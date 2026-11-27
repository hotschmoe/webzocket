const std = @import("std");
const assert = @import("assert").assert;

pub const input_max: u32 = 150000;
pub const payload_max: u32 = 140000;
pub const classes: u8 = 100;
pub const opcodes = [_]u8{ 1, 2, 8, 9, 10 };
pub const lengths = [_]u32{ 0, 125, 126, 65535, 65536, 70000 };
pub const Outcome = enum { accept, incomplete, rejected };
pub const Message = struct { opcode: u8, offset: u32, length: u32 };
pub const Case = struct {
    bytes: [input_max]u8 = undefined,
    payload: [payload_max]u8 = undefined,
    length: u32 = 0,
    payload_length: u32 = 0,
    messages: [8]Message = undefined,
    count: u8 = 0,
    class: u8 = 0,
    outcome: Outcome = .accept,
    expected_error: ?anyerror = null,
    compression: bool = false,
    forbid_allocation: bool = true,
    static_size: u32 = input_max,
    maximum: u32 = input_max,
    handshake: bool = false,
    key: [24]u8 = undefined,
    expected_key: [32]u8 = undefined,
    key_length: u8 = 0,
    chunk_seed: u64 = 0,
    frame_opcodes: [16]u8 = @splat(0),

    pub fn append(self: *Case, bytes: []const u8) !void {
        assert(self.length <= input_max);
        if (bytes.len > input_max - self.length) return error.InputLimit;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += @intCast(bytes.len);
        assert(self.length <= input_max);
    }

    pub fn expect_message(self: *Case, opcode: u8, bytes: []const u8) !void {
        assert(self.count <= self.messages.len);
        if (self.count == self.messages.len) return error.MessageLimit;
        if (bytes.len > payload_max - self.payload_length) return error.PayloadLimit;
        self.messages[self.count] = .{
            .opcode = opcode,
            .offset = self.payload_length,
            .length = @intCast(bytes.len),
        };
        @memcpy(self.payload[self.payload_length..][0..bytes.len], bytes);
        self.payload_length += @intCast(bytes.len);
        self.count += 1;
        assert(self.payload_length <= payload_max);
    }
};

pub const Frame = struct {
    opcode: u8,
    payload: []const u8,
    masked: bool = false,
    final: bool = true,
    flags: u8 = 0,
    encoding: ?u8 = null,
    mask: [4]u8 = .{ 71, 2, 199, 34 },
};

pub fn append_frame(case: *Case, frame: Frame) !void {
    assert(frame.opcode < 16);
    case.frame_opcodes[frame.opcode] += 1;
    const size: u8 = frame.encoding orelse
        @as(u8, if (frame.payload.len < 126) 0 else if (frame.payload.len < 65536) 2 else 8);
    assert(size == 0 or size == 2 or size == 8);
    const marker: u8 = if (size == 0) @intCast(frame.payload.len) else if (size == 2) 126 else 127;
    try case.append(&.{
        frame.opcode | frame.flags | @as(u8, if (frame.final) 128 else 0),
        marker | @as(u8, if (frame.masked) 128 else 0),
    });
    for (0..size) |index| {
        const shift: u6 = @intCast((size - 1 - index) * 8);
        try case.append(&.{@truncate(@as(u64, frame.payload.len) >> shift)});
    }
    if (frame.masked) try case.append(&frame.mask);
    const start = case.length;
    try case.append(frame.payload);
    if (frame.masked) {
        for (case.bytes[start..case.length], 0..) |*byte, index| byte.* ^= frame.mask[index % 4];
    }
    assert(case.length >= start + frame.payload.len);
}

pub fn generate(case: *Case, seed: u64, number: u32) !void {
    case.* = .{};
    case.class = @intCast(number % classes);
    var random = std.Random.DefaultPrng.init(seed +% (@as(u64, number) *% 0x9e3779b97f4a7c15));
    const rng = random.random();
    case.chunk_seed = rng.int(u64);
    if (case.class < 30) {
        try regular(case, rng);
    } else if (case.class < 48) {
        try damaged(case, rng);
    } else if (case.class < 64) {
        try handshake(case, rng);
    } else try @import("fuzz_profiles.zig").generate_extra(case, rng);
    assert(case.class < classes);
    assert(case.length <= input_max);
}

fn regular(case: *Case, random: std.Random) !void {
    assert(case.class < 30);
    const opcode = opcodes[case.class / 6];
    const length = lengths[case.class % 6];
    var payload: [70000]u8 = undefined;
    random.bytes(payload[0..length]);
    if (opcode == 1) for (payload[0..length]) |*byte| {
        byte.* = 'a' + byte.* % 26;
    };
    const masked = random.boolean();
    var mask: [4]u8 = undefined;
    random.bytes(&mask);
    try append_frame(case, .{
        .opcode = opcode,
        .payload = payload[0..length],
        .masked = masked,
        .mask = mask,
    });
    if (case.class == 1) case.static_size = case.length;
    if (opcode >= 8 and length > 125) {
        case.outcome = .rejected;
        case.expected_error = error.LargeControl;
    } else try case.expect_message(opcode, payload[0..length]);
    assert(case.length > length);
}

