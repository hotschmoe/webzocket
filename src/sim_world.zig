const std = @import("std");
const ws = @import("webzocket");
const assert = @import("assert").assert;
const core = @import("sim_core.zig");
const wire = @import("sim_wire.zig");
const cross = @import("sim_cross.zig");
const Pipe = @import("sim_pipe.zig").Pipe;

const Conn = ws.conn.Conn;
const Violation = core.Violation;
const MessageKind = ws.conn.MessageKind;

pub const recv_cap: u32 = 8192;
pub const message_cap: u32 = 72000;
pub const send_cap: u32 = 80000;
const ring_capacity: u32 = 64;
const step_limit: u32 = 600_000;
const drain_max: u32 = 100_000;
const timeout_steps: u32 = 2000;
const old_log_high: u32 = 1500;

fn timed_out(conn: *const Conn) bool {
    assert(conn.failure == null or conn.is_done());
    const failure = conn.failure orelse return false;
    return failure == error.Timeout;
}

const Kind = enum(u8) { text, binary, ping };
const Item = struct { kind: Kind, length: u32, seed: u64 };
const Close = struct { code: ?u16, reason: [123]u8 = undefined, reason_len: u8 = 0 };
const Frag = struct {
    kind: MessageKind,
    seed: u64,
    length: u32,
    offset: u32,
    parts_left: u8,
};
pub const Scenario = enum(u8) { graceful, cut, stall_handshake, stall_close };
const Phase = enum(u8) { work, closing };

pub const Totals = struct {
    sessions: u64 = 0,
    steps: u64 = 0,
    messages: u64 = 0,
    message_bytes: u64 = 0,
    pings: u64 = 0,
    pongs: u64 = 0,
    coalesced: u64 = 0,
    closes: u64 = 0,
    refused: u64 = 0,
    old_messages: u64 = 0,
    bytes: u64 = 0,
    scenarios: [4]u64 = @splat(0),
    eof: [7]u64 = @splat(0),
};

const Side = struct {
    conn: Conn,
    index: u8,
    recv: core.Region(recv_cap),
    message: core.Region(message_cap),
    send: core.Region(send_cap),
    payload: [message_cap]u8,
    sent: core.Ring(Item, ring_capacity),
    pongs: core.Ring(Item, ring_capacity),
    frag: ?Frag,
    close: ?Close,
    close_wanted: ?Close,
    closed_event: bool,
    opened: bool,
    refused: u64,
    skipped: u64,
    forgiven: u64,
    quiet_bytes: ?u64,
    message_max: u32,
    send_len: u32,
    target: [40]u8,
    target_len: u8,
};

