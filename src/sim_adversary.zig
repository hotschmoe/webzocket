const std = @import("std");
const ws = @import("webzocket");
const assert = @import("assert").assert;
const core = @import("sim_core.zig");
const wire = @import("sim_wire.zig");

const Conn = ws.conn.Conn;
const Violation = core.Violation;
const Error = ws.conn.Error;

const stream_cap: u32 = 16384;
const output_cap: u32 = 16384;
const drain_max: u32 = 4096;
const items_max: u32 = 8;

pub const Class = enum(u8) {
    rsv_bit,
    bad_opcode,
    control_fragmented,
    control_too_long,
    wrong_mask,
    nonminimal_16,
    nonminimal_64,
    length_msb,
    lone_continuation,
    data_in_fragment,
    frame_oversize,
    fragments_oversize,
    utf8_single,
    utf8_split,
    utf8_truncated,
    close_one_byte,
    close_bad_code,
    close_bad_reason,
    s_bare_lf,
    s_nul,
    s_no_spaces,
    s_post,
    s_bad_target,
    s_http10,
    s_no_colon,
    s_space_colon,
    s_fold,
    s_dup_key,
    s_dup_host,
    s_no_host,
    s_no_upgrade,
    s_wrong_upgrade,
    s_no_connection,
    s_wrong_connection,
    s_version_12,
    s_no_version,
    s_key_short,
    s_key_chars,
    s_key_trailing,
    s_no_key,
    s_too_large,
    c_http10,
    c_short_status,
    c_status_200,
    c_status_400,
    c_no_upgrade,
    c_no_connection,
    c_no_accept,
    c_wrong_accept,
    c_dup_accept,
    c_extensions,
    c_protocol,
    c_bare_lf,
    c_too_large,
    ok_close,
    truncated,
};
pub const class_count: u32 = std.meta.fieldNames(Class).len;

const Kind = enum(u8) { text, binary, ping };
const Item = struct { kind: Kind, length: u32, seed: u64 };
const Schedule = enum { random, bulk };

const Plan = struct {
    class: Class,
    role: ws.conn.Role,
    recv_len: u32,
    message_len: u32,
    send_len: u32,
    raw_key: [16]u8,
    key_text: [24]u8,
    target: [24]u8,
    target_len: u8,
    host: [12]u8,
    host_len: u8,
    expect_error: ?Error,
    expect_code: u16,
    item_count: u32,
    pings: u32,
    close_code: ?u16,
    close_reason: [20]u8,
    close_reason_len: u8,
    peer_masked: bool,
    limit_hit: bool,
    chunk_seed: u64,
};

const Result = struct {
    trace: u64 = 0,
    output_hash: u64 = 0,
    failure: ?Error = null,
    state: ws.conn.State = .handshake,
    eof: ?ws.conn.Eof = null,
    delivered: u32 = 0,
    closed: bool = false,
    opened: bool = false,
    output_at_failure: u32 = 0,
    limit_hits: u64 = 0,
};

pub const Totals = struct {
    sessions: u64 = 0,
    classes: [class_count]u64 = @splat(0),
    steps: u64 = 0,
    rejected: u64 = 0,
    accepted: u64 = 0,
    truncated: u64 = 0,
    limit_hits: u64 = 0,
    bytes: u64 = 0,
};

fn same_error(left: ?Error, right: ?Error) bool {
    return if (left) |a| (if (right) |b| a == b else false) else right == null;
}

