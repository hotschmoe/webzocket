const std = @import("std");
const ws = @import("webzocket");
const assert = @import("assert").assert;
const core = @import("sim_core.zig");
const wire = @import("sim_wire.zig");
const generate = @import("fuzz_generate.zig");

const Conn = ws.conn.Conn;
const Error = ws.conn.Error;
const Violation = core.Violation;

const recv_len: u32 = 8192;
const message_len: u32 = generate.input_max;
const send_len: u32 = 4096;
const events_max: u32 = 1 << 16;

const Verdict = struct {
    failure: ?Error = null,
    events: u32 = 0,
    mismatch: bool = false,
    opened: bool = false,
    accept_ok: bool = false,
};

const Row = struct {
    cases: u64 = 0,
    old_accept: u64 = 0,
    conn_accept: u64 = 0,
    stricter: u64 = 0,
    both_reject: u64 = 0,
    looser: u64 = 0,
    last_error: [24]u8 = @splat(0),
};

fn error_name(err: ?Error) []const u8 {
    return if (err) |value| @errorName(value) else "none";
}

fn mask_error(err: Error) bool {
    return err == error.MaskRequired or err == error.MaskForbidden;
}

fn mapped(old: anyerror) []const Error {
    if (old == error.LargeControl) return &.{error.ControlTooLong};
    if (old == error.ReservedFlags or old == error.CompressionError) return &.{error.ReservedBits};
    if (old == error.InvalidMessageType) return &.{error.BadOpcode};
    if (old == error.FragmentedControl) return &.{error.ControlFragmented};
    if (old == error.UnfragmentedContinuation) return &.{error.UnexpectedContinuation};
    if (old == error.NestedFragment) return &.{error.ExpectedContinuation};
    if (old == error.TooLarge) return &.{ error.MessageTooLarge, error.LengthMsb };
    assert(old != error.TooLarge);
    assert(old != error.ReservedFlags and old != error.LargeControl);
    return &.{};
}

fn stricter_allowed(class: u8, err: Error) bool {
    assert(class < generate.classes);
    if (mask_error(err)) return true;
    const close_errors = err == error.BadCloseCode or err == error.InvalidUtf8 or
        err == error.BadClosePayload;
    assert(!mask_error(err));
    return switch (class) {
        12...17 => close_errors,
        31, 83 => err == error.ReservedBits,
        37, 38 => err == error.NonMinimalLength,
        40, 41 => err == error.InvalidUtf8,
        42 => err == error.BadCloseCode,
        43 => err == error.BadClosePayload,
        else => false,
    };
}

fn close_matches(closed: ws.conn.Closed, payload: []const u8) bool {
    assert(payload.len <= 125);
    assert(closed.reason.len <= 123);
    if (payload.len < 2) return closed.code == ws.conn.code_none and closed.reason.len == 0;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    return closed.code == code and std.mem.eql(u8, closed.reason, payload[2..]);
}

fn note_error(row: *Row, err: ?Error) void {
    assert(row.cases > 0);
    const text = error_name(err);
    const length = @min(text.len, row.last_error.len - 1);
    row.last_error = @splat(0);
    @memcpy(row.last_error[0..length], text[0..length]);
    assert(row.last_error[row.last_error.len - 1] == 0);
}

