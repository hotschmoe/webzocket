const std = @import("std");
const assert = @import("assert").assert;

pub const Role = enum(u8) { server, client };

pub const Opcode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,

    pub fn is_control(self: Opcode) bool {
        return @backingInt(self) >= 8;
    }
};

pub const FrameError = error{
    ReservedBits,
    BadOpcode,
    ControlFragmented,
    ControlTooLong,
    MaskRequired,
    MaskForbidden,
    NonMinimalLength,
    LengthMsb,
};

pub const Header = struct {
    opcode: Opcode,
    fin: bool,
    mask: ?[4]u8,
    payload_len: u64,
    header_len: u8,
};

pub const header_max: u8 = 14;
pub const control_payload_max: u8 = 125;
pub const close_reason_max: u8 = 123;

fn decode_opcode(value: u8) ?Opcode {
    assert(value <= 15);
    return switch (value) {
        0 => .continuation,
        1 => .text,
        2 => .binary,
        8 => .close,
        9 => .ping,
        10 => .pong,
        else => null,
    };
}

// Checks run in this order: reserved bits, opcode, control rules, mask by role, length form.
pub fn parse_header(role: Role, bytes: []const u8) FrameError!?Header {
    if (bytes.len < 2) return null;
    const first = bytes[0];
    const second = bytes[1];
    if (first & 0x70 != 0) return error.ReservedBits;
    const opcode = decode_opcode(first & 0x0f) orelse return error.BadOpcode;
    const fin = first & 0x80 != 0;
    const marker = second & 0x7f;
    if (opcode.is_control()) {
        if (!fin) return error.ControlFragmented;
        if (marker > control_payload_max) return error.ControlTooLong;
    }
    const masked = second & 0x80 != 0;
    if (role == .server and !masked) return error.MaskRequired;
    if (role == .client and masked) return error.MaskForbidden;
    const extra: u8 = switch (marker) {
        126 => 2,
        127 => 8,
        else => 0,
    };
    const header_len: u8 = 2 + extra + @as(u8, if (masked) 4 else 0);
    if (bytes.len < header_len) return null;
    var payload_len: u64 = marker;
    if (extra == 2) payload_len = std.mem.readInt(u16, bytes[2..4], .big);
    if (extra == 8) payload_len = std.mem.readInt(u64, bytes[2..10], .big);
    assert(extra != 0 or payload_len <= 125);
    if (payload_len >> 63 != 0) return error.LengthMsb;
    if (extra == 2 and payload_len < 126) return error.NonMinimalLength;
    if (extra == 8 and payload_len < 65536) return error.NonMinimalLength;
    var mask: ?[4]u8 = null;
    if (masked) mask = bytes[header_len - 4 ..][0..4].*;
    assert(header_len >= 2 and header_len <= header_max);
    return .{
        .opcode = opcode,
        .fin = fin,
        .mask = mask,
        .payload_len = payload_len,
        .header_len = header_len,
    };
}

pub fn header_len_for(payload_len: u64, masked: bool) u8 {
    assert(payload_len >> 63 == 0);
    const extra: u8 = if (payload_len < 126) 0 else if (payload_len < 65536) 2 else 8;
    const length: u8 = 2 + extra + @as(u8, if (masked) 4 else 0);
    assert(length >= 2 and length <= header_max);
    return length;
}

pub fn encode_header(
    out: *[header_max]u8,
    opcode: Opcode,
    fin: bool,
    payload_len: u64,
    mask: ?[4]u8,
) u8 {
    assert(payload_len >> 63 == 0);
    assert(!opcode.is_control() or (fin and payload_len <= control_payload_max));
    out[0] = @backingInt(opcode) | @as(u8, if (fin) 0x80 else 0);
    var length: u8 = 2;
    if (payload_len < 126) {
        out[1] = @intCast(payload_len);
    } else if (payload_len < 65536) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload_len), .big);
        length = 4;
    } else {
        out[1] = 127;
        std.mem.writeInt(u64, out[2..10], payload_len, .big);
        length = 10;
    }
    if (mask) |key| {
        out[1] |= 0x80;
        @memcpy(out[length..][0..4], &key);
        length += 4;
    }
    assert(length == header_len_for(payload_len, mask != null));
    return length;
}

pub fn apply_mask(mask: [4]u8, offset: u32, bytes: []u8) void {
    assert(@as(u64, offset) + bytes.len <= std.math.maxInt(u32));
    const phase: u32 = offset & 3;
    var rotated: [4]u8 = undefined;
    for (&rotated, 0..) |*byte, index| byte.* = mask[(phase + index) & 3];
    const word = std.mem.readInt(u32, &rotated, .little);
    var index: usize = 0;
    while (index + 4 <= bytes.len) : (index += 4) {
        const chunk = bytes[index..][0..4];
        std.mem.writeInt(u32, chunk, std.mem.readInt(u32, chunk, .little) ^ word, .little);
    }
    for (bytes[index..], 0..) |*byte, tail| byte.* ^= rotated[tail];
    assert(index + 4 > bytes.len);
}

pub fn copy_masked(dst: []u8, src: []const u8, mask: [4]u8, offset: u32) void {
    assert(dst.len == src.len);
    @memcpy(dst, src);
    apply_mask(mask, offset, dst);
    assert(dst.len == src.len);
}

pub fn close_code_valid(code: u16) bool {
    return (code >= 1000 and code <= 1003) or (code >= 1007 and code <= 1014) or
        (code >= 3000 and code <= 4999);
}
