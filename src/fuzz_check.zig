const std = @import("std");
const ws = @import("webzocket");
const generate = @import("fuzz_generate.zig");
const assert = @import("assert").assert;
const Tracking = @import("fuzz_allocator.zig").Tracking;

pub const memory_max: u32 = 2 * 1024 * 1024;
pub const error_names = [_][]const u8{
    "LargeControl",             "ReservedFlags",     "InvalidMessageType", "FragmentedControl",
    "UnfragmentedContinuation", "NestedFragment",    "TooLarge",           "CompressionError",
    "MissingHeaders",           "InvalidVersion",    "InvalidHeader",      "InvalidProtocol",
    "InvalidUpgrade",           "InvalidConnection", "InvalidRequestLine",
};
pub const Counters = struct {
    classes: [generate.classes]u64 = @splat(0),
    opcodes: [16]u64 = @splat(0),
    lengths: [6]u64 = @splat(0),
    errors: [error_names.len]u64 = @splat(0),
    accepted: u64 = 0,
    rejected: u64 = 0,
    incomplete: u64 = 0,
    masked: u64 = 0,
    unmasked: u64 = 0,
    no_fallback: u64 = 0,
    pooled: u64 = 0,
    prefix_checks: u64 = 0,
};
pub const Workspace = struct {
    guarded: [generate.input_max + 32]u8 = undefined,
    scratch: [memory_max]u8 = undefined,
    pooled: [2][generate.input_max]u8 = undefined,
};

pub fn check(case: *const generate.Case, work: *Workspace, io: std.Io, counters: *Counters) !void {
    assert(case.length <= generate.input_max);
    if (case.handshake) {
        try check_handshake(case, work, counters);
    } else {
        if (case.class < 30) try check_writer(case);
        for (0..4) |mode| {
            try check_frames(case, work, .{ .io = io, .mode = @intCast(mode) }, counters);
        }
        if (case.class < 30) {
            counters.lengths[case.class % 6] += 1;
        }
        for (&counters.opcodes, case.frame_opcodes) |*count, frames| count.* += frames;
        if (case.length > 1 and case.bytes[1] & 128 != 0) {
            counters.masked += 1;
        } else counters.unmasked += 1;
    }
    counters.classes[case.class] += 1;
    switch (case.outcome) {
        .accept => counters.accepted += 1,
        .rejected => {
            counters.rejected += 1;
            try count_error(case.expected_error.?, counters);
        },
        .incomplete => counters.incomplete += 1,
    }
    assert(counters.classes[case.class] > 0);
}

const Plan = struct { io: std.Io, mode: u8 };

fn check_frames(
    case: *const generate.Case,
    work: *Workspace,
    plan: Plan,
    counters: *Counters,
) !void {
    assert(plan.mode < 4);
    assert(case.static_size >= 2 and case.static_size <= generate.input_max);
    const poison: u8 = if (plan.mode == 1) 0x5a else 0xa5;
    @memset(&work.guarded, poison);
    var arena = std.heap.FixedBufferAllocator.init(&work.scratch);
    var forbidden = std.heap.FixedBufferAllocator.init(&.{});
    const forbid = case.forbid_allocation and plan.mode < 2;
    var pool_buffers = [_][]u8{ &work.pooled[0], &work.pooled[1] };
    var tracking = Tracking{ .backing = if (forbid) forbidden.allocator() else arena.allocator() };
    var provider = try ws.buffer.Provider.init(
        tracking.allocator(),
        plan.io,
        .{ .count = 0, .max = case.maximum },
    );
    if (plan.mode == 2) {
        provider.pool_buffer_size = generate.input_max;
        provider.pool = .{
            .buffer_size = generate.input_max,
            .available = 2,
            .buffers = &pool_buffers,
            .allocator = forbidden.allocator(),
            .io = plan.io,
            .mutex = .init,
        };
    }
    const size = if (plan.mode >= 2) @min(case.static_size, 16) else case.static_size;
    var reader = ws.proto.Reader.init(
        work.guarded[16..][0..size],
        &provider,
        if (case.compression) .{} else null,
    );
    var cleaned = false;
    defer if (!cleaned) reader.deinit();
    const result = drive(case, &reader, plan.mode, counters);
    assert(reader.pos <= reader.buf.data.len and reader.start <= reader.pos);
    reader.deinit();
    cleaned = true;
    if (tracking.live_bytes != 0) return error.MemoryLeak;
    if (plan.mode == 2 and provider.pool.available != 2) return error.PooledBufferLeak;
    try verify_result(case, result);
    if (!std.mem.allEqual(u8, work.guarded[0..16], poison) or
        !std.mem.allEqual(u8, work.guarded[16 + size ..], poison)) return error.BufferOverrun;
    if (forbid) {
        if (tracking.calls != 0) return error.FallbackAllocation;
        counters.no_fallback += 1;
    }
    if (plan.mode == 2) counters.pooled += 1;
}