pub const Adversary = struct {
    stream: [stream_cap]u8,
    stream_len: u32,
    items: [items_max]Item,
    output: [output_cap]u8,
    output_len: u32,
    scratch: [4096]u8,
    recv: core.Region(1024),
    message: core.Region(4096),
    send: core.Region(4096),
    plan: Plan,
    prng: std.Random.DefaultPrng,
    totals: Totals,

    pub fn init(self: *Adversary) void {
        self.totals = .{};
    }

    fn random(self: *Adversary) std.Random {
        return self.prng.random();
    }

    fn pick(self: *Adversary, comptime T: type, options: []const T) T {
        return options[self.random().uintLessThan(usize, options.len)];
    }

    fn add_bytes(self: *Adversary, bytes: []const u8) void {
        assert(self.stream_len + bytes.len <= stream_cap);
        @memcpy(self.stream[self.stream_len..][0..bytes.len], bytes);
        self.stream_len += @intCast(bytes.len);
        assert(self.stream_len <= stream_cap);
    }

    fn add_text(self: *Adversary, comptime format: []const u8, args: anytype) void {
        assert(self.stream_len < stream_cap);
        const room = self.stream[self.stream_len..];
        const text = std.fmt.bufPrint(room, format, args) catch @panic("sim stream capacity");
        self.stream_len += @intCast(text.len);
        assert(self.stream_len <= stream_cap);
    }

    fn add_frame_as(self: *Adversary, spec: wire.FrameSpec, masked: bool) void {
        assert(spec.opcode <= 15);
        var framed = spec;
        framed.mask = null;
        if (masked) framed.mask = self.random_mask();
        const length = wire.encode_frame(self.stream[self.stream_len..], framed);
        self.stream_len += length;
        assert(self.stream_len <= stream_cap);
    }

    fn add_frame(self: *Adversary, spec: wire.FrameSpec) void {
        self.add_frame_as(spec, self.plan.peer_masked);
    }

    fn random_mask(self: *Adversary) [4]u8 {
        assert(self.plan.item_count <= items_max);
        assert(self.stream_len <= stream_cap);
        var mask: [4]u8 = undefined;
        self.random().bytes(&mask);
        return mask;
    }

    fn add_message(self: *Adversary, kind: Kind, length: u32, seed: u64, parts: u32) void {
        assert(kind != .ping and self.plan.item_count < items_max);
        const payload = self.scratch[0..length];
        wire.payload_fill(payload, seed, kind == .text);
        var offset: u32 = 0;
        for (0..parts) |part| {
            const left = length - offset;
            const take = if (part + 1 == parts) left else self.random().uintLessThan(u32, left + 1);
            self.add_frame(.{
                .opcode = if (part == 0) (if (kind == .text) 1 else 2) else 0,
                .fin = part + 1 == parts,
                .payload = payload[offset..][0..take],
            });
            offset += take;
        }
        assert(offset == length);
        self.items[self.plan.item_count] = .{ .kind = kind, .length = length, .seed = seed };
        self.plan.item_count += 1;
    }

    fn add_ping(self: *Adversary, length: u32, seed: u64) void {
        assert(length <= 125 and self.plan.item_count < items_max);
        const payload = self.scratch[0..length];
        wire.payload_fill(payload, seed, false);
        self.add_frame(.{ .opcode = 9, .payload = payload });
        self.items[self.plan.item_count] = .{ .kind = .ping, .length = length, .seed = seed };
        self.plan.item_count += 1;
        self.plan.pings += 1;
        assert(self.plan.pings <= self.plan.item_count);
    }

    fn add_prefix(self: *Adversary) void {
        assert(self.plan.item_count == 0 and self.plan.pings == 0);
        const count = self.random().uintLessThan(u32, 4);
        const limit = @min(self.plan.message_len, 600);
        defer assert(self.plan.item_count <= 3);
        for (0..count) |_| {
            const seed = self.random().int(u64);
            if (self.random().uintLessThan(u8, 4) == 0) {
                self.add_ping(self.random().uintLessThan(u32, 126), seed);
            } else {
                const kind: Kind = if (self.random().boolean()) .text else .binary;
                const parts = self.random().intRangeAtMost(u32, 1, 3);
                self.add_message(kind, self.random().uintLessThan(u32, limit + 1), seed, parts);
            }
        }
    }

    fn begin(self: *Adversary, seed: u64, index: u32) void {
        self.prng = std.Random.DefaultPrng.init(wire.mix64(seed ^ 0xadad, index));
        self.stream_len = 0;
        const roll = self.random().uintLessThan(u8, 100);
        const class: Class = if (roll < 10)
            .ok_close
        else if (roll < 20)
            .truncated
        else
            self.pick(Class, std.enums.values(Class));
        const server_head = @backingInt(class) >= @backingInt(Class.s_bare_lf) and
            @backingInt(class) <= @backingInt(Class.s_too_large);
        const client_head = @backingInt(class) >= @backingInt(Class.c_http10) and
            @backingInt(class) <= @backingInt(Class.c_too_large);
        var role: ws.conn.Role = if (self.random().boolean()) .server else .client;
        if (server_head) role = .server;
        if (client_head) role = .client;
        self.plan = .{
            .class = class,
            .role = role,
            .recv_len = self.pick(u32, &.{ 512, 1024 }),
            .message_len = self.pick(u32, &.{ 16, 125, 1000, 4096 }),
            .send_len = self.pick(u32, &.{ 1024, 4096 }),
            .raw_key = undefined,
            .key_text = undefined,
            .target = undefined,
            .target_len = 0,
            .host = undefined,
            .host_len = 0,
            .expect_error = null,
            .expect_code = 0,
            .item_count = 0,
            .pings = 0,
            .close_code = null,
            .close_reason = undefined,
            .close_reason_len = 0,
            .peer_masked = role == .server,
            .limit_hit = false,
            .chunk_seed = self.random().int(u64),
        };
        self.random().bytes(&self.plan.raw_key);
        _ = std.base64.standard.Encoder.encode(&self.plan.key_text, &self.plan.raw_key);
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
        self.plan.target_len = self.random().intRangeAtMost(u8, 1, 24);
        for (self.plan.target[0..self.plan.target_len]) |*byte| {
            byte.* = alphabet[self.random().uintLessThan(usize, alphabet.len)];
        }
        self.plan.target[0] = '/';
        assert(self.plan.item_count == 0 and self.stream_len == 0);
        assert(self.plan.target_len >= 1 and self.plan.target[0] == '/');
        self.plan.host_len = self.random().intRangeAtMost(u8, 1, 12);
        for (self.plan.host[0..self.plan.host_len]) |*byte| {
            byte.* = alphabet[self.random().uintLessThan(usize, alphabet.len)];
        }
    }

    fn target(self: *const Adversary) []const u8 {
        return self.plan.target[0..self.plan.target_len];
    }

    fn host(self: *const Adversary) []const u8 {
        return self.plan.host[0..self.plan.host_len];
    }

    fn compose_request(self: *Adversary, damage: ?Class) void {
        assert(self.plan.role == .server);
        const d = damage orelse .ok_close;
        const target_text = self.target();
        switch (d) {
            .s_bare_lf => self.add_text("GET {s} HTTP/1.1\n", .{target_text}),
            .s_no_spaces => self.add_text("GET{s}HTTP/1.1\r\n", .{target_text}),
            .s_post => self.add_text("POST {s} HTTP/1.1\r\n", .{target_text}),
            .s_http10 => self.add_text("GET {s} HTTP/1.0\r\n", .{target_text}),
            .s_bad_target => self.add_text("GET {s}\x80 HTTP/1.1\r\n", .{target_text}),
            else => self.add_text("GET {s} HTTP/1.1\r\n", .{target_text}),
        }
        if (d != .s_no_host) self.add_text("Host: {s}\r\n", .{self.host()});
        if (d == .s_dup_host) self.add_text("host: other\r\n", .{});
        self.request_upgrade(d);
        self.request_websocket(d);
        self.request_extras(d);
        self.add_bytes("\r\n");
        assert(self.stream_len > 20);
    }

    fn request_upgrade(self: *Adversary, d: Class) void {
        assert(self.stream_len > 0);
        defer assert(self.stream_len <= stream_cap);
        switch (d) {
            .s_no_upgrade => {},
            .s_wrong_upgrade => self.add_bytes("Upgrade: h2c\r\n"),
            else => self.add_bytes("Upgrade: websocket\r\n"),
        }
        switch (d) {
            .s_no_connection => {},
            .s_wrong_connection => {
                const values = [_][]const u8{ "keep-alive", "xupgrade", "upgraded", "close" };
                const value = self.pick([]const u8, &values);
                self.add_text("Connection: {s}\r\n", .{value});
            },
            else => self.add_bytes("Connection: Upgrade\r\n"),
        }
    }

    fn request_websocket(self: *Adversary, d: Class) void {
        assert(self.stream_len > 0);
        defer assert(self.stream_len <= stream_cap);
        switch (d) {
            .s_no_version => {},
            .s_version_12 => self.add_bytes("Sec-WebSocket-Version: 12\r\n"),
            else => self.add_bytes("Sec-WebSocket-Version: 13\r\n"),
        }
        switch (d) {
            .s_no_key => {},
            .s_key_short => self.add_bytes("Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\n"),
            .s_key_chars => self.add_bytes("Sec-WebSocket-Key: !!!!!!!!!!!!!!!!!!!!!!==\r\n"),
            .s_key_trailing => self.add_bytes("Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAB==\r\n"),
            else => self.add_text("Sec-WebSocket-Key: {s}\r\n", .{&self.plan.key_text}),
        }
        if (d == .s_dup_key) self.add_text("sec-websocket-key: {s}\r\n", .{&self.plan.key_text});
    }

    fn request_extras(self: *Adversary, d: Class) void {
        assert(self.plan.role == .server);
        defer assert(self.stream_len <= stream_cap);
        switch (d) {
            .s_nul => self.add_bytes("X-A: a\x00b\r\n"),
            .s_no_colon => self.add_bytes("garbage line\r\n"),
            .s_space_colon => self.add_bytes("X-A : b\r\n"),
            .s_fold => self.add_bytes("X-A: b\r\n continued\r\n"),
            .s_too_large => {
                self.add_bytes("X-Pad: ");
                for (0..400) |_| self.add_bytes("a");
                self.add_bytes("\r\n");
            },
            else => {},
        }
    }

    fn compose_reply(self: *Adversary, damage: ?Class) void {
        assert(self.plan.role == .client);
        defer assert(self.stream_len > 20);
        const d = damage orelse .ok_close;
        const status: []const u8 = switch (d) {
            .c_http10 => "HTTP/1.0 101 Switching Protocols\r\n",
            .c_short_status => "HTTP/1.1 10 x\r\n",
            .c_status_200 => "HTTP/1.1 200 OK\r\n",
            .c_status_400 => "HTTP/1.1 400 Bad Request\r\n",
            .c_bare_lf => "HTTP/1.1 101 Switching Protocols\n",
            else => "HTTP/1.1 101 Switching Protocols\r\n",
        };
        self.add_bytes(status);
        if (d != .c_no_upgrade) self.add_bytes("Upgrade: websocket\r\n");
        if (d != .c_no_connection) self.add_bytes("Connection: Upgrade\r\n");
        const accept = wire.accept_text(&self.plan.key_text);
        switch (d) {
            .c_no_accept => {},
            .c_wrong_accept => {
                self.add_bytes("Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n");
            },
            else => self.add_text("Sec-WebSocket-Accept: {s}\r\n", .{&accept}),
        }
        if (d == .c_dup_accept) self.add_text("sec-websocket-accept: {s}\r\n", .{&accept});
        if (d == .c_extensions) self.add_bytes("Sec-WebSocket-Extensions: permessage-deflate\r\n");
        if (d == .c_protocol) self.add_bytes("Sec-WebSocket-Protocol: chat\r\n");
        if (d == .c_too_large) {
            self.add_bytes("X-Pad: ");
            for (0..400) |_| self.add_bytes("a");
            self.add_bytes("\r\n");
        }
        self.add_bytes("\r\n");
    }

    fn compose_valid_head(self: *Adversary) void {
        assert(self.stream_len == 0);
        defer assert(self.stream_len > 20);
        if (self.plan.role == .server) return self.compose_request_variant();
        self.compose_reply(null);
    }

    fn compose_request_variant(self: *Adversary) void {
        assert(self.plan.role == .server);
        defer assert(self.stream_len > 100);
        const upper = self.random().boolean();
        self.add_text("GET {s} HTTP/1.1\r\n", .{self.target()});
        self.add_text("{s}: {s}\r\n", .{ if (upper) "HOST" else "host", self.host() });
        self.add_bytes(if (upper) "UPGRADE:   WebSocket  \r\n" else "upgrade: websocket\r\n");
        self.add_bytes(if (upper)
            "connection: keep-alive,  Upgrade\r\n"
        else
            "Connection: upgrade\r\n");
        self.add_bytes("Origin: http://example\r\n");
        self.add_bytes("Sec-WebSocket-Extensions: permessage-deflate\r\n");
        self.add_bytes("Sec-WebSocket-Protocol: chat, superchat\r\nSec-WebSocket-Version: 13\r\n");
        self.add_text("Sec-WebSocket-Key:{s}\r\n\r\n", .{&self.plan.key_text});
    }

    fn set_expected(self: *Adversary, err: Error, code: u16) void {
        assert(code == 1002 or code == 1007 or code == 1009);
        defer assert(self.plan.expect_error != null);
        self.plan.expect_error = err;
        self.plan.expect_code = code;
    }

    fn build_frames(self: *Adversary) void {
        assert(self.plan.expect_error == null);
        defer assert(self.plan.expect_error != null);
        const class = self.plan.class;
        const correct = self.plan.peer_masked;
        switch (class) {
            .rsv_bit => {
                const bit = self.pick(u8, &.{ 0x10, 0x20, 0x40 });
                const opcode = self.pick(u8, &.{ 1, 2, 9 });
                self.add_frame(.{ .opcode = opcode, .rsv = bit, .payload = "abc" });
                self.set_expected(error.ReservedBits, 1002);
            },
            .bad_opcode => {
                const reserved = [_]u8{ 3, 4, 5, 6, 7, 11, 12, 13, 14, 15 };
                self.add_frame(.{ .opcode = self.pick(u8, &reserved), .payload = "abc" });
                self.set_expected(error.BadOpcode, 1002);
            },
            .control_fragmented => {
                self.add_frame(.{ .opcode = self.pick(u8, &.{ 8, 9, 10 }), .fin = false });
                self.set_expected(error.ControlFragmented, 1002);
            },
            .control_too_long => {
                const opcode = self.pick(u8, &.{ 8, 9, 10 });
                self.add_frame(.{ .opcode = opcode, .payload = self.scratch[0..126] });
                self.set_expected(error.ControlTooLong, 1002);
            },
            .wrong_mask => {
                self.add_frame_as(.{ .opcode = 1, .payload = "abc" }, !correct);
                const err = if (correct) error.MaskRequired else error.MaskForbidden;
                self.set_expected(err, 1002);
            },
            .nonminimal_16 => {
                self.add_frame(.{ .opcode = 2, .length_form = 2, .payload = "abc" });
                self.set_expected(error.NonMinimalLength, 1002);
            },
            .nonminimal_64 => {
                self.add_frame(.{ .opcode = 2, .length_form = 8, .payload = self.scratch[0..200] });
                self.set_expected(error.NonMinimalLength, 1002);
            },
            .length_msb => {
                const declared: u64 = (1 << 63) | 5;
                self.add_frame(.{
                    .opcode = 2,
                    .length_form = 8,
                    .declared = declared,
                    .payload = "abc",
                });
                self.set_expected(error.LengthMsb, 1002);
            },
            else => self.build_message_frames(class),
        }
    }

    fn build_message_frames(self: *Adversary, class: Class) void {
        assert(self.plan.message_len >= 16);
        defer assert(self.plan.expect_error != null);
        const limit = self.plan.message_len;
        switch (class) {
            .lone_continuation => {
                self.add_frame(.{ .opcode = 0, .payload = "abc" });
                self.set_expected(error.UnexpectedContinuation, 1002);
            },
            .data_in_fragment => {
                self.add_frame(.{ .opcode = 1, .fin = false, .payload = "abc" });
                self.add_frame(.{ .opcode = self.pick(u8, &.{ 1, 2 }), .payload = "def" });
                self.set_expected(error.ExpectedContinuation, 1002);
            },
            .frame_oversize => {
                self.add_frame(.{ .opcode = 2, .declared = limit + 1 });
                self.set_expected(error.MessageTooLarge, 1009);
                self.plan.limit_hit = true;
            },
            .fragments_oversize => {
                const part = limit / 2 + 1;
                self.add_frame(.{ .opcode = 2, .fin = false, .payload = self.scratch[0..part] });
                self.add_frame(.{ .opcode = 0, .fin = false, .payload = self.scratch[0..part] });
                self.set_expected(error.MessageTooLarge, 1009);
                self.plan.limit_hit = true;
            },
            else => self.build_text_frames(class),
        }
    }

    fn build_text_frames(self: *Adversary, class: Class) void {
        assert(self.plan.expect_error == null);
        defer assert(self.plan.expect_code != 0);
        switch (class) {
            .utf8_single => {
                const bad_values = [_][]const u8{
                    "\xff", "\xc0\xaf", "ab\xe2\x82", "\xed\xa0\x80", "\xf4\x90\x80\x80",
                };
                const bad = self.pick([]const u8, &bad_values);
                self.add_frame(.{ .opcode = 1, .payload = bad });
                self.set_expected(error.InvalidUtf8, 1007);
            },
            .utf8_split => {
                self.add_frame(.{ .opcode = 1, .fin = false, .payload = "a\xe2\x82" });
                self.add_frame(.{ .opcode = 0, .payload = "a" });
                self.set_expected(error.InvalidUtf8, 1007);
            },
            .utf8_truncated => {
                self.add_frame(.{ .opcode = 1, .fin = false, .payload = "a\xe2" });
                self.add_frame(.{ .opcode = 0 });
                self.set_expected(error.InvalidUtf8, 1007);
            },
            .close_one_byte => {
                self.add_frame(.{ .opcode = 8, .payload = "\x03" });
                self.set_expected(error.BadClosePayload, 1002);
            },
            .close_bad_code => {
                const codes = [_]u16{
                    0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000, 65535, 1100,
                };
                var payload: [2]u8 = undefined;
                std.mem.writeInt(u16, &payload, self.pick(u16, &codes), .big);
                self.add_frame(.{ .opcode = 8, .payload = &payload });
                self.set_expected(error.BadCloseCode, 1002);
            },
            .close_bad_reason => {
                self.add_frame(.{ .opcode = 8, .payload = "\x03\xe8\xc3\x28" });
                self.set_expected(error.InvalidUtf8, 1007);
            },
            else => unreachable,
        }
    }

    fn head_error(class: Class) ?Error {
        return switch (class) {
            .s_bare_lf, .c_bare_lf => error.BadLineEnding,
            .s_nul => error.BadByte,
            .s_no_spaces => error.BadRequestLine,
            .s_post => error.BadMethod,
            .s_bad_target => error.BadTarget,
            .s_http10 => error.BadHttpVersion,
            .s_no_colon, .s_space_colon, .s_fold => error.BadHeader,
            .s_dup_key, .s_dup_host, .c_dup_accept => error.DuplicateHeader,
            .s_no_host => error.MissingHost,
            .s_no_upgrade, .s_wrong_upgrade, .c_no_upgrade => error.BadUpgrade,
            .s_no_connection, .s_wrong_connection, .c_no_connection => error.BadConnection,
            .s_version_12, .s_no_version => error.BadWebSocketVersion,
            .s_key_short, .s_key_chars, .s_key_trailing, .s_no_key => error.BadKey,
            .s_too_large, .c_too_large => error.HandshakeTooLarge,
            .c_http10, .c_short_status => error.BadStatusLine,
            .c_status_200, .c_status_400 => error.BadStatus,
            .c_no_accept, .c_wrong_accept => error.BadAccept,
            .c_extensions => error.ExtensionNotOffered,
            .c_protocol => error.SubprotocolNotOffered,
            else => null,
        };
    }

    fn build(self: *Adversary, seed: u64, index: u32) void {
        self.begin(seed, index);
        assert(self.plan.recv_len >= 256);
        defer assert(self.stream_len <= stream_cap);
        const class = self.plan.class;
        if (head_error(class)) |err| {
            self.plan.expect_error = err;
            const too_large = class == .s_too_large or class == .c_too_large;
            if (too_large) self.plan.recv_len = 256;
            self.plan.limit_hit = class == .s_too_large or class == .c_too_large;
            if (self.plan.role == .server) {
                self.compose_request(class);
            } else self.compose_reply(class);
            return;
        }
        self.compose_valid_head();
        self.add_prefix();
        if (class == .ok_close or class == .truncated) return self.build_close();
        self.build_frames();
    }

    fn build_close(self: *Adversary) void {
        const plan = &self.plan;
        assert(plan.close_code == null and plan.close_reason_len == 0);
        defer assert(plan.close_reason_len <= 20);
        if (self.random().uintLessThan(u8, 5) != 0) {
            const codes = [_]u16{
                1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 3000, 4999,
            };
            plan.close_code = self.pick(u16, &codes);
            plan.close_reason_len = self.random().uintLessThan(u8, 21);
            const reason = plan.close_reason[0..plan.close_reason_len];
            wire.payload_fill(reason, self.random().int(u64), true);
        }
        var payload: [23]u8 = undefined;
        var length: usize = 0;
        if (plan.close_code) |code| {
            std.mem.writeInt(u16, payload[0..2], code, .big);
            const reason = plan.close_reason[0..plan.close_reason_len];
            @memcpy(payload[2..][0..reason.len], reason);
            length = 2 + plan.close_reason_len;
        }
        self.add_frame(.{ .opcode = 8, .payload = payload[0..length] });
        if (plan.class == .truncated) {
            self.stream_len = self.random().uintLessThan(u32, self.stream_len + 1);
        } else if (self.random().boolean()) {
            for (0..40) |_| self.add_bytes(&.{self.random().int(u8)});
        }
    }

    fn random_chunk(chunker: std.Random, remaining: u32) u32 {
        assert(remaining > 0);
        const roll = chunker.uintLessThan(u8, 10);
        var wanted: u32 = chunker.intRangeAtMost(u32, 10, 300);
        if (roll < 7) wanted = chunker.intRangeAtMost(u32, 2, 9);
        if (roll < 4) wanted = 1;
        const chunk = @min(wanted, remaining);
        assert(chunk >= 1 and chunk <= remaining);
        return chunk;
    }

    fn collect(self: *Adversary, conn: *Conn, report: *core.Report) Violation!void {
        assert(self.output_len <= output_cap);
        defer assert(self.output_len <= output_cap);
        const out = conn.output();
        if (out.len == 0) return;
        if (self.output_len + out.len > output_cap) {
            return report.fail(.liveness, "session output over {d} bytes", .{output_cap});
        }
        @memcpy(self.output[self.output_len..][0..out.len], out);
        self.output_len += @intCast(out.len);
        self.totals.bytes += out.len;
        conn.output_taken(@intCast(out.len));
    }

    fn execute(self: *Adversary, report: *core.Report, schedule: Schedule) Violation!Result {
        const plan = &self.plan;
        assert(plan.recv_len >= 256 and plan.message_len >= 16);
        assert(self.stream_len <= stream_cap);
        var conn = ws.conn.Conn.init(.{
            .role = plan.role,
            .recv = self.recv.arm(plan.recv_len),
            .message = self.message.arm(plan.message_len),
            .send = self.send.arm(plan.send_len),
            .mask_seed = @splat(0x5a),
        }, 0) catch return report.fail(.limits, "init rejected a valid config", .{});
        self.output_len = 0;
        var result = Result{};
        var trace = core.Trace{};
        if (plan.role == .client) {
            conn.start_client(self.host(), self.target(), &plan.raw_key) catch |err| {
                return report.fail(.handshake, "start_client failed: {s}", .{@errorName(err)});
            };
            try self.collect(&conn, report);
        }
        try self.feed_stream(&conn, &result, &trace, report, schedule);
        if (plan.class == .truncated) result.eof = conn.end_of_input();
        result.state = if (result.eof != null) .ended else conn.state;
        result.trace = trace.digest();
        result.output_hash = core.hash_bytes(self.output[0..self.output_len]);
        result.limit_hits = conn.stats.limit_hits;
        try self.check_storage(&conn, report);
        return result;
    }

    fn check_storage(self: *Adversary, conn: *const Conn, report: *core.Report) Violation!void {
        assert(self.recv.declared == self.plan.recv_len);
        assert(self.message.declared == self.plan.message_len);
        if (!self.recv.intact() or !self.message.intact() or !self.send.intact()) {
            return report.fail(.canary, "adversary session wrote outside declared storage", .{});
        }
        const stats = &conn.stats;
        if (stats.recv_high > self.recv.declared or stats.message_high > self.message.declared or
            stats.send_high > self.send.declared)
        {
            return report.fail(.limits, "adversary session used more than it declared", .{});
        }
    }

    fn feed_stream(
        self: *Adversary,
        conn: *Conn,
        result: *Result,
        trace: *core.Trace,
        report: *core.Report,
        schedule: Schedule,
    ) Violation!void {
        assert(self.output_len <= output_cap);
        var chunker_state = std.Random.DefaultPrng.init(self.plan.chunk_seed);
        var position: u32 = 0;
        for (0..self.stream_len * 2 + 8) |_| {
            if (position >= self.stream_len) break;
            const remaining = self.stream_len - position;
            var want = remaining;
            if (schedule == .random) want = random_chunk(chunker_state.random(), remaining);
            const accepted = conn.feed(self.stream[position..][0..want]);
            position += accepted;
            self.totals.steps += 1;
            const progressed = try self.drain(conn, result, trace, report);
            try self.collect(conn, report);
            if (result.failure != null and result.output_at_failure == 0) {
                result.output_at_failure = self.output_len;
            }
            if (accepted == 0 and !progressed) {
                return report.fail(.liveness, "adversary stream stalled", .{});
            }
        }
        try self.drain_all(conn, result, trace, report);
        assert(position <= self.stream_len);
        if (position < self.stream_len) {
            return report.fail(.liveness, "adversary stream not consumed", .{});
        }
        if (result.failure != null and self.output_len != result.output_at_failure) {
            return report.fail(.quiet, "output grew after the error", .{});
        }
    }

    fn drain_all(
        self: *Adversary,
        conn: *Conn,
        result: *Result,
        trace: *core.Trace,
        report: *core.Report,
    ) Violation!void {
        assert(self.output_len <= output_cap);
        _ = try self.drain(conn, result, trace, report);
        try self.collect(conn, report);
        assert(self.output_len <= output_cap);
        if (result.failure != null and result.output_at_failure == 0) {
            result.output_at_failure = self.output_len;
        }
    }

    fn drain(
        self: *Adversary,
        conn: *Conn,
        result: *Result,
        trace: *core.Trace,
        report: *core.Report,
    ) Violation!bool {
        assert(result.delivered <= self.plan.item_count);
        assert(self.output_len <= output_cap);
        var progressed = false;
        for (0..drain_max) |_| {
            const polled = conn.poll() catch |err| {
                if (result.failure != null) {
                    return report.fail(.quiet, "second error {s}", .{@errorName(err)});
                }
                result.failure = err;
                trace.mix_bytes(@errorName(err));
                return true;
            };
            const event = polled orelse return progressed;
            progressed = true;
            if (result.failure != null or result.closed) {
                return report.fail(.quiet, "event after the connection ended", .{});
            }
            try self.on_event(event, result, trace, report);
        }
        return report.fail(.liveness, "adversary drain limit", .{});
    }

    fn on_event(
        self: *Adversary,
        event: ws.conn.Event,
        result: *Result,
        trace: *core.Trace,
        report: *core.Report,
    ) Violation!void {
        switch (event) {
            .opened => |opened| {
                const want = if (self.plan.role == .server) self.target() else "";
                if (result.opened or !std.mem.eql(u8, opened.target, want)) {
                    return report.fail(.handshake, "opened event changed the target", .{});
                }
                result.opened = true;
                trace.mix(1);
            },
            .message => |message| {
                const kind: Kind = if (message.kind == .text) .text else .binary;
                try self.expect_item(kind, message.data, result, report);
                trace.mix_bytes(message.data);
            },
            .ping => |data| {
                try self.expect_item(.ping, data, result, report);
                trace.mix_bytes(data);
            },
            .pong => return report.fail(.delivery, "pong delivered without a ping", .{}),
            .closed => |closed| {
                const want = self.plan.close_code orelse ws.conn.code_none;
                const reason = self.plan.close_reason[0..self.plan.close_reason_len];
                const wrong = closed.code != want or result.closed;
                if (wrong or !std.mem.eql(u8, closed.reason, reason)) {
                    return report.fail(.close, "close event code {d}, expected {d}", .{
                        closed.code, want,
                    });
                }
                result.closed = true;
                trace.mix(closed.code);
            },
        }
    }

    fn expect_item(
        self: *Adversary,
        kind: Kind,
        data: []const u8,
        result: *Result,
        report: *core.Report,
    ) Violation!void {
        assert(self.plan.item_count <= items_max);
        if (result.delivered >= self.plan.item_count) {
            return report.fail(.delivery, "delivered more than the stream carried", .{});
        }
        const item = self.items[result.delivered];
        wire.payload_fill(self.scratch[0..item.length], item.seed, item.kind == .text);
        if (item.kind != kind or !std.mem.eql(u8, self.scratch[0..item.length], data)) {
            return report.fail(.delivery, "delivered item {d} changed", .{result.delivered});
        }
        result.delivered += 1;
        assert(result.delivered <= self.plan.item_count);
    }

    fn error_name(err: ?Error) []const u8 {
        return if (err) |value| @errorName(value) else "none";
    }

    fn head_text(self: *const Adversary, buffer: []u8) []const u8 {
        assert(buffer.len >= 256);
        var length: u32 = 0;
        if (self.plan.role == .server) {
            length = wire.reply_text(buffer, &self.plan.key_text);
        } else {
            length = wire.request_text(buffer, self.target(), &self.plan.key_text, self.host());
        }
        assert(length >= 129 and length <= buffer.len);
        return buffer[0..length];
    }

    fn verify_outcome(
        self: *Adversary,
        report: *core.Report,
        result: *const Result,
    ) Violation!void {
        const plan = &self.plan;
        assert(plan.item_count <= items_max);
        assert(result.delivered <= plan.item_count);
        if (!same_error(result.failure, plan.expect_error)) {
            return report.fail(.error_class, "class {s}: expected {s}, got {s}", .{
                @tagName(plan.class), error_name(plan.expect_error), error_name(result.failure),
            });
        }
        if (plan.expect_error != null) {
            if (result.state != .failed) {
                return report.fail(.error_class, "state {s} after damage", .{
                    @tagName(result.state),
                });
            }
            if (plan.limit_hit and result.limit_hits == 0) {
                return report.fail(.limits, "limit hit was not counted", .{});
            }
            return self.verify_error_output(report, result);
        }
        if (plan.class == .truncated) return self.verify_truncated(report, result);
        if (result.state != .closed or !result.closed or result.delivered != plan.item_count) {
            return report.fail(.close, "valid stream ended in {s}", .{@tagName(result.state)});
        }
        return self.verify_frames(report, plan.close_code, true);
    }

    fn verify_error_output(
        self: *Adversary,
        report: *core.Report,
        result: *const Result,
    ) Violation!void {
        const plan = &self.plan;
        assert(plan.expect_error != null and result.state == .failed);
        assert(self.output_len > 0);
        const head_class = head_error(plan.class) != null;
        var buffer: [512]u8 = undefined;
        if (head_class and plan.role == .server) {
            if (!std.mem.eql(u8, self.output[0..self.output_len], wire.rejection_text)) {
                return report.fail(.error_class, "server rejection text changed", .{});
            }
            return;
        }
        const head = self.head_text(&buffer);
        if (self.output_len < head.len or !std.mem.eql(u8, self.output[0..head.len], head)) {
            return report.fail(.handshake, "handshake bytes changed", .{});
        }
        if (head_class) {
            if (self.output_len != head.len) {
                return report.fail(.quiet, "client sent bytes after a bad reply", .{});
            }
            return;
        }
        if (result.delivered != plan.item_count) {
            return report.fail(.delivery, "items before the damage were lost", .{});
        }
        return self.verify_frames(report, plan.expect_code, false);
    }

    fn verify_truncated(
        self: *Adversary,
        report: *core.Report,
        result: *const Result,
    ) Violation!void {
        assert(self.plan.class == .truncated and self.plan.expect_error == null);
        var scanner = wire.Scanner{};
        scanner.feed(self.stream[0..self.stream_len]);
        assert(scanner.bytes == self.stream_len);
        const want: ws.conn.Eof = if (scanner.close_seen)
            .clean
        else if (!scanner.head_done)
            .in_handshake
        else if (!scanner.at_boundary())
            .in_frame
        else if (scanner.message_open)
            .in_message
        else
            .without_close;
        const got = result.eof orelse return report.fail(.eof, "no end of input outcome", .{});
        if (got != want) {
            return report.fail(.eof, "truncated stream gave {s}, expected {s}", .{
                @tagName(got), @tagName(want),
            });
        }
    }

    fn verify_frames(
        self: *Adversary,
        report: *core.Report,
        close_code: ?u16,
        echo: bool,
    ) Violation!void {
        assert(self.output_len >= 129);
        var buffer: [512]u8 = undefined;
        const head = self.head_text(&buffer);
        assert(head.len >= 129 and head.len <= self.output_len);
        const bytes = self.output[0..self.output_len];
        var position: u32 = @intCast(head.len);
        var payload: [125]u8 = undefined;
        const masked = self.plan.role == .client;
        for (self.items[0..self.plan.item_count]) |item| {
            if (item.kind != .ping) continue;
            const view = wire.next_frame(bytes, &position, &payload) orelse {
                return report.fail(.ping, "missing pong in the output", .{});
            };
            wire.payload_fill(self.scratch[0..item.length], item.seed, false);
            const same = std.mem.eql(u8, view.payload, self.scratch[0..item.length]);
            if (view.opcode != 10 or view.masked != masked or !same) {
                return report.fail(.ping, "pong does not match its ping", .{});
            }
        }
        const view = wire.next_frame(bytes, &position, &payload) orelse {
            return report.fail(.close, "missing close frame in the output", .{});
        };
        var want: [2]u8 = undefined;
        std.mem.writeInt(u16, &want, close_code orelse 0, .big);
        const want_len: usize = if (close_code != null) 2 else 0;
        _ = echo;
        const same_code = std.mem.eql(u8, view.payload, want[0..want_len]);
        if (view.opcode != 8 or view.masked != masked or !same_code) {
            return report.fail(.close, "close frame in the output has the wrong code", .{});
        }
        if (position != bytes.len) {
            return report.fail(.quiet, "output continues after the close frame", .{});
        }
    }

    pub fn run_session(
        self: *Adversary,
        report: *core.Report,
        seed: u64,
        index: u32,
    ) Violation!u64 {
        assert(report.checker == null);
        self.build(seed, index);
        const first = try self.execute(report, .random);
        try self.verify_outcome(report, &first);
        const second = try self.execute(report, .bulk);
        const same = first.trace == second.trace and first.output_hash == second.output_hash and
            same_error(first.failure, second.failure) and first.state == second.state and
            first.delivered == second.delivered and first.eof == second.eof and
            first.limit_hits == second.limit_hits;
        if (!same) {
            return report.fail(.chunking, "class {s}: chunking changed the outcome", .{
                @tagName(self.plan.class),
            });
        }
        const totals = &self.totals;
        totals.sessions += 1;
        totals.classes[@backingInt(self.plan.class)] += 1;
        totals.limit_hits += first.limit_hits;
        if (self.plan.expect_error != null) {
            totals.rejected += 1;
        } else if (self.plan.class == .truncated) {
            totals.truncated += 1;
        } else totals.accepted += 1;
        assert(totals.sessions > 0 and totals.limit_hits >= first.limit_hits);
        return first.trace ^ first.output_hash;
    }
};