fn damaged(case: *Case, random: std.Random) !void {
    assert(case.class >= 30 and case.class < 48);
    var frame = Frame{ .opcode = 1, .payload = "hello", .masked = random.boolean() };
    switch (case.class) {
        30 => return fragmented(case, random),
        31 => return compressed(case),
        32 => {
            frame.flags = 16;
            case.expected_error = error.ReservedFlags;
        },
        33 => {
            frame.opcode = 3 + random.uintLessThan(u8, 5);
            case.expected_error = error.InvalidMessageType;
        },
        34 => {
            frame.opcode = 9;
            frame.final = false;
            case.expected_error = error.FragmentedControl;
        },
        35 => {
            frame.opcode = 0;
            case.expected_error = error.UnfragmentedContinuation;
        },
        36 => return nested(case, frame.masked),
        37 => frame.encoding = 2,
        38 => frame.encoding = 8,
        39 => {
            case.static_size = 2;
            case.maximum = 4;
            case.expected_error = error.TooLarge;
        },
        40 => frame.payload = "\xc0\xaf",
        41 => {
            frame.opcode = 8;
            frame.payload = "\x03\xe8\xff";
        },
        42 => {
            frame.opcode = 8;
            frame.payload = "\x03\xed";
        },
        43 => {
            frame.opcode = 8;
            frame.payload = "x";
        },
        44 => {
            frame.flags = 64;
            case.expected_error = error.ReservedFlags;
        },
        45 => {
            case.compression = true;
            case.forbid_allocation = false;
            frame.flags = 64;
            frame.payload = "\xff\xff\xff";
            case.expected_error = error.CompressionError;
        },
        46 => {
            frame.payload = "a truncated frame";
            case.outcome = .incomplete;
        },
        47 => {
            frame.flags = 32;
            case.expected_error = error.ReservedFlags;
        },
        else => return error.UnknownClass,
    }
    try finish_frame(case, frame, random);
}

fn finish_frame(case: *Case, frame: Frame, random: std.Random) !void {
    assert(case.length == 0);
    try append_frame(case, frame);
    if (case.class == 46) {
        case.length = random.uintLessThan(u32, case.length);
    } else if (case.expected_error != null) {
        case.outcome = .rejected;
    } else try case.expect_message(frame.opcode, frame.payload);
    assert(case.count <= 1);
}

fn fragmented(case: *Case, random: std.Random) !void {
    assert(case.count == 0);
    case.forbid_allocation = false;
    case.static_size = 16;
    var payload: [4096]u8 = undefined;
    const length = random.intRangeAtMost(u32, 6, payload.len);
    random.bytes(payload[0..length]);
    for (payload[0..length]) |*byte| byte.* = 'a' + byte.* % 26;
    const count = random.intRangeAtMost(u8, 2, 6);
    const opcode: u8 = if (random.boolean()) 1 else 2;
    var start: u32 = 0;
    for (0..count) |index| {
        const end = if (index + 1 == count) length else start + length / count;
        try append_frame(case, .{
            .opcode = if (index == 0) opcode else 0,
            .payload = payload[start..end],
            .final = index + 1 == count,
            .masked = random.boolean(),
        });
        if (index + 1 < count) {
            const control: u8 = if (random.boolean()) 9 else 10;
            try append_frame(case, .{ .opcode = control, .payload = "control" });
            try case.expect_message(control, "control");
        }
        start = end;
    }
    try case.expect_message(opcode, payload[0..length]);
    assert(start == length and case.count == count);
}

fn nested(case: *Case, masked: bool) !void {
    assert(case.count == 0);
    case.forbid_allocation = false;
    try append_frame(case, .{ .opcode = 1, .payload = "first", .final = false, .masked = masked });
    try append_frame(case, .{ .opcode = 2, .payload = "second", .masked = masked });
    case.outcome = .rejected;
    case.expected_error = error.NestedFragment;
    assert(case.length > 11);
}

fn compressed(case: *Case) !void {
    assert(case.count == 0);
    case.compression = true;
    case.forbid_allocation = false;
    const message = "a compressed message with a stored DEFLATE block";
    var payload: [message.len + 6]u8 = undefined;
    @memcpy(payload[0..5], &[_]u8{ 0, message.len, 0, ~@as(u8, message.len), 255 });
    @memcpy(payload[5..][0..message.len], message);
    payload[payload.len - 1] = 0;
    try append_frame(case, .{ .opcode = 1, .payload = &payload, .flags = 64 });
    try case.expect_message(1, message);
    assert(case.length > message.len);
}