pub const Corpus = struct {
    case: generate.Case,
    recv: core.Region(recv_len),
    message: core.Region(message_len),
    send: core.Region(send_len),
    rows: [generate.classes]Row,
    prng: std.Random.DefaultPrng,
    cases: u64,
    output: [send_len]u8,
    output_len: u32,
    report: *core.Report,

    pub fn init(self: *Corpus) void {
        self.rows = @splat(.{});
        self.cases = 0;
        assert(self.rows[0].cases == 0);
        assert(self.cases == 0);
    }

    fn fail(
        self: *Corpus,
        checker: core.Checker,
        comptime format: []const u8,
        args: anytype,
    ) Violation {
        return self.report.fail(checker, format, args);
    }

    fn random_chunk(self: *Corpus, remaining: u32) u32 {
        assert(remaining > 0);
        const random = self.prng.random();
        const roll = random.uintLessThan(u8, 10);
        var wanted = random.intRangeAtMost(u32, 41, 9000);
        if (roll < 6) wanted = random.intRangeAtMost(u32, 2, 40);
        if (roll < 3) wanted = 1;
        const chunk = @min(wanted, remaining);
        assert(chunk >= 1 and chunk <= remaining);
        return chunk;
    }

    fn open(self: *Corpus, conn: *Conn, role: ws.conn.Role) Violation!void {
        assert(conn.state == .handshake);
        var key_raw: [16]u8 = @splat(7);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_raw);
        var buffer: [512]u8 = undefined;
        var length: u32 = 0;
        if (role == .client) {
            conn.start_client("corpus", "/", &key_raw) catch {
                return self.fail(.handshake, "corpus start_client failed", .{});
            };
            length = wire.reply_text(&buffer, &key);
        } else length = wire.request_text(&buffer, "/", &key, "corpus");
        try self.feed_all(conn, buffer[0..length], &.{}, null);
        assert(conn.is_open());
    }

    fn feed_all(
        self: *Corpus,
        conn: *Conn,
        bytes: []const u8,
        expected: []const generate.Message,
        verdict: ?*Verdict,
    ) Violation!void {
        assert(bytes.len <= generate.input_max);
        var position: u32 = 0;
        for (0..bytes.len * 2 + 4) |_| {
            if (position >= bytes.len) break;
            const want = self.random_chunk(@intCast(bytes.len - position));
            const accepted = conn.feed(bytes[position..][0..want]);
            position += accepted;
            const progressed = self.drain(conn, expected, verdict);
            self.take_output(conn);
            if (accepted == 0 and !progressed) return self.fail(.liveness, "corpus stalled", .{});
        }
        _ = self.drain(conn, expected, verdict);
        self.take_output(conn);
        assert(position == bytes.len);
    }

    fn take_output(self: *Corpus, conn: *Conn) void {
        assert(self.output_len <= send_len);
        const out = conn.output();
        const count: u32 = @intCast(@min(out.len, send_len - self.output_len));
        @memcpy(self.output[self.output_len..][0..count], out[0..count]);
        self.output_len += count;
        conn.output_taken(@intCast(out.len));
        assert(self.output_len <= send_len);
    }

    fn drain(
        self: *Corpus,
        conn: *Conn,
        expected: []const generate.Message,
        verdict: ?*Verdict,
    ) bool {
        assert(expected.len <= self.case.messages.len);
        var progressed = false;
        for (0..events_max) |_| {
            const polled = conn.poll() catch |err| {
                if (verdict) |value| value.failure = err;
                return true;
            };
            const event = polled orelse return progressed;
            progressed = true;
            const value = verdict orelse continue;
            if (!self.event_matches(event, expected, value)) value.mismatch = true;
        }
        assert(progressed);
        return progressed;
    }

    fn event_matches(
        self: *Corpus,
        event: ws.conn.Event,
        expected: []const generate.Message,
        verdict: *Verdict,
    ) bool {
        assert(verdict.events <= expected.len + 1);
        assert(expected.len <= self.case.messages.len);
        if (event == .opened) {
            verdict.opened = true;
            return true;
        }
        if (verdict.events >= expected.len) return false;
        const want = expected[verdict.events];
        verdict.events += 1;
        const payload = self.case.payload[want.offset..][0..want.length];
        return switch (event) {
            .message => |message| want.opcode == (if (message.kind == .text) @as(u8, 1) else 2) and
                std.mem.eql(u8, message.data, payload),
            .ping => |data| want.opcode == 9 and std.mem.eql(u8, data, payload),
            .pong => |data| want.opcode == 10 and std.mem.eql(u8, data, payload),
            .closed => |closed| want.opcode == 8 and close_matches(closed, payload),
            .opened => unreachable,
        };
    }

    fn run_frames(self: *Corpus, role: ws.conn.Role) Violation!Verdict {
        const case = &self.case;
        assert(!case.handshake and case.count <= case.messages.len);
        var maximum: u32 = message_len;
        if (case.expected_error) |err| {
            if (err == error.TooLarge and case.maximum < generate.input_max) maximum = case.maximum;
        }
        var conn = ws.conn.Conn.init(.{
            .role = role,
            .recv = self.recv.arm(recv_len),
            .message = self.message.arm(maximum),
            .send = self.send.arm(send_len),
            .mask_seed = @splat(0x5a),
        }, 0) catch return self.fail(.limits, "corpus init rejected a valid config", .{});
        assert(self.recv.declared == recv_len);
        self.output_len = 0;
        try self.open(&conn, role);
        var verdict = Verdict{};
        const expected = case.messages[0..case.count];
        try self.feed_all(&conn, case.bytes[0..case.length], expected, &verdict);
        verdict.accept_ok = verdict.failure == null and !verdict.mismatch and
            verdict.events == case.count;
        if (!self.recv.intact() or !self.message.intact() or !self.send.intact()) {
            return self.fail(.canary, "corpus run wrote outside declared storage", .{});
        }
        return verdict;
    }

    fn check_frame_case(self: *Corpus) Violation!void {
        const class = self.case.class;
        assert(class < generate.classes and !self.case.handshake);
        const row = &self.rows[class];
        const results = [2]Verdict{ try self.run_frames(.server), try self.run_frames(.client) };
        row.cases += 1;
        for (results) |verdict| note_error(row, verdict.failure);
        switch (self.case.outcome) {
            .accept => try self.check_accepted(row, results),
            .rejected => try self.check_rejected(row, results),
            .incomplete => for (results) |verdict| {
                const err = verdict.failure orelse continue;
                if (!mask_error(err)) {
                    return self.fail(.cross_old, "class {d}: truncated frame failed: {s}", .{
                        class, @errorName(err),
                    });
                }
            },
        }
        assert(row.cases > 0);
    }

    fn check_accepted(self: *Corpus, row: *Row, results: [2]Verdict) Violation!void {
        const class = self.case.class;
        assert(self.case.outcome == .accept);
        row.old_accept += 1;
        if (results[0].accept_ok or results[1].accept_ok) {
            row.conn_accept += 1;
            return;
        }
        row.stricter += 1;
        for (results) |verdict| {
            const err = verdict.failure orelse {
                return self.fail(.cross_old, "class {d}: Conn changed a message", .{class});
            };
            if (!stricter_allowed(class, err)) {
                return self.fail(.cross_old, "class {d}: unexplained rejection {s}", .{
                    class, @errorName(err),
                });
            }
        }
        assert(row.stricter <= row.old_accept);
    }

    fn check_rejected(self: *Corpus, row: *Row, results: [2]Verdict) Violation!void {
        const class = self.case.class;
        const old = self.case.expected_error.?;
        assert(self.case.outcome == .rejected);
        var matched = false;
        for (results) |verdict| {
            const err = verdict.failure orelse {
                return self.fail(.cross_old, "class {d}: Conn accepted old reject {s}", .{
                    class, @errorName(old),
                });
            };
            for (mapped(old)) |want| matched = matched or err == want;
        }
        if (!matched) {
            return self.fail(.cross_old, "class {d}: Conn never reported {s}", .{
                class, @errorName(old),
            });
        }
        row.both_reject += 1;
        assert(row.both_reject <= row.cases);
    }

    fn check_handshake_case(self: *Corpus) Violation!void {
        const case = &self.case;
        assert(case.handshake and case.class < generate.classes);
        const row = &self.rows[case.class];
        var conn = ws.conn.Conn.init(.{
            .role = .server,
            .recv = self.recv.arm(recv_len),
            .message = self.message.arm(16),
            .send = self.send.arm(send_len),
        }, 0) catch return self.fail(.limits, "corpus init rejected a valid config", .{});
        var verdict = Verdict{};
        self.output_len = 0;
        try self.feed_all(&conn, case.bytes[0..case.length], &.{}, &verdict);
        row.cases += 1;
        note_error(row, verdict.failure);
        if (verdict.opened) try self.check_reply();
        try self.judge_handshake(row, verdict);
        assert(row.cases > 0);
    }

    fn judge_handshake(self: *Corpus, row: *Row, verdict: Verdict) Violation!void {
        const case = &self.case;
        assert(row.cases > 0);
        assert(verdict.opened or verdict.failure != null or case.outcome == .incomplete);
        switch (case.outcome) {
            .accept => {
                row.old_accept += 1;
                if (verdict.opened) row.conn_accept += 1 else row.stricter += 1;
            },
            .rejected => {
                if (verdict.opened and case.class == 93) {
                    row.looser += 1;
                } else if (verdict.opened) {
                    return self.fail(.cross_old, "class {d}: Conn opened a reject", .{case.class});
                } else row.both_reject += 1;
            },
            .incomplete => if (verdict.opened) {
                return self.fail(.cross_old, "class {d}: Conn opened early", .{case.class});
            },
        }
    }

    fn check_reply(self: *Corpus) Violation!void {
        const case = &self.case;
        assert(self.output_len > 0);
        assert(self.output_len >= 129);
        if (case.key_length != 24) {
            return self.fail(.handshake, "class {d}: opened with a {d}-byte key", .{
                case.class, case.key_length,
            });
        }
        var buffer: [256]u8 = undefined;
        const length = wire.reply_text(&buffer, case.expected_key[0..24]);
        if (!std.mem.eql(u8, self.output[0..self.output_len], buffer[0..length])) {
            return self.fail(.handshake, "class {d}: reply lacks the accept key", .{case.class});
        }
    }

    pub fn run(self: *Corpus, report: *core.Report, seed: u64, count: u32) Violation!void {
        assert(count > 0);
        self.report = report;
        self.prng = std.Random.DefaultPrng.init(wire.mix64(seed, 0xc0));
        for (0..count) |number| {
            generate.generate(&self.case, seed, @intCast(number)) catch {
                return self.fail(.limits, "generator refused case {d}", .{number});
            };
            self.cases += 1;
            if (self.case.handshake) {
                try self.check_handshake_case();
            } else try self.check_frame_case();
        }
        assert(self.cases >= count);
    }
};
