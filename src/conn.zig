const std = @import("std");
const assert = @import("assert").assert;
const frame = @import("conn_frame.zig");
const handshake = @import("conn_handshake.zig");
const utf8 = @import("conn_utf8.zig");

pub const Role = frame.Role;
pub const MessageKind = enum(u8) { text, binary };
pub const code_none: u16 = 1005;
pub const recv_min: u32 = 64;

pub const SendError = error{
    QueueFull,
    TooLarge,
    NotOpen,
    Closing,
    MessageInProgress,
    FragmentMismatch,
    InvalidUtf8,
    InvalidCloseCode,
    InvalidCloseReason,
};

pub const Error = frame.FrameError || handshake.HandshakeError || error{
    UnexpectedContinuation,
    ExpectedContinuation,
    MessageTooLarge,
    InvalidUtf8,
    BadClosePayload,
    BadCloseCode,
    Timeout,
    QueueFull,
};

pub const Config = struct {
    role: Role,
    recv: []u8,
    message: []u8,
    send: []u8,
    handshake_timeout_ms: u32 = 0,
    close_timeout_ms: u32 = 0,
    mask_seed: [32]u8 = @splat(0),
};

pub const State = enum(u8) { handshake, open, closing, closed, failed, ended };
pub const Eof = enum(u8) {
    clean,
    failed,
    in_handshake,
    in_frame,
    in_message,
    without_close,
    during_close,
};

pub const Opened = struct { target: []const u8 };
pub const Message = struct { kind: MessageKind, data: []const u8 };
pub const Closed = struct { code: u16, reason: []const u8 };
pub const Event = union(enum) {
    opened: Opened,
    message: Message,
    ping: []const u8,
    pong: []const u8,
    closed: Closed,
};

pub const Stats = struct {
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    frames_in: u64 = 0,
    frames_out: u64 = 0,
    messages_in: u64 = 0,
    messages_out: u64 = 0,
    pings_in: u64 = 0,
    pongs_in: u64 = 0,
    pongs_out: u64 = 0,
    pongs_coalesced: u64 = 0,
    control_dropped: u64 = 0,
    sends_refused: u64 = 0,
    limit_hits: u64 = 0,
    ignored_bytes: u64 = 0,
    recv_high: u32 = 0,
    message_high: u32 = 0,
    send_high: u32 = 0,
};

const Current = struct { header: frame.Header, done: u32 };
const Step = union(enum) { need_input, progress, event: Event };

fn is_handshake_error(err: Error) bool {
    return switch (err) {
        error.HandshakeTooLarge, error.BadLineEnding, error.BadByte, error.BadRequestLine => true,
        error.BadMethod, error.BadTarget, error.BadHost, error.BadHttpVersion => true,
        error.BadHeader, error.DuplicateHeader, error.MissingHost, error.BadUpgrade => true,
        error.BadConnection, error.BadWebSocketVersion, error.BadKey, error.BadStatusLine => true,
        error.BadStatus, error.BadAccept, error.ExtensionNotOffered => true,
        error.SubprotocolNotOffered => true,
        else => false,
    };
}

fn close_code_for(err: Error) ?u16 {
    if (err == error.InvalidUtf8) return 1007;
    if (err == error.MessageTooLarge) return 1009;
    if (is_handshake_error(err)) return null;
    if (err == error.Timeout or err == error.QueueFull) return null;
    assert(err != error.HandshakeTooLarge and err != error.BadKey);
    return 1002;
}