pub const World = struct {
    sides: [2]Side,
    pipes: [2]Pipe,
    old: [2]cross.OldStream,
    scratch: [message_cap]u8,
    report: core.Report,
    trace: core.Trace,
    totals: Totals,
    prng: std.Random.DefaultPrng,
    now: u64,
    scenario: Scenario,
    phase: Phase,
    cut_at: u64,
    ops_left: [2]u32,
    chunk_bias: u8,
    delay_max: u32,
    ended: bool,
    close_chosen: bool,
    stall_victim: ?u8,
    eofs: [2]ws.conn.Eof,

    pub fn digest(self: *const World) u64 {
        return self.trace.digest();
    }

    fn other(self: *World, side: *Side) *Side {
        return &self.sides[1 - side.index];
    }

    fn fail(
        self: *World,
        checker: core.Checker,
        comptime format: []const u8,
        args: anytype,
    ) Violation {
        return self.report.fail(checker, format, args);
    }

    fn random(self: *World) std.Random {
        return self.prng.random();
    }

    fn pick(self: *World, comptime T: type, options: []const T) T {
        return options[self.random().uintLessThan(usize, options.len)];
    }

    pub fn run_session(self: *World, seed: u64, index: u32) Violation!void {
        assert(self.report.checker == null);
        try self.begin(seed, index);
        assert(self.sides[0].conn.role == .client and self.sides[1].conn.role == .server);
        for (0..step_limit) |_| {
            if (self.finished()) return self.finish();
            try self.step();
        }
        return self.fail(.liveness, "session did not end in {d} steps", .{step_limit});
    }

    fn begin(self: *World, seed: u64, index: u32) Violation!void {
        self.prng = std.Random.DefaultPrng.init(wire.mix64(seed, index));
        self.now = 1000;
        self.phase = .work;
        self.ended = false;
        self.close_chosen = false;
        self.stall_victim = null;
        self.trace = .{};
        self.report.checker = null;
        const roll = self.random().uintLessThan(u8, 100);
        self.scenario = if (roll < 70) .graceful else if (roll < 88) .cut else if (roll < 94)
            .stall_handshake
        else
            .stall_close;
        self.cut_at = if (self.scenario == .cut) self.pick_cut() else std.math.maxInt(u64);
        self.chunk_bias = self.random().uintLessThan(u8, 4);
        self.delay_max = self.pick(u32, &.{ 0, 0, 3, 40 });
        if (self.scenario == .stall_close or self.scenario == .stall_handshake) {
            self.chunk_bias = 3;
            self.delay_max = 0;
        }
        const ops_low = self.random().intRangeAtMost(u32, 4, 60);
        self.ops_left = .{ ops_low, self.random().intRangeAtMost(u32, 4, 60) };
        for (&self.pipes) |*pipe| pipe.reset();
        const old_static = self.pick(u32, &.{ 16, 64, 512, 4096 });
        for (&self.old) |*old| old.start(old_static);
        try self.setup_sides();
        if (self.scenario == .stall_handshake) {
            for (&self.pipes) |*pipe| pipe.cut();
        }
        self.totals.sessions += 1;
        self.totals.scenarios[@backingInt(self.scenario)] += 1;
        assert(self.ops_left[0] >= 4 and self.ops_left[1] >= 4);
        try self.start_handshake();
        assert(self.sides[0].conn.queued() > 0 and self.sides[1].conn.queued() == 0);
    }

    fn pick_cut(self: *World) u64 {
        assert(self.scenario == .cut);
        const cut = switch (self.random().uintLessThan(u8, 4)) {
            0 => self.random().uintLessThan(u64, 400),
            1 => self.random().uintLessThan(u64, 3000),
            else => self.random().uintLessThan(u64, 40000),
        };
        assert(cut < 40000);
        return cut;
    }

    fn setup_sides(self: *World) Violation!void {
        assert(self.pipes[0].written == 0 and self.pipes[1].written == 0);
        const recv_len = self.pick(u32, &.{ 256, 256, 512, 1024, 4096, 8192 });
        const timed = self.scenario == .stall_handshake or self.scenario == .stall_close;
        for (&self.sides, 0..) |*side, index| {
            side.index = @intCast(index);
            side.message_max = self.pick(u32, &.{ 16, 125, 125, 1000, 1000, 4096, 4096, 72000 });
            side.send_len = self.pick(u32, &.{ 256, 600, 600, 8192, 8192, 80000 });
            var seed: [32]u8 = undefined;
            self.random().bytes(&seed);
            side.conn = ws.conn.Conn.init(.{
                .role = if (index == 0) .client else .server,
                .recv = side.recv.arm(recv_len),
                .message = side.message.arm(side.message_max),
                .send = side.send.arm(side.send_len),
                .handshake_timeout_ms = if (self.scenario == .stall_handshake) timeout_steps else 0,
                .close_timeout_ms = if (timed) timeout_steps else 0,
                .mask_seed = seed,
            }, self.now) catch return self.fail(.limits, "init rejected a valid config", .{});
            side.sent.clear();
            side.pongs.clear();
            side.frag = null;
            side.close = null;
            side.close_wanted = null;
            side.closed_event = false;
            side.opened = false;
            side.refused = 0;
            side.skipped = 0;
            side.forgiven = 0;
            side.quiet_bytes = null;
            assert(side.conn.state == .handshake and side.conn.queued() == 0);
        }
        assert(self.sides[0].send_len >= 256 and self.sides[1].send_len >= 256);
    }

    fn start_handshake(self: *World) Violation!void {
        assert(self.sides[0].conn.state == .handshake and self.sides[0].index == 0);
        const client = &self.sides[0];
        const server = &self.sides[1];
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-._~/";
        client.target_len = self.random().intRangeAtMost(u8, 1, 40);
        for (client.target[0..client.target_len]) |*byte| {
            byte.* = alphabet[self.random().uintLessThan(usize, alphabet.len)];
        }
        client.target[0] = '/';
        server.target_len = 0;
        var host: [30]u8 = undefined;
        const host_len = self.random().intRangeAtMost(u8, 1, 30);
        for (host[0..host_len]) |*byte| byte.* = alphabet[self.random().uintLessThan(usize, 37)];
        var raw: [16]u8 = undefined;
        self.random().bytes(&raw);
        var text: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&text, &raw);
        const target = client.target[0..client.target_len];
        client.conn.start_client(host[0..host_len], target, &raw) catch |err| {
            return self.fail(.handshake, "start_client failed: {s}", .{@errorName(err)});
        };
        const request = client.conn.output();
        if (!cross.old_accepts_request(request, client.target[0..client.target_len], &text)) {
            return self.fail(.cross_old, "old Handshake.parse refused the request", .{});
        }
        assert(client.conn.queued() > 0);
    }

    fn finished(self: *World) bool {
        assert(self.sides[0].index == 0 and self.sides[1].index == 1);
        if (self.ended) return true;
        for (&self.sides) |*side| {
            if (!side.conn.is_done()) return false;
        }
        for (&self.sides, 0..) |*side, index| {
            const pipe = &self.pipes[index];
            if (pipe.dead) continue;
            if (side.conn.output().len > 0 or pipe.pending() > 0) return false;
        }
        assert(self.sides[0].conn.is_done() and self.sides[1].conn.is_done());
        return true;
    }

    fn step(self: *World) Violation!void {
        assert(self.now >= 1000 and !self.ended);
        self.now += 1;
        self.totals.steps += 1;
        for (&self.sides) |*side| {
            side.conn.tick(self.now) catch |err| try self.on_error(side, err);
        }
        const roll = self.random().uintLessThan(u8, 100);
        const index = self.random().uintLessThan(u8, 2);
        self.trace.mix(@as(u64, roll) << 8 | index);
        if (roll < 30) {
            try self.work(&self.sides[index]);
        } else if (roll < 55) {
            try self.pump(index);
        } else try self.deliver(index);
        try self.check_invariants();
        assert(self.totals.steps > 0);
    }

    fn on_error(self: *World, side: *Side, err: ws.conn.Error) Violation!void {
        assert(side.index < 2 and side.conn.failure != null);
        const expected = err == error.Timeout and
            (self.scenario == .stall_handshake or self.scenario == .stall_close);
        if (!expected) {
            return self.fail(.error_class, "side {d} failed in an honest session: {s}", .{
                side.index, @errorName(err),
            });
        }
        self.trace.mix(@as(u64, 0xe000) | side.index);
        assert(side.conn.state == .failed);
    }

    fn work(self: *World, side: *Side) Violation!void {
        assert(side.index < 2);
        assert(self.ops_left[0] <= 60 and self.ops_left[1] <= 60);
        if (self.phase == .closing) return self.work_close();
        if (self.ops_left[0] == 0 and self.ops_left[1] == 0) {
            self.phase = .closing;
            return;
        }
        if (self.ops_left[side.index] == 0) return;
        if (side.conn.state == .handshake) return self.expect_not_open(side);
        if (!side.conn.is_open()) return;
        self.ops_left[side.index] -= 1;
        if (side.frag != null) return self.continue_fragment(side);
        const roll = self.random().uintLessThan(u8, 100);
        if (roll < 20) return self.send_ping(side);
        return self.start_message(side);
    }

    fn expect_not_open(self: *World, side: *Side) Violation!void {
        assert(side.conn.state == .handshake);
        if (side.conn.send_ping("x")) |_| {
            return self.fail(.handshake, "send accepted before the handshake finished", .{});
        } else |err| {
            if (err != error.NotOpen) {
                return self.fail(.handshake, "open check gave {s}", .{@errorName(err)});
            }
        }
        assert(side.conn.state == .handshake);
    }

    fn work_close(self: *World) Violation!void {
        assert(self.phase == .closing);
        if (!self.close_chosen) {
            self.close_chosen = true;
            const first = self.random().uintLessThan(u8, 2);
            self.sides[first].close_wanted = self.random_close();
            if (self.random().uintLessThan(u8, 4) == 0 and self.scenario != .stall_close) {
                self.sides[1 - first].close_wanted = self.random_close();
            }
        }
        for (&self.sides) |*side| {
            const wanted = side.close_wanted orelse continue;
            if (side.conn.is_open()) try self.try_close(side, wanted);
        }
        assert(self.close_chosen);
    }

    fn random_close(self: *World) Close {
        var close = Close{ .code = null };
        if (self.random().uintLessThan(u8, 6) == 0) return close;
        const codes = [_]u16{ 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010 };
        const more = [_]u16{ 1011, 1012, 1013, 1014 };
        const all = codes ++ more;
        close.code = if (self.random().boolean())
            self.pick(u16, &all)
        else
            self.random().intRangeAtMost(u16, 3000, 4999);
        close.reason_len = self.random().intRangeAtMost(u8, 0, 123);
        wire.payload_fill(close.reason[0..close.reason_len], self.random().int(u64), true);
        assert(close.code.? >= 1000 and close.code.? <= 4999);
        assert(close.reason_len <= 123);
        return close;
    }

    fn try_close(self: *World, side: *Side, close: Close) Violation!void {
        assert(side.close == null and side.close_wanted != null);
        if (side.conn.send_close(close.code, close.reason[0..close.reason_len], self.now)) |_| {
            side.close = close;
            side.close_wanted = null;
            self.totals.closes += 1;
            if (self.scenario == .stall_close and self.stall_victim == null) {
                self.stall_victim = side.index;
                self.pipes[1 - side.index].cut();
            }
        } else |err| switch (err) {
            error.QueueFull => try self.count_refusal(side, err),
            error.TooLarge => try self.count_refusal(side, err),
            else => return self.fail(.close, "send_close failed: {s}", .{@errorName(err)}),
        }
        assert(side.close != null or side.refused > 0);
    }

    fn count_refusal(self: *World, side: *Side, err: ws.conn.SendError) Violation!void {
        assert(err == error.QueueFull or err == error.TooLarge);
        side.refused += 1;
        self.totals.refused += 1;
        assert(self.totals.refused >= side.refused);
    }

    fn start_message(self: *World, side: *Side) Violation!void {
        assert(side.frag == null and side.conn.is_open());
        if (side.sent.count + 2 > ring_capacity) return;
        const peer = self.other(side);
        const part_max = side.send_len - 14;
        const limit = @min(peer.message_max, part_max * 8);
        const length = self.pick_length(limit);
        const kind: MessageKind = if (self.random().boolean()) .text else .binary;
        const seed = self.random().int(u64);
        wire.payload_fill(side.payload[0..length], seed, kind == .text);
        side.frag = .{
            .kind = kind,
            .seed = seed,
            .length = length,
            .offset = 0,
            .parts_left = self.random().intRangeAtMost(u8, 1, 4),
        };
        try self.continue_fragment(side);
        assert(side.frag != null or side.sent.count > 0);
    }

    fn pick_length(self: *World, limit: u32) u32 {
        assert(limit <= message_cap);
        const roll = self.random().uintLessThan(u8, 100);
        var length: u32 = 0;
        if (roll < 10) {
            length = @min(self.pick(u32, &.{ 0, 1, 125, 126, 127, 65535, 65536 }), limit);
        } else if (roll < 60) {
            length = self.random().uintLessThan(u32, @min(limit, 125) + 1);
        } else if (roll < 85) {
            length = self.random().uintLessThan(u32, @min(limit, 1000) + 1);
        } else length = self.random().uintLessThan(u32, @min(limit, 9000) + 1);
        assert(length <= limit);
        return length;
    }

    fn continue_fragment(self: *World, side: *Side) Violation!void {
        assert(side.frag != null and side.frag.?.offset <= side.frag.?.length);
        var frag = side.frag.?;
        const part_max = side.send_len - 14;
        const remaining = frag.length - frag.offset;
        var take = remaining;
        if (frag.parts_left > 1 and remaining > 1) {
            take = self.random().intRangeAtMost(u32, 1, @min(remaining, part_max));
            frag.parts_left -= 1;
        } else take = @min(remaining, part_max);
        const fin = take == remaining;
        const before = side.conn.stats.bytes_out;
        const payload = side.payload[frag.offset..][0..take];
        if (side.conn.send_fragment(frag.kind, payload, fin)) |_| {
            try self.after_fragment(side, &frag, take, fin, before);
        } else |err| switch (err) {
            error.QueueFull => try self.refused_fragment(side, err, take),
            else => return self.fail(.limits, "send_fragment gave {s}", .{@errorName(err)}),
        }
        assert(side.conn.queued() <= side.send_len);
    }

    fn frame_total(side: *const Side, payload_len: u32) u32 {
        assert(payload_len <= message_cap);
        assert(side.index < 2);
        const extra: u32 = if (payload_len < 126) 0 else if (payload_len < 65536) 2 else 8;
        return 2 + extra + (if (side.index == 0) @as(u32, 4) else 0) + payload_len;
    }

    fn refused_fragment(
        self: *World,
        side: *Side,
        err: ws.conn.SendError,
        take: u32,
    ) Violation!void {
        assert(err == error.QueueFull or err == error.TooLarge);
        const total = frame_total(side, take);
        const room = side.send_len - side.conn.queued();
        if (total <= room and !side.conn.pending_control()) {
            return self.fail(.limits, "refused with room: need {d} have {d}", .{ total, room });
        }
        try self.count_refusal(side, err);
        assert(side.refused > 0);
    }

    fn after_fragment(
        self: *World,
        side: *Side,
        frag: *Frag,
        take: u32,
        fin: bool,
        before: u64,
    ) Violation!void {
        assert(take <= frag.length - frag.offset);
        const total = frame_total(side, take);
        if (side.conn.stats.bytes_out < before + total) {
            return self.fail(.limits, "accepted send queued fewer than {d} bytes", .{total});
        }
        frag.offset += take;
        if (!fin) {
            side.frag = frag.*;
            return;
        }
        assert(frag.offset == frag.length);
        const kind: Kind = if (frag.kind == .text) .text else .binary;
        side.sent.push(.{ .kind = kind, .length = frag.length, .seed = frag.seed });
        side.frag = null;
        self.totals.messages += 1;
        self.totals.message_bytes += frag.length;
        assert(side.sent.count > 0);
    }

    fn send_ping(self: *World, side: *Side) Violation!void {
        assert(side.conn.is_open() and side.pongs.count <= ring_capacity);
        if (side.sent.count + 2 > ring_capacity or side.pongs.count + 2 > ring_capacity) return;
        const length = self.random().uintLessThan(u32, 126);
        const item = Item{ .kind = .ping, .length = length, .seed = self.random().int(u64) };
        var buffer: [125]u8 = undefined;
        wire.payload_fill(buffer[0..length], item.seed, false);
        if (side.conn.send_ping(buffer[0..length])) |_| {
            side.sent.push(item);
            side.pongs.push(item);
            self.totals.pings += 1;
        } else |err| switch (err) {
            error.QueueFull => try self.refused_fragment(side, err, length),
            else => return self.fail(.ping, "send_ping failed: {s}", .{@errorName(err)}),
        }
        assert(side.conn.queued() <= side.send_len);
    }

    fn chunk_limit(self: *World) u32 {
        assert(self.chunk_bias < 4);
        const roll = self.random().uintLessThan(u8, 100);
        var limit: u32 = 0;
        if (self.chunk_bias == 0) {
            limit = if (roll < 70) 1 else 4000;
        } else if (self.chunk_bias == 3 or roll >= 75) {
            limit = self.random().intRangeAtMost(u32, 2001, 70000);
        } else if (roll < 12) {
            limit = 1;
        } else if (roll < 30) {
            limit = self.random().intRangeAtMost(u32, 2, 16);
        } else if (roll < 50) {
            limit = self.random().intRangeAtMost(u32, 17, 200);
        } else limit = self.random().intRangeAtMost(u32, 201, 2000);
        assert(limit >= 1 and limit <= 70000);
        return limit;
    }

    fn pump(self: *World, index: u8) Violation!void {
        assert(index < 2);
        assert(self.pipes[index].written >= self.pipes[index].delivered);
        const side = &self.sides[index];
        const pipe = &self.pipes[index];
        const out = side.conn.output();
        if (out.len == 0 or pipe.space() == 0) return;
        if (self.old[index].log.count > old_log_high) return;
        const count: u32 = @min(@as(u32, @intCast(out.len)), pipe.space(), self.chunk_limit());
        self.old[index].feed(out[0..count]) catch |err| {
            return self.fail(.cross_old, "old Reader refused side {d}: {s}", .{
                index, @errorName(err),
            });
        };
        const delay = self.random().uintLessThan(u64, self.delay_max + 1);
        pipe.push(out[0..count], self.now + delay);
        side.conn.output_taken(count);
        self.totals.bytes += count;
        self.trace.mix(count);
    }

    fn deliver(self: *World, index: u8) Violation!void {
        assert(index < 2);
        assert(self.pipes[index].written >= self.pipes[index].delivered);
        const pipe = &self.pipes[index];
        const receiver = &self.sides[1 - index];
        var limit = self.chunk_limit();
        if (self.scenario == .cut) {
            const total = self.pipes[0].delivered + self.pipes[1].delivered;
            if (total >= self.cut_at) return self.do_cut();
            limit = @intCast(@min(limit, self.cut_at - total));
        }
        const chunk = pipe.peek(self.now, limit) orelse return;
        const accepted = receiver.conn.feed(chunk);
        if (accepted > 0) pipe.consume(accepted);
        self.trace.mix(accepted);
        try self.drain(receiver);
    }

    fn do_cut(self: *World) Violation!void {
        assert(self.scenario == .cut and !self.ended);
        assert(self.cut_at <= self.pipes[0].delivered + self.pipes[1].delivered);
        for (&self.pipes) |*pipe| pipe.cut();
        for (&self.sides, 0..) |*side, index| {
            try self.drain(side);
            const expected = self.expected_eof(side);
            const got = side.conn.end_of_input();
            self.eofs[index] = got;
            self.totals.eof[@backingInt(got)] += 1;
            if (got != expected) {
                return self.fail(.eof, "side {d} end of input gave {s}, expected {s}", .{
                    index, @tagName(got), @tagName(expected),
                });
            }
        }
        self.ended = true;
    }

    fn expected_eof(self: *World, side: *Side) ws.conn.Eof {
        assert(side.index < 2);
        assert(self.pipes[1 - side.index].scanner.bytes == self.pipes[1 - side.index].delivered);
        const incoming = &self.pipes[1 - side.index].scanner;
        if (side.closed_event) return .clean;
        if (side.conn.failure != null) return .failed;
        if (!incoming.head_done) return .in_handshake;
        if (side.close != null) return .during_close;
        if (!incoming.at_boundary()) return .in_frame;
        if (incoming.message_open) return .in_message;
        return .without_close;
    }

    fn drain(self: *World, side: *Side) Violation!void {
        assert(side.index < 2);
        assert(side.conn.stats.bytes_in >= side.conn.stats.messages_in);
        for (0..drain_max) |_| {
            const polled = side.conn.poll() catch |err| {
                try self.on_error(side, err);
                return;
            };
            const event = polled orelse return;
            try self.on_event(side, event);
        }
        return self.fail(.liveness, "poll produced {d} events in a row", .{drain_max});
    }

    fn on_event(self: *World, side: *Side, event: ws.conn.Event) Violation!void {
        switch (event) {
            .opened => |opened| try self.on_opened(side, opened.target),
            .message => |message| try self.on_message(side, message),
            .ping => |data| try self.on_ping(side, data),
            .pong => |data| try self.on_pong(side, data),
            .closed => |closed| try self.on_closed(side, closed),
        }
    }

    fn on_opened(self: *World, side: *Side, target: []const u8) Violation!void {
        assert(target.len <= 40 and !side.conn.is_done());
        assert(side.index < 2);
        if (side.opened) return self.fail(.handshake, "side {d} opened twice", .{side.index});
        side.opened = true;
        const client = &self.sides[0];
        const expect = if (side.index == 1) client.target[0..client.target_len] else "";
        if (!std.mem.eql(u8, target, expect)) {
            return self.fail(.handshake, "request target changed on the way", .{});
        }
        self.trace.mix(@as(u64, 0x1000) | side.index);
        self.trace.mix_bytes(target);
    }

    fn cross_compare(self: *World, side: *Side, tag: u8, data: []const u8) Violation!void {
        assert(tag >= 1 and tag <= 10);
        assert(side.index < 2 and data.len <= message_cap);
        const old = &self.old[1 - side.index];
        const record = old.log.front() orelse {
            return self.fail(.cross_old, "old Reader decoded nothing for tag {d}", .{tag});
        };
        const same = record.tag == tag and record.length == data.len;
        if (!same or record.hash != core.hash_bytes(data)) {
            return self.fail(.cross_old, "old Reader and Conn disagree on tag {d}", .{tag});
        }
        old.log.pop();
        self.trace.mix(@as(u64, tag) << 32 | data.len);
        self.trace.mix(record.hash);
    }

    fn expect_payload(self: *World, item: Item, data: []const u8) bool {
        assert(item.length <= message_cap);
        assert(data.len <= message_cap);
        if (item.length != data.len) return false;
        const expected = self.scratch[0..item.length];
        wire.payload_fill(expected, item.seed, item.kind == .text);
        return std.mem.eql(u8, expected, data);
    }

    fn on_message(self: *World, side: *Side, message: ws.conn.Message) Violation!void {
        assert(message.data.len <= side.message_max);
        assert(side.opened);
        const peer = self.other(side);
        const item = peer.sent.front() orelse {
            return self.fail(.delivery, "side {d} delivered an unsent message", .{side.index});
        };
        const want: ws.conn.MessageKind = if (item.kind == .text) .text else .binary;
        const changed = item.kind == .ping or want != message.kind;
        if (changed or !self.expect_payload(item, message.data)) {
            return self.fail(.delivery, "side {d} changed a message (len {d}, expected {d})", .{
                side.index, message.data.len, item.length,
            });
        }
        peer.sent.pop();
        try self.cross_compare(side, if (message.kind == .text) 1 else 2, message.data);
    }

    fn on_ping(self: *World, side: *Side, data: []const u8) Violation!void {
        assert(data.len <= 125);
        assert(side.opened);
        const peer = self.other(side);
        const item = peer.sent.front() orelse {
            return self.fail(.ping, "side {d} delivered a ping nobody sent", .{side.index});
        };
        if (item.kind != .ping or !self.expect_payload(item, data)) {
            return self.fail(.ping, "side {d} delivered a changed ping", .{side.index});
        }
        peer.sent.pop();
        if (side.close != null) peer.forgiven += 1;
        try self.cross_compare(side, 9, data);
    }

    fn on_pong(self: *World, side: *Side, data: []const u8) Violation!void {
        assert(data.len <= 125);
        assert(side.skipped <= self.other(side).conn.stats.pongs_coalesced + side.forgiven);
        const coalesced = self.other(side).conn.stats.pongs_coalesced;
        const allowance = coalesced + side.forgiven - side.skipped;
        var skip: u32 = 0;
        while (skip <= allowance and skip < side.pongs.count) : (skip += 1) {
            if (!self.expect_payload(side.pongs.at(skip), data)) continue;
            for (0..skip + 1) |_| side.pongs.pop();
            side.skipped += skip;
            return self.cross_compare(side, 10, data);
        }
        return self.fail(.ping, "side {d} got a pong with no matching ping", .{side.index});
    }

    fn on_closed(self: *World, side: *Side, closed: ws.conn.Closed) Violation!void {
        assert(closed.reason.len <= 123);
        assert(side.conn.state == .closed);
        if (side.closed_event) return self.fail(.close, "side {d} closed twice", .{side.index});
        side.closed_event = true;
        const peer = self.other(side);
        var code: u16 = 0;
        var reason: []const u8 = "";
        if (peer.close) |explicit| {
            code = explicit.code orelse ws.conn.code_none;
            reason = explicit.reason[0..explicit.reason_len];
        } else if (side.close) |mine| {
            code = mine.code orelse ws.conn.code_none;
        } else return self.fail(.close, "side {d} closed with nobody closing", .{side.index});
        if (closed.code != code or !std.mem.eql(u8, closed.reason, reason)) {
            return self.fail(.close, "side {d} close was {d}, expected {d}", .{
                side.index, closed.code, code,
            });
        }
        var payload: [125]u8 = undefined;
        var length: usize = 0;
        if (code != ws.conn.code_none) {
            std.mem.writeInt(u16, payload[0..2], code, .big);
            @memcpy(payload[2..][0..reason.len], reason);
            length = 2 + reason.len;
        }
        try self.cross_compare(side, 8, payload[0..length]);
    }

    fn check_invariants(self: *World) Violation!void {
        assert(self.sides[0].recv.declared == self.sides[1].recv.declared);
        assert(self.sides[0].index == 0 and self.sides[1].index == 1);
        for (&self.sides) |*side| {
            if (!side.recv.intact() or !side.message.intact() or !side.send.intact()) {
                return self.fail(.canary, "side {d} wrote outside storage", .{side.index});
            }
            const stats = &side.conn.stats;
            const declared = side.recv.declared;
            if (stats.recv_high > declared or stats.message_high > side.message.declared or
                stats.send_high > side.send.declared)
            {
                return self.fail(.limits, "side {d} used more than declared", .{side.index});
            }
            try self.check_quiet(side);
        }
    }

    fn check_quiet(self: *World, side: *Side) Violation!void {
        assert(side.index < 2);
        assert(side.conn.failure == null or side.conn.is_done());
        if (!side.conn.is_done()) return;
        const polled = side.conn.poll() catch {
            return self.fail(.quiet, "side {d} raised an error when done", .{side.index});
        };
        if (polled != null) return self.fail(.quiet, "side {d} delivered when done", .{side.index});
        if (side.conn.pending_control()) return;
        const produced = side.conn.stats.bytes_out;
        const before = side.quiet_bytes orelse {
            side.quiet_bytes = produced;
            return;
        };
        if (before != produced) {
            return self.fail(.quiet, "side {d} produced bytes when done", .{side.index});
        }
    }

    pub fn init(self: *World) void {
        self.report = .{};
        self.totals = .{};
        self.trace = .{};
        self.eofs = .{ .clean, .clean };
        self.ended = false;
        assert(self.report.checker == null and self.totals.sessions == 0);
        assert(self.eofs[0] == .clean and self.eofs[1] == .clean);
    }

    fn finish(self: *World) Violation!void {
        assert(self.report.checker == null);
        assert(self.sides[0].conn.is_done() and self.sides[1].conn.is_done());
        if (!self.ended) {
            switch (self.scenario) {
                .stall_handshake => try self.finish_stalled_handshake(),
                .stall_close => try self.finish_stall_close(),
                .graceful, .cut => try self.finish_graceful(),
            }
        }
        for (&self.sides) |*side| {
            if (side.refused != side.conn.stats.sends_refused) {
                return self.fail(.limits, "side {d} counted {d} refusals, Conn {d}", .{
                    side.index, side.refused, side.conn.stats.sends_refused,
                });
            }
            self.totals.coalesced += side.conn.stats.pongs_coalesced;
            self.totals.pongs += side.conn.stats.pongs_in;
        }
        for (&self.old) |*old| self.totals.old_messages += old.messages;
        assert(self.totals.sessions > 0);
    }

    fn expect_eof(self: *World, side: *Side, want: ws.conn.Eof) Violation!void {
        assert(side.conn.state != .ended);
        assert(side.index < 2);
        const got = side.conn.end_of_input();
        self.eofs[side.index] = got;
        self.totals.eof[@backingInt(got)] += 1;
        if (got != want) {
            return self.fail(.eof, "side {d} end of input gave {s}, expected {s}", .{
                side.index, @tagName(got), @tagName(want),
            });
        }
    }

    fn finish_stalled_handshake(self: *World) Violation!void {
        assert(self.scenario == .stall_handshake);
        assert(self.sides[0].conn.state == .failed and self.sides[1].conn.state == .failed);
        for (&self.sides) |*side| {
            if (!timed_out(&side.conn)) {
                return self.fail(.liveness, "side {d} did not time out", .{side.index});
            }
            try self.expect_eof(side, .failed);
        }
    }

    fn finish_stall_close(self: *World) Violation!void {
        assert(self.scenario == .stall_close);
        assert(self.stall_victim == null or self.stall_victim.? < 2);
        const victim_index = self.stall_victim orelse {
            return self.fail(.liveness, "stall scenario ended without a close", .{});
        };
        const victim = &self.sides[victim_index];
        const peer = self.other(victim);
        if (!timed_out(&victim.conn) or victim.sent.count != 0) {
            return self.fail(.liveness, "closing side did not time out cleanly", .{});
        }
        if (peer.conn.state != .closed or !peer.closed_event) {
            return self.fail(.close, "peer of a stalled close did not close", .{});
        }
        try self.expect_eof(victim, .failed);
        try self.expect_eof(peer, .clean);
    }

    fn finish_graceful(self: *World) Violation!void {
        assert(!self.ended);
        assert(self.scenario != .stall_handshake and self.scenario != .stall_close);
        for (&self.sides) |*side| {
            const peer = self.other(side);
            if (side.conn.state != .closed or !side.closed_event) {
                return self.fail(.close, "side {d} ended in state {s}", .{
                    side.index, @tagName(side.conn.state),
                });
            }
            if (side.sent.count != 0) {
                return self.fail(.delivery, "side {d} has {d} messages never delivered", .{
                    side.index, side.sent.count,
                });
            }
            if (side.pongs.count > peer.conn.stats.pongs_coalesced + side.forgiven - side.skipped) {
                return self.fail(.ping, "side {d} has unanswered pings", .{side.index});
            }
            if (side.conn.stats.bytes_out != peer.conn.stats.bytes_in) {
                return self.fail(.delivery, "byte counts differ for side {d}", .{side.index});
            }
            if (side.conn.stats.messages_out != peer.conn.stats.messages_in) {
                return self.fail(.delivery, "message counts differ for side {d}", .{side.index});
            }
            if (self.old[side.index].log.count != 0) {
                return self.fail(.cross_old, "old Reader saw frames nobody delivered", .{});
            }
        }
        for (&self.sides) |*side| try self.expect_eof(side, .clean);
    }
};