fn handshake(case: *Case, random: std.Random) !void {
    assert(case.class >= 48 and case.class < classes);
    case.handshake = true;
    var key: [16]u8 = undefined;
    random.bytes(&key);
    _ = std.base64.standard.Encoder.encode(&case.key, &key);
    try expect_key(case, &case.key);
    try case.append(if (case.class == 60) "POST / HTTP/1.1\r\n" else "GET / HTTP/1.1\r\n");
    if (case.class != 49) try case.append("Upgrade: websocket\r\n");
    if (case.class != 50) try case.append("Connection: Upgrade\r\n");
    try case.append("Host: localhost\r\n");
    if (case.class == 51) {
        try case.append("Sec-WebSocket-Version: 12\r\n");
    } else try case.append("Sec-WebSocket-Version: 13\r\n");
    if (case.class != 52) {
        try case.append("Sec-WebSocket-Key: ");
        try case.append(switch (case.class) {
            54 => "abc",
            55 => "!!!!!!!!!!!!!!!!!!!!!!!!",
            else => &case.key,
        });
        try case.append("\r\n");
    }
    if (case.class == 54) try expect_key(case, "abc");
    if (case.class == 55) try expect_key(case, "!!!!!!!!!!!!!!!!!!!!!!!!");
    try handshake_damage(case);
    if (case.expected_error != null) case.outcome = .rejected;
    assert(case.length > 20);
}

fn handshake_damage(case: *Case) !void {
    assert(case.handshake);
    switch (case.class) {
        49, 50, 52 => case.expected_error = error.MissingHeaders,
        51 => case.expected_error = error.InvalidVersion,
        53 => {
            try case.append("Sec-WebSocket-Key: duplicate\r\n");
            try expect_key(case, "duplicate");
        },
        56 => {
            try case.append("X-Long: ");
            for (0..4096) |_| try case.append("a");
            try case.append("\r\n");
        },
        57 => {
            try case.append("\n");
            case.outcome = .incomplete;
        },
        58 => {
            try case.append("invalid header\r\n");
            case.expected_error = error.InvalidHeader;
        },
        59 => {
            @memcpy(case.bytes[6..14], "HTTP/1.0");
            case.expected_error = error.InvalidProtocol;
        },
        61 => try case.append("Sec-WebSocket-Extensions: permessage-deflate; " ++
            "server_max_window_bits=abc, permessage-deflate\r\n"),
        62 => try case.append("Upgrade: websocket\r\n"),
        63 => try case.append("Connection: xupgrade\r\n"),
        else => {},
    }
    try case.append(if (case.class == 57) "\n" else "\r\n");
    assert(case.length <= input_max);
}

pub fn expect_key(case: *Case, key: []const u8) !void {
    assert(case.handshake);
    if (key.len > case.expected_key.len) return error.KeyLimit;
    @memcpy(case.expected_key[0..key.len], key);
    case.key_length = @intCast(key.len);
    assert(case.key_length <= case.expected_key.len);
}

pub fn generate_regression(case: *Case, random: std.Random) !void {
    assert(case.class == 84 or case.class == 85 or case.class >= 96);
    if (case.class == 84) {
        case.maximum = 0;
        try append_frame(case, .{ .opcode = 1, .payload = "data", .masked = random.boolean() });
        return case.expect_message(1, "data");
    }
    case.outcome = .rejected;
    case.expected_error = error.TooLarge;
    if (case.class == 85 or case.class == 96) {
        case.static_size = 16;
        const headers = [_][10]u8{
            .{ 130, 127, 128, 0, 0, 0, 0, 0, 0, 0 },
            .{ 130, 127, 255, 255, 255, 255, 255, 255, 255, 255 },
        };
        try case.append(&headers[@intFromBool(case.class == 96)]);
    } else {
        case.handshake = true;
        case.expected_error = error.InvalidRequestLine;
        const headers = "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: abc\r\n\r\n";
        const lines = [_][]const u8{
            " HTTP/1.1" ++ headers, "HTTP/1.1" ++ headers, "X HTTP/1.1" ++ headers,
        };
        try case.append(lines[case.class - 97]);
    }
    assert(case.expected_error != null);
}

pub fn generate_probe(case: *Case, name: []const u8) !void {
    case.* = .{};
    if (std.mem.eql(u8, name, "forbidden-fragment")) {
        case.class = 82;
        case.outcome = .rejected;
        case.expected_error = error.OutOfMemory;
        try append_frame(case, .{ .opcode = 1, .payload = "first", .final = false });
    } else return error.UnknownProbe;
    assert(case.length > 0);
    assert(case.expected_error != null);
}
