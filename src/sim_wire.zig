const std = @import("std");
const assert = @import("assert").assert;

pub const header_max: u32 = 14;
pub const rejection_text = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n" ++
    "Content-Length: 0\r\nSec-WebSocket-Version: 13\r\n\r\n";

pub fn mix64(first: u64, second: u64) u64 {
    return std.hash.Wyhash.hash(first, std.mem.asBytes(&second));
}

fn encode_codepoint(codepoint: u32, out: []u8) u32 {
    assert(out.len >= 4);
    assert(codepoint <= 0x10ffff and (codepoint < 0xd800 or codepoint > 0xdfff));
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        out[0] = @intCast(0xc0 | (codepoint >> 6));
        out[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    }
    if (codepoint < 0x10000) {
        out[0] = @intCast(0xe0 | (codepoint >> 12));
        out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (codepoint >> 18));
    out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (codepoint & 0x3f));
    return 4;
}

fn pick_codepoint(random: std.Random) u32 {
    return switch (random.uintLessThan(u8, 10)) {
        0 => random.intRangeAtMost(u32, 0x80, 0x7ff),
        1 => random.intRangeAtMost(u32, 0x800, 0xd7ff),
        2 => random.intRangeAtMost(u32, 0xe000, 0xffff),
        3 => random.intRangeAtMost(u32, 0x10000, 0x10ffff),
        else => random.intRangeAtMost(u32, 0x20, 0x7e),
    };
}

pub fn payload_fill(buf: []u8, seed: u64, text: bool) void {
    assert(buf.len <= 1 << 20);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    if (!text) return random.bytes(buf);
    var position: u32 = 0;
    while (position < buf.len) {
        var scratch: [4]u8 = undefined;
        var width = encode_codepoint(pick_codepoint(random), &scratch);
        if (position + width > buf.len) {
            width = encode_codepoint('a' + random.uintLessThan(u8, 26), &scratch);
        }
        @memcpy(buf[position..][0..width], scratch[0..width]);
        position += width;
    }
    assert(position == buf.len);
}

pub const FrameSpec = struct {
    opcode: u8,
    fin: bool = true,
    rsv: u8 = 0,
    mask: ?[4]u8 = null,
    length_form: u8 = 0,
    declared: ?u64 = null,
    payload: []const u8 = "",
};

pub fn encode_frame(out: []u8, spec: FrameSpec) u32 {
    assert(spec.opcode <= 15 and spec.rsv & 0x8f == 0);
    const length: u64 = spec.declared orelse spec.payload.len;
    assert(spec.length_form == 0 or spec.length_form == 2 or spec.length_form == 8);
    out[0] = spec.opcode | spec.rsv | @as(u8, if (spec.fin) 0x80 else 0);
    var form = spec.length_form;
    if (form == 0) form = if (length < 126) 0 else if (length < 65536) 2 else 8;
    var position: u32 = 2;
    if (form == 0) {
        out[1] = @intCast(length);
    } else if (form == 2) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @truncate(length), .big);
        position = 4;
    } else {
        out[1] = 127;
        std.mem.writeInt(u64, out[2..10], length, .big);
        position = 10;
    }
    if (spec.mask) |key| {
        out[1] |= 0x80;
        @memcpy(out[position..][0..4], &key);
        position += 4;
    }
    const start = position;
    @memcpy(out[start..][0..spec.payload.len], spec.payload);
    if (spec.mask) |key| {
        for (out[start..][0..spec.payload.len], 0..) |*byte, index| byte.* ^= key[index & 3];
    }
    const total = start + @as(u32, @intCast(spec.payload.len));
    assert(total <= out.len and start >= 2 and start <= header_max);
    return total;
}

pub fn request_text(out: []u8, target: []const u8, key: *const [24]u8, host: []const u8) u32 {
    assert(target.len > 0 and host.len > 0);
    assert(out.len >= 150);
    const text = std.fmt.bufPrint(out, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n\r\n", .{
        target, host, key,
    }) catch @panic("request buffer");
    return @intCast(text.len);
}