pub const Conn = struct {
    role: Role,
    state: State,
    failure: ?Error,
    recv: []u8,
    recv_start: u32,
    recv_end: u32,
    head_scan: u32,
    message: []u8,
    message_len: u32,
    message_kind: MessageKind,
    message_open: bool,
    utf8_state: utf8.Utf8,
    send: []u8,
    send_start: u32,
    send_end: u32,
    current: ?Current,
    control: [frame.control_payload_max]u8,
    control_len: u8,
    pong: [frame.control_payload_max]u8,
    pong_len: u8,
    pong_pending: bool,
    close_pending: bool,
    close_pending_code: u16,
    out_kind: ?MessageKind,
    out_utf8: utf8.Utf8,
    close_sent: bool,
    key: [handshake.key_len]u8,
    key_ready: bool,
    deadline_ms: u64,
    close_timeout_ms: u32,
    masker: std.Random.ChaCha,
    stats: Stats,

    pub fn init(config: Config, now_ms: u64) error{InvalidConfig}!Conn {
        const limit: usize = std.math.maxInt(u32);
        if (config.recv.len < recv_min or config.recv.len > limit) return error.InvalidConfig;
        if (config.message.len > limit or config.send.len > limit) return error.InvalidConfig;
        const unseeded = std.mem.allEqual(u8, &config.mask_seed, 0);
        if (config.role == .client and unseeded) return error.InvalidConfig;
        assert(now_ms < std.math.maxInt(u64) - @as(u64, config.handshake_timeout_ms));
        const timeout = config.handshake_timeout_ms;
        const deadline = if (timeout == 0) 0 else now_ms + timeout;
        assert(config.recv.len >= recv_min);
        const conn: Conn = .{
            .role = config.role,
            .state = .handshake,
            .failure = null,
            .recv = config.recv,
            .recv_start = 0,
            .recv_end = 0,
            .head_scan = 0,
            .message = config.message,
            .message_len = 0,
            .message_kind = .binary,
            .message_open = false,
            .utf8_state = .{},
            .send = config.send,
            .send_start = 0,
            .send_end = 0,
            .current = null,
            .control = undefined,
            .control_len = 0,
            .pong = undefined,
            .pong_len = 0,
            .pong_pending = false,
            .close_pending = false,
            .close_pending_code = 0,
            .out_kind = null,
            .out_utf8 = .{},
            .close_sent = false,
            .key = undefined,
            .key_ready = false,
            .deadline_ms = deadline,
            .close_timeout_ms = config.close_timeout_ms,
            .masker = std.Random.ChaCha.init(config.mask_seed),
            .stats = .{},
        };
        assert(conn.state == .handshake and conn.failure == null);
        assert(conn.recv_end == 0 and conn.send_end == 0);
        return conn;
    }

    pub fn is_open(self: *const Conn) bool {
        return self.state == .open;
    }

    pub fn is_done(self: *const Conn) bool {
        return self.state == .closed or self.state == .failed or self.state == .ended;
    }

    pub fn pending_control(self: *const Conn) bool {
        return self.pong_pending or self.close_pending;
    }

    pub fn queued(self: *const Conn) u32 {
        assert(self.send_start <= self.send_end);
        assert(self.send_end <= self.send.len);
        return self.send_end - self.send_start;
    }

    pub fn start_client(
        self: *Conn,
        host: []const u8,
        target: []const u8,
        raw_key: *const [16]u8,
    ) (handshake.HandshakeError || SendError)!void {
        assert(self.role == .client and self.state == .handshake);
        assert(!self.key_ready);
        const total = try handshake.request_len(host, target);
        if (total > self.send.len) return self.refuse(error.TooLarge);
        if (!self.reserve(total)) return self.refuse(error.QueueFull);
        handshake.encode_key(raw_key, &self.key);
        const out = self.send[self.send_end..];
        const written = handshake.write_request(out, host, target, &self.key);
        assert(written == total);
        self.commit(total);
        self.key_ready = true;
        assert(self.queued() >= total and self.state == .handshake);
    }

    fn refuse(self: *Conn, err: SendError) SendError {
        assert(err == error.QueueFull or err == error.TooLarge);
        self.stats.sends_refused += 1;
        if (err == error.TooLarge) self.stats.limit_hits += 1;
        assert(self.stats.sends_refused >= self.stats.limit_hits);
        return err;
    }

    fn reserve(self: *Conn, need: u32) bool {
        assert(self.send_start <= self.send_end and self.send_end <= self.send.len);
        if (self.send_start == self.send_end) {
            self.send_start = 0;
            self.send_end = 0;
        }
        const capacity: u32 = @intCast(self.send.len);
        if (capacity - self.send_end >= need) return true;
        const held = self.send_end - self.send_start;
        if (capacity - held < need) return false;
        std.mem.copyForwards(u8, self.send[0..held], self.send[self.send_start..self.send_end]);
        self.send_start = 0;
        self.send_end = held;
        assert(capacity - self.send_end >= need);
        return true;
    }

    fn commit(self: *Conn, length: u32) void {
        assert(self.send_end + length <= self.send.len);
        self.send_end += length;
        self.stats.bytes_out += length;
        self.stats.send_high = @max(self.stats.send_high, self.send_end - self.send_start);
        assert(self.stats.send_high <= self.send.len);
    }

    pub fn output(self: *const Conn) []const u8 {
        return self.send[self.send_start..self.send_end];
    }

    pub fn output_taken(self: *Conn, count: u32) void {
        assert(count <= self.send_end - self.send_start);
        self.send_start += count;
        if (self.send_start == self.send_end) {
            self.send_start = 0;
            self.send_end = 0;
        }
        self.flush_pending();
        assert(self.send_start <= self.send_end);
    }

    fn frame_total(self: *const Conn, payload_len: usize) u64 {
        const masked = self.role == .client;
        return frame.header_len_for(payload_len, masked) + @as(u64, payload_len);
    }

    fn write_frame(self: *Conn, opcode: frame.Opcode, fin: bool, payload: []const u8) void {
        assert(self.send.len - self.send_end >= self.frame_total(payload.len));
        var header: [frame.header_max]u8 = undefined;
        var mask: ?[4]u8 = null;
        if (self.role == .client) {
            var key: [4]u8 = undefined;
            self.masker.random().bytes(&key);
            mask = key;
        }
        const header_len = frame.encode_header(&header, opcode, fin, payload.len, mask);
        const total: u32 = @intCast(header_len + payload.len);
        const out = self.send[self.send_end..][0..total];
        @memcpy(out[0..header_len], header[0..header_len]);
        if (mask) |key| {
            frame.copy_masked(out[header_len..], payload, key, 0);
        } else @memcpy(out[header_len..], payload);
        self.commit(total);
        self.stats.frames_out += 1;
        assert(self.send_end <= self.send.len);
    }

    fn queue_frame(
        self: *Conn,
        opcode: frame.Opcode,
        fin: bool,
        payload: []const u8,
    ) SendError!void {
        assert(self.state == .open);
        const total = self.frame_total(payload.len);
        if (total > self.send.len) return self.refuse(error.TooLarge);
        if (!self.reserve(@intCast(total))) return self.refuse(error.QueueFull);
        self.write_frame(opcode, fin, payload);
        assert(self.queued() >= total);
    }

    const Written = enum { written, full, never };

    fn try_write(self: *Conn, opcode: frame.Opcode, payload: []const u8) Written {
        assert(opcode.is_control());
        assert(payload.len <= frame.control_payload_max);
        const total = self.frame_total(payload.len);
        if (total > self.send.len) return .never;
        if (!self.reserve(@intCast(total))) return .full;
        self.write_frame(opcode, true, payload);
        assert(self.queued() >= total);
        return .written;
    }

    fn flush_pending(self: *Conn) void {
        assert(self.pong_len <= frame.control_payload_max);
        assert(self.close_pending_code == 0 or frame.close_code_valid(self.close_pending_code));
        if (self.pong_pending) {
            switch (self.try_write(.pong, self.pong[0..self.pong_len])) {
                .written => self.stats.pongs_out += 1,
                .never => self.stats.control_dropped += 1,
                .full => return,
            }
            self.pong_pending = false;
        }
        if (self.close_pending) {
            var payload: [2]u8 = undefined;
            std.mem.writeInt(u16, &payload, self.close_pending_code, .big);
            const body = if (self.close_pending_code == 0) payload[0..0] else payload[0..2];
            switch (self.try_write(.close, body)) {
                .written => {},
                .never => self.stats.control_dropped += 1,
                .full => return,
            }
            self.close_pending = false;
        }
        assert(self.send_end <= self.send.len);
    }

    pub fn recv_space(self: *Conn) []u8 {
        assert(self.recv_start <= self.recv_end);
        if (self.is_done()) return self.recv;
        if (self.recv_start == self.recv_end) {
            self.recv_start = 0;
            self.recv_end = 0;
        } else if (self.recv_start > 0) {
            const held = self.recv_end - self.recv_start;
            std.mem.copyForwards(u8, self.recv[0..held], self.recv[self.recv_start..self.recv_end]);
            self.recv_start = 0;
            self.recv_end = held;
        }
        assert(self.recv_end <= self.recv.len);
        return self.recv[self.recv_end..];
    }

    pub fn received(self: *Conn, count: u32) void {
        if (self.is_done()) {
            self.stats.ignored_bytes += count;
            return;
        }
        assert(count <= self.recv.len - self.recv_end);
        self.recv_end += count;
        self.stats.bytes_in += count;
        self.stats.recv_high = @max(self.stats.recv_high, self.recv_end - self.recv_start);
        assert(self.recv_start <= self.recv_end and self.recv_end <= self.recv.len);
    }

    pub fn feed(self: *Conn, bytes: []const u8) u32 {
        const space = self.recv_space();
        const count: u32 = @intCast(@min(bytes.len, space.len));
        assert(count <= bytes.len and count <= space.len);
        @memcpy(space[0..count], bytes[0..count]);
        self.received(count);
        if (self.is_done()) return @intCast(@min(bytes.len, std.math.maxInt(u32)));
        return count;
    }

    pub fn poll(self: *Conn) Error!?Event {
        assert(self.recv_start <= self.recv_end and self.recv_end <= self.recv.len);
        assert(self.failure == null or self.state == .failed or self.state == .ended);
        self.flush_pending();
        return switch (self.state) {
            .handshake => self.poll_handshake(),
            .open, .closing => self.poll_frames(),
            .closed, .failed, .ended => null,
        };
    }

    fn poll_handshake(self: *Conn) Error!?Event {
        assert(self.recv_start == 0 and self.state == .handshake);
        if (self.role == .client and !self.key_ready) return null;
        const buffered = self.recv[0..self.recv_end];
        const found = handshake.scan_head(buffered, &self.head_scan) catch |err| {
            return self.fail(err);
        };
        const head_end = found orelse {
            if (buffered.len == self.recv.len) {
                self.stats.limit_hits += 1;
                return self.fail(error.HandshakeTooLarge);
            }
            return null;
        };
        const head = buffered[0..head_end];
        var target: []const u8 = "";
        if (self.role == .server) {
            const request = handshake.parse_request(head) catch |err| return self.fail(err);
            if (!self.reserve(handshake.reply_len)) {
                self.stats.limit_hits += 1;
                return self.fail(error.QueueFull);
            }
            const length = handshake.write_reply(self.send[self.send_end..], &request.key);
            self.commit(length);
            target = request.target;
        } else {
            handshake.parse_reply(head, &self.key) catch |err| return self.fail(err);
        }
        self.recv_start = head_end;
        self.state = .open;
        self.deadline_ms = 0;
        assert(self.recv_start <= self.recv_end);
        assert(self.state == .open and self.head_scan == head_end);
        return .{ .opened = .{ .target = target } };
    }

    fn poll_frames(self: *Conn) Error!?Event {
        assert(self.state == .open or self.state == .closing);
        const bound = self.recv_end - self.recv_start + 1;
        assert(bound >= 1);
        for (0..bound) |_| {
            const next = self.step() catch |err| return self.fail(err);
            switch (next) {
                .need_input => return null,
                .progress => {},
                .event => |event| return event,
            }
        }
        @panic("poll_frames made no progress");
    }

    fn step(self: *Conn) Error!Step {
        assert(self.state == .open or self.state == .closing);
        assert(self.recv_start <= self.recv_end);
        if (self.current != null) return self.step_payload();
        return self.step_header();
    }

    fn check_header(self: *const Conn, header: frame.Header) Error!void {
        assert(header.payload_len >> 63 == 0);
        switch (header.opcode) {
            .continuation => if (!self.message_open) return error.UnexpectedContinuation,
            .text, .binary => if (self.message_open) return error.ExpectedContinuation,
            else => return,
        }
        const base: u64 = if (header.opcode == .continuation) self.message_len else 0;
        if (base + header.payload_len > self.message.len) return error.MessageTooLarge;
        assert(base <= self.message.len);
    }

    fn step_header(self: *Conn) Error!Step {
        assert(self.current == null);
        const available = self.recv[self.recv_start..self.recv_end];
        const parsed = try frame.parse_header(self.role, available);
        const header = parsed orelse return .need_input;
        self.check_header(header) catch |err| {
            if (err == error.MessageTooLarge) self.stats.limit_hits += 1;
            return err;
        };
        self.recv_start += header.header_len;
        self.stats.frames_in += 1;
        switch (header.opcode) {
            .text, .binary => {
                self.message_kind = if (header.opcode == .text) .text else .binary;
                self.message_len = 0;
                self.message_open = true;
                self.utf8_state = .{};
            },
            .continuation => {},
            else => self.control_len = @intCast(header.payload_len),
        }
        self.current = .{ .header = header, .done = 0 };
        assert(self.recv_start <= self.recv_end);
        if (header.payload_len == 0) return self.finish_frame();
        return .progress;
    }

    fn step_payload(self: *Conn) Error!Step {
        assert(self.current != null);
        const current = &self.current.?;
        const header = current.header;
        const available = self.recv_end - self.recv_start;
        if (available == 0) return .need_input;
        const left = header.payload_len - current.done;
        assert(left > 0 and left <= header.payload_len);
        const count: u32 = @intCast(@min(left, available));
        assert(count > 0 and count <= available);
        const source = self.recv[self.recv_start..][0..count];
        const control = header.opcode.is_control();
        const target = if (control)
            self.control[current.done..][0..count]
        else
            self.message[self.message_len..][0..count];
        if (header.mask) |key| {
            frame.copy_masked(target, source, key, current.done);
        } else @memcpy(target, source);
        if (!control and self.message_kind == .text and !self.utf8_state.feed(target)) {
            return error.InvalidUtf8;
        }
        self.recv_start += count;
        current.done += count;
        if (!control) {
            self.message_len += count;
            self.stats.message_high = @max(self.stats.message_high, self.message_len);
        }
        assert(current.done <= header.payload_len);
        if (current.done == header.payload_len) return self.finish_frame();
        return .progress;
    }

    fn finish_frame(self: *Conn) Error!Step {
        assert(self.current != null and self.current.?.done <= self.current.?.header.payload_len);
        const header = self.current.?.header;
        self.current = null;
        switch (header.opcode) {
            .text, .binary, .continuation => return self.finish_data(header.fin),
            .ping => return self.finish_ping(),
            .pong => {
                self.stats.pongs_in += 1;
                return .{ .event = .{ .pong = self.control[0..self.control_len] } };
            },
            .close => return self.finish_close(),
        }
    }

    fn finish_data(self: *Conn, fin: bool) Error!Step {
        assert(self.message_open);
        if (!fin) return .progress;
        if (self.message_kind == .text and !self.utf8_state.complete()) return error.InvalidUtf8;
        self.message_open = false;
        self.stats.messages_in += 1;
        assert(self.message_len <= self.message.len);
        const data = self.message[0..self.message_len];
        return .{ .event = .{ .message = .{ .kind = self.message_kind, .data = data } } };
    }

    fn finish_ping(self: *Conn) Error!Step {
        assert(self.control_len <= frame.control_payload_max);
        const payload = self.control[0..self.control_len];
        self.stats.pings_in += 1;
        if (self.close_sent) return .{ .event = .{ .ping = payload } };
        if (self.pong_pending) self.stats.pongs_coalesced += 1;
        @memcpy(self.pong[0..payload.len], payload);
        self.pong_len = self.control_len;
        self.pong_pending = true;
        self.flush_pending();
        assert(self.pong_pending or self.stats.pongs_out > 0 or self.stats.control_dropped > 0);
        return .{ .event = .{ .ping = payload } };
    }

    fn finish_close(self: *Conn) Error!Step {
        assert(self.control_len <= frame.control_payload_max);
        const payload = self.control[0..self.control_len];
        if (payload.len == 1) return error.BadClosePayload;
        var code: u16 = code_none;
        if (payload.len >= 2) {
            code = std.mem.readInt(u16, payload[0..2], .big);
            if (!frame.close_code_valid(code)) return error.BadCloseCode;
            if (!utf8.valid(payload[2..])) return error.InvalidUtf8;
        }
        if (!self.close_sent) {
            self.close_pending = true;
            self.close_pending_code = if (code == code_none) 0 else code;
            self.close_sent = true;
            self.flush_pending();
        }
        self.state = .closed;
        self.deadline_ms = 0;
        const reason = if (payload.len >= 2) payload[2..] else payload[0..0];
        assert(self.state == .closed and self.close_sent);
        return .{ .event = .{ .closed = .{ .code = code, .reason = reason } } };
    }

    fn fail(self: *Conn, err: Error) Error {
        assert(self.state == .handshake or self.state == .open or self.state == .closing);
        const before = self.state;
        self.state = .failed;
        self.failure = err;
        self.pong_pending = false;
        self.close_pending = false;
        self.deadline_ms = 0;
        if (before == .handshake and self.role == .server) {
            if (is_handshake_error(err) and self.reserve(handshake.rejection.len)) {
                const text = handshake.rejection;
                @memcpy(self.send[self.send_end..][0..text.len], text);
                self.commit(handshake.rejection.len);
            }
        } else if (before == .open and !self.close_sent) {
            self.queue_failure_close(close_code_for(err));
        }
        assert(self.state == .failed and self.failure != null);
        return err;
    }

    fn queue_failure_close(self: *Conn, code: ?u16) void {
        assert(self.state == .failed and !self.close_sent);
        const value = code orelse return;
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, value, .big);
        self.close_sent = true;
        if (self.try_write(.close, &payload) != .written) self.stats.control_dropped += 1;
        assert(self.close_sent);
    }

    pub fn tick(self: *Conn, now_ms: u64) Error!void {
        assert(self.deadline_ms == 0 or self.state == .handshake or self.state == .closing);
        const waiting = self.state == .handshake or self.state == .closing;
        if (waiting and self.deadline_ms != 0 and now_ms >= self.deadline_ms) {
            return self.fail(error.Timeout);
        }
        assert(self.failure == null or self.state == .failed);
    }

    fn require_open(self: *const Conn) SendError!void {
        switch (self.state) {
            .handshake => return error.NotOpen,
            .open => {},
            .closing, .closed, .failed, .ended => return error.Closing,
        }
    }

    pub fn send_message(self: *Conn, kind: MessageKind, payload: []const u8) SendError!void {
        if (self.out_kind != null) return error.MessageInProgress;
        const before = self.stats.messages_out;
        try self.send_fragment(kind, payload, true);
        assert(self.stats.messages_out == before + 1 and self.out_kind == null);
    }

    pub fn send_fragment(
        self: *Conn,
        kind: MessageKind,
        payload: []const u8,
        fin: bool,
    ) SendError!void {
        try self.require_open();
        assert(!self.close_sent);
        if (self.out_kind) |open_kind| if (open_kind != kind) return error.FragmentMismatch;
        if (!self.flush_clear()) return self.refuse(error.QueueFull);
        var check = if (self.out_kind == null) utf8.Utf8{} else self.out_utf8;
        if (kind == .text and !check.feed(payload)) return error.InvalidUtf8;
        if (kind == .text and fin and !check.complete()) return error.InvalidUtf8;
        const first = self.out_kind == null;
        const opcode: frame.Opcode = if (!first)
            .continuation
        else if (kind == .text)
            .text
        else
            .binary;
        try self.queue_frame(opcode, fin, payload);
        self.out_utf8 = check;
        self.out_kind = if (fin) null else kind;
        if (fin) self.stats.messages_out += 1;
        assert(fin == (self.out_kind == null));
    }

    fn flush_clear(self: *Conn) bool {
        assert(self.state == .open);
        self.flush_pending();
        const clear = !self.pong_pending and !self.close_pending;
        assert(self.queued() <= self.send.len);
        return clear;
    }

    pub fn send_ping(self: *Conn, payload: []const u8) SendError!void {
        try self.require_open();
        if (payload.len > frame.control_payload_max) return self.refuse(error.TooLarge);
        if (!self.flush_clear()) return self.refuse(error.QueueFull);
        try self.queue_frame(.ping, true, payload);
        assert(payload.len <= frame.control_payload_max);
    }

    pub fn send_close(
        self: *Conn,
        code: ?u16,
        reason: []const u8,
        now_ms: u64,
    ) SendError!void {
        try self.require_open();
        assert(!self.close_sent);
        if (code == null and reason.len != 0) return error.InvalidCloseReason;
        if (code) |value| if (!frame.close_code_valid(value)) return error.InvalidCloseCode;
        if (reason.len > frame.close_reason_max or !utf8.valid(reason)) {
            return error.InvalidCloseReason;
        }
        if (!self.flush_clear()) return self.refuse(error.QueueFull);
        var payload: [frame.control_payload_max]u8 = undefined;
        var length: usize = 0;
        if (code) |value| {
            std.mem.writeInt(u16, payload[0..2], value, .big);
            @memcpy(payload[2..][0..reason.len], reason);
            length = 2 + reason.len;
        }
        try self.queue_frame(.close, true, payload[0..length]);
        self.state = .closing;
        self.close_sent = true;
        assert(now_ms < std.math.maxInt(u64) - @as(u64, self.close_timeout_ms));
        if (self.close_timeout_ms != 0) self.deadline_ms = now_ms + self.close_timeout_ms;
        assert(self.state == .closing and self.close_sent);
    }

    pub fn end_of_input(self: *Conn) Eof {
        assert(self.state != .ended);
        const before = self.state;
        self.state = .ended;
        self.deadline_ms = 0;
        const outcome: Eof = switch (before) {
            .closed => .clean,
            .failed => .failed,
            .handshake => .in_handshake,
            .closing => .during_close,
            .ended => unreachable,
            .open => self.eof_while_open(),
        };
        assert(self.state == .ended and (outcome != .failed or self.failure != null));
        return outcome;
    }

    fn eof_while_open(self: *const Conn) Eof {
        assert(self.state == .ended and self.close_sent == false);
        if (self.current != null or self.recv_end > self.recv_start) return .in_frame;
        if (self.message_open) return .in_message;
        return .without_close;
    }
};