fn drive(
    case: *const generate.Case,
    reader: *ws.proto.Reader,
    mode: u8,
    counters: *Counters,
) !void {
    assert(mode < 4);
    assert(reader.pos == 0 and reader.start == 0);
    var offset: u32 = 0;
    var count: u8 = 0;
    var random = std.Random.DefaultPrng.init(case.chunk_seed);
    for (0..generate.input_max * 2) |_| {
        const message = try reader.read();
        if (message) |pair| {
            if (count >= case.count) return error.UnexpectedMessage;
            const expected = case.messages[count];
            const actual = pair[1];
            if (opcode(actual.type) != expected.opcode) return error.ChangedOpcode;
            const payload = case.payload[expected.offset..][0..expected.length];
            if (!std.mem.eql(u8, actual.data, payload)) return error.ChangedPayload;
            reader.done(actual.type);
            count += 1;
            continue;
        }
        if (offset == case.length) {
            if (count != case.count) return error.MissingMessage;
            if (case.outcome == .accept and !reader.isEmpty()) return error.PendingBytes;
            return;
        }
        const remaining = case.length - offset;
        const wanted = switch (mode) {
            0 => remaining,
            1 => 1,
            else => random.random().intRangeAtMost(u32, 1, @min(remaining, 8192)),
        };
        const take = @min(wanted, reader.buf.data.len - reader.pos);
        if (take == 0) return error.ReaderStalled;
        @memcpy(reader.buf.data[reader.pos..][0..take], case.bytes[offset..][0..take]);
        reader.pos += take;
        offset += @intCast(take);
        if (mode == 1) counters.prefix_checks += 1;
    }
    return error.StepLimit;
}

fn opcode(kind: ws.Message.Type) u8 {
    return switch (kind) {
        .text => 1,
        .binary => 2,
        .close => 8,
        .ping => 9,
        .pong => 10,
    };
}

fn verify_result(case: *const generate.Case, result: anyerror!void) !void {
    assert(case.expected_error == null or case.outcome == .rejected);
    if (result) |_| {
        if (case.outcome == .rejected) return error.AcceptedMalformed;
    } else |err| {
        if (case.expected_error == null or err != case.expected_error.?) return err;
    }
    assert(case.outcome != .rejected or case.expected_error != null);
}

fn check_writer(case: *const generate.Case) !void {
    assert(case.class < 30);
    const length = generate.lengths[case.class % 6];
    const op: ws.OpCode = @fromBackingInt(@intCast(128 | generate.opcodes[case.class / 6]));
    const size: u8 = if (length < 126) 2 else if (length < 65536) 4 else 10;
    var header: [14]u8 = @splat(0x5a);
    const written = ws.proto.writeFrameHeader(&header, op, length, false);
    if (written.len != size or header[0] != case.bytes[0] or
        header[1] != case.bytes[1] & 127) return error.ChangedHeader;
    if (!std.mem.eql(u8, header[2..size], case.bytes[2..size])) return error.ChangedLength;
    if (!std.mem.allEqual(u8, header[size..], 0x5a)) return error.HeaderOverrun;
    _ = ws.proto.writeFrameHeader(&header, op, length, true);
    if (header[0] != case.bytes[0] | 64) return error.MissingCompressionFlag;
    assert(written.len <= header.len);
}