pub fn accept_text(key: *const [24]u8) [28]u8 {
    assert(key[22] == '=' and key[23] == '=');
    var joined: [60]u8 = undefined;
    @memcpy(joined[0..24], key);
    @memcpy(joined[24..], "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&joined, &digest, .{});
    var encoded: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    assert(encoded[27] == '=');
    return encoded;
}

pub fn reply_text(out: []u8, key: *const [24]u8) u32 {
    assert(out.len >= 129);
    const accept = accept_text(key);
    const head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n";
    const text = std.fmt.bufPrint(out, head ++
        "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch {
        @panic("reply buffer");
    };
    assert(text.len == 129);
    return @intCast(text.len);
}

pub const Scanner = struct {
    head_state: u8 = 0,
    head_done: bool = false,
    head_len: u32 = 0,
    header: [header_max]u8 = undefined,
    header_have: u32 = 0,
    payload_left: u64 = 0,
    opcode: u8 = 0,
    final: bool = true,
    message_open: bool = false,
    close_seen: bool = false,
    frames: u64 = 0,
    frames_after_close: u64 = 0,
    bytes: u64 = 0,

    pub fn at_boundary(self: *const Scanner) bool {
        return self.head_done and self.header_have == 0 and self.payload_left == 0;
    }

    pub fn feed(self: *Scanner, bytes: []const u8) void {
        for (bytes) |byte| {
            self.bytes += 1;
            if (!self.head_done) {
                self.scan_head_byte(byte);
            } else if (self.payload_left > 0) {
                self.payload_left -= 1;
                if (self.payload_left == 0) self.finish_frame();
            } else self.scan_header_byte(byte);
        }
        assert(self.head_state <= 4);
        assert(self.header_have < header_max);
    }

    fn scan_head_byte(self: *Scanner, byte: u8) void {
        assert(!self.head_done and self.head_state < 4);
        self.head_len += 1;
        const state = self.head_state;
        if (byte == '\r' and (state == 0 or state == 2)) {
            self.head_state += 1;
        } else if (byte == '\n' and (state == 1 or state == 3)) {
            self.head_state += 1;
        } else self.head_state = if (byte == '\r') 1 else 0;
        if (self.head_state == 4) self.head_done = true;
        assert(self.head_len > 0 and self.head_state <= 4);
    }

    fn header_total(self: *const Scanner) u32 {
        assert(self.header_have >= 2);
        const second = self.header[1];
        const extra: u32 = switch (second & 0x7f) {
            126 => 2,
            127 => 8,
            else => 0,
        };
        const total = 2 + extra + @as(u32, if (second & 0x80 != 0) 4 else 0);
        assert(total >= 2 and total <= header_max);
        return total;
    }

    fn scan_header_byte(self: *Scanner, byte: u8) void {
        assert(self.header_have < header_max);
        self.header[self.header_have] = byte;
        self.header_have += 1;
        if (self.header_have < 2 or self.header_have < self.header_total()) return;
        const second = self.header[1];
        var length: u64 = second & 0x7f;
        if (length == 126) {
            length = std.mem.readInt(u16, self.header[2..4], .big);
        } else if (length == 127) length = std.mem.readInt(u64, self.header[2..10], .big);
        self.opcode = self.header[0] & 0x0f;
        self.final = self.header[0] & 0x80 != 0;
        if (self.close_seen) self.frames_after_close += 1;
        self.header_have = 0;
        self.payload_left = length;
        assert(self.header_have == 0 and self.opcode <= 15);
        if (length == 0) self.finish_frame();
    }

    fn finish_frame(self: *Scanner) void {
        assert(self.payload_left == 0);
        self.frames += 1;
        if (self.opcode == 8) self.close_seen = true;
        if (self.opcode == 1 or self.opcode == 2 or self.opcode == 0) {
            self.message_open = !self.final;
        }
        assert(self.frames > 0);
    }
};

pub const View = struct { opcode: u8, fin: bool, masked: bool, payload: []const u8 };

pub fn next_frame(bytes: []const u8, position: *u32, scratch: []u8) ?View {
    const start = position.*;
    assert(start <= bytes.len);
    if (bytes.len - start < 2) return null;
    const first = bytes[start];
    const second = bytes[start + 1];
    const masked = second & 0x80 != 0;
    var length: u64 = second & 0x7f;
    var cursor: u32 = start + 2;
    const extra: u32 = if (length == 126) 2 else if (length == 127) 8 else 0;
    if (bytes.len - cursor < extra + @as(u32, if (masked) 4 else 0)) return null;
    if (extra == 2) length = std.mem.readInt(u16, bytes[cursor..][0..2], .big);
    if (extra == 8) length = std.mem.readInt(u64, bytes[cursor..][0..8], .big);
    cursor += extra;
    var mask: [4]u8 = @splat(0);
    if (masked) {
        mask = bytes[cursor..][0..4].*;
        cursor += 4;
    }
    if (length > bytes.len - cursor or length > scratch.len) return null;
    const payload = scratch[0..@intCast(length)];
    for (payload, bytes[cursor..][0..payload.len], 0..) |*out, byte, index| {
        out.* = byte ^ mask[index & 3];
    }
    position.* = cursor + @as(u32, @intCast(length));
    assert(position.* <= bytes.len and position.* > start);
    return .{
        .opcode = first & 0x0f,
        .fin = first & 0x80 != 0,
        .masked = masked,
        .payload = payload,
    };
}