fn check_handshake(case: *const generate.Case, work: *Workspace, counters: *Counters) !void {
    assert(case.handshake);
    for (0..2) |mode| {
        @memset(&work.guarded, 0xa5);
        var keys: [16][]const u8 = undefined;
        var values: [16][]const u8 = undefined;
        var state = ws.Handshake.State{
            .buf = work.guarded[16..][0..case.length],
            .req_headers = .{ .len = 0, .keys = &keys, .values = &values },
            .res_headers = .{ .len = 0, .keys = &.{}, .values = &.{} },
            .pool = undefined,
        };
        const result = parse_request(case, &state, @intCast(mode), counters);
        try verify_result(case, result);
        if (!std.mem.allEqual(u8, work.guarded[0..16], 0xa5) or
            !std.mem.allEqual(u8, work.guarded[16 + case.length ..], 0xa5))
            return error.HandshakeOverrun;
    }
    assert(case.length <= generate.input_max);
}

fn parse_request(
    case: *const generate.Case,
    state: *ws.Handshake.State,
    mode: u8,
    counters: *Counters,
) !void {
    assert(state.len == 0);
    assert(mode <= 1);
    for (0..case.length) |index| {
        state.buf[index] = case.bytes[index];
        state.len = index + 1;
        if (mode == 0 and state.len < case.length) continue;
        const parsed = try ws.Handshake.parse(state);
        counters.prefix_checks += 1;
        if (parsed) |request| {
            if (state.len != case.length) return error.PrematureHandshake;
            if (case.outcome == .incomplete) return error.AcceptedIncomplete;
            if (!std.mem.eql(u8, request.url, "/")) return error.ChangedUrl;
            if (!std.mem.eql(u8, request.key, case.expected_key[0..case.key_length]))
                return error.ChangedRequestKey;
            try check_reply(request.key);
            return;
        }
    }
    if (case.outcome != .incomplete) return error.MissingHandshake;
}

fn check_reply(key: []const u8) !void {
    assert(key.len < 128);
    var joined: [164]u8 = undefined;
    @memcpy(joined[0..key.len], key);
    @memcpy(joined[key.len..][0..36], "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined[0 .. key.len + 36], &digest, .{});
    var encoded: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    for (0..4) |mode| {
        const compressed = mode & 1 != 0;
        const custom = mode & 2 != 0;
        var buffer: [1024]u8 = @splat(0xa5);
        var keys = [_][]const u8{"X-Fuzz"};
        var values = [_][]const u8{"seeded"};
        var headers = ws.Handshake.KeyValue{ .keys = &keys, .values = &values, .len = 1 };
        const reply = try ws.Handshake.createReply(
            key,
            if (custom) &headers else null,
            compressed,
            &buffer,
        );
        if (!std.mem.startsWith(u8, reply, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\nConnection: upgrade\r\n")) return error.ChangedReplyStatus;
        const start = std.mem.indexOf(u8, reply, "Sec-Websocket-Accept: ") orelse
            return error.MissingAcceptKey;
        if (!std.mem.eql(u8, reply[start + 22 ..][0..28], &encoded)) return error.WrongAcceptKey;
        const ending = if (custom) "\r\nX-Fuzz: seeded\r\n\r\n" else "\r\n\r\n";
        if (!std.mem.endsWith(u8, reply, ending))
            return error.ChangedReplyHeaders;
        const has_compression = std.mem.indexOf(u8, reply, "permessage-deflate") != null;
        if (has_compression != compressed) return error.ChangedNegotiation;
        if (!std.mem.allEqual(u8, buffer[reply.len..], 0xa5)) return error.ReplyOverrun;
    }
    assert(key.len + 36 <= joined.len);
}

fn count_error(err: anyerror, counters: *Counters) !void {
    assert(counters.rejected > 0);
    for (error_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, @errorName(err))) {
            counters.errors[index] += 1;
            return;
        }
    }
    return error.UnknownExpectedError;
}

pub fn verify_coverage(counters: *const Counters) !void {
    assert(counters.accepted + counters.rejected + counters.incomplete > 0);
    for (counters.classes) |count| if (count == 0) return error.ClassCoverageGap;
    for (counters.opcodes) |count| if (count == 0) return error.OpcodeCoverageGap;
    for (counters.lengths) |count| if (count == 0) return error.LengthCoverageGap;
    for (counters.errors) |count| if (count == 0) return error.ErrorCoverageGap;
    if (counters.no_fallback == 0 or counters.pooled == 0 or counters.masked == 0 or
        counters.unmasked == 0 or counters.prefix_checks == 0) return error.PathCoverageGap;
    assert(counters.rejected > 0);
}
