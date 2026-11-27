const std = @import("std");
const g = @import("fuzz_generate.zig");
const assert = @import("assert").assert;

pub fn generate_extra(case: *g.Case, random: std.Random) !void {
    assert(case.class >= 64 and case.class < g.classes);
    if (case.class == 84 or case.class == 85 or case.class >= 96)
        return g.generate_regression(case, random);
    if (case.class >= 86) return handshake(case);
    var frame = g.Frame{ .opcode = 1, .payload = "data", .masked = random.boolean() };
    if (case.class < 74) {
        const reserved = [_]u8{ 3, 4, 5, 6, 7, 11, 12, 13, 14, 15 };
        frame.opcode = reserved[case.class - 64];
        case.expected_error = error.InvalidMessageType;
    } else if (case.class < 77) {
        frame.opcode = g.opcodes[case.class - 74 + 2];
        frame.final = false;
        case.expected_error = error.FragmentedControl;
    } else if (case.class < 80) {
        var payload: [126]u8 = undefined;
        random.bytes(&payload);
        frame.opcode = g.opcodes[case.class - 77 + 2];
        frame.payload = &payload;
        try g.append_frame(case, frame);
        case.outcome = .rejected;
        case.expected_error = error.LargeControl;
        return;
    } else if (case.class < 83) {
        return fragment_limit(case);
    } else if (case.class == 83) {
        return compressed_fragment(case);
    }
    try g.append_frame(case, frame);
    if (case.expected_error != null) {
        case.outcome = .rejected;
    } else try case.expect_message(frame.opcode, frame.payload);
    assert(case.length > 0);
}

fn fragment_limit(case: *g.Case) !void {
    assert(case.class >= 80 and case.class <= 82);
    case.forbid_allocation = false;
    case.maximum = 8;
    try g.append_frame(case, .{ .opcode = 1, .payload = "first", .final = false });
    if (case.class == 82) {
        case.outcome = .incomplete;
        return;
    }
    try g.append_frame(case, .{
        .opcode = 0,
        .payload = "second",
        .final = case.class == 80,
    });
    case.outcome = .rejected;
    case.expected_error = error.TooLarge;
    assert(case.length == 15);
}

fn compressed_fragment(case: *g.Case) !void {
    assert(case.count == 0);
    case.compression = true;
    case.forbid_allocation = false;
    var message: [70000]u8 = undefined;
    for (&message, 0..) |*byte, index| byte.* = @intCast((index * 7 + index / 1000) % 251);
    var storage: [71000]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&writer, &window, .raw, .default);
    try compressor.writer.writeAll(&message);
    try compressor.finish();
    const payload = writer.buffered();
    try g.append_frame(case, .{
        .opcode = 2,
        .payload = payload[0..6],
        .final = false,
        .flags = 64,
    });
    try g.append_frame(case, .{ .opcode = 9, .payload = "ping" });
    try case.expect_message(9, "ping");
    try g.append_frame(case, .{ .opcode = 0, .payload = payload[6..], .masked = true });
    try case.expect_message(2, &message);
    assert(case.count == 2);
}

fn handshake(case: *g.Case) !void {
    assert(case.class >= 86);
    case.handshake = true;
    try g.expect_key(case, "dGhlIHNhbXBsZSBub25jZQ==");
    try case.append(if (case.class == 92) "POST / HTTP/1.1\r\n" else "GET / HTTP/1.1\r\n");
    if (case.class != 89) try case.append("Host: localhost\r\n");
    try case.append(if (case.class == 86) "Upgrade: wrong\r\n" else "Upgrade: websocket\r\n");
    try case.append(if (case.class == 87) "Connection: close\r\n" else "Connection: Upgrade\r\n");
    if (case.class != 88) try case.append("Sec-WebSocket-Version: 13\r\n");
    try case.append("Sec-WebSocket-Key: ");
    if (case.class == 90) try g.expect_key(case, "");
    try case.append(case.expected_key[0..case.key_length]);
    try case.append("\r\n");
    switch (case.class) {
        86 => case.expected_error = error.InvalidUpgrade,
        87 => case.expected_error = error.InvalidConnection,
        88 => case.expected_error = error.MissingHeaders,
        91 => {
            try case.append("Sec-WebSocket-Version: 12\r\n");
            case.expected_error = error.InvalidVersion;
        },
        93 => {
            try case.append("Upgrade: websocket, other\r\n");
            case.expected_error = error.InvalidUpgrade;
        },
        94 => return bare_lf(case),
        95 => case.bytes[15] = 'X',
        else => {},
    }
    try case.append("\r\n");
    if (case.expected_error != null) case.outcome = .rejected;
    assert(case.length > 20);
}

fn bare_lf(case: *g.Case) !void {
    assert(case.handshake);
    var output: u32 = 0;
    for (case.bytes[0..case.length]) |byte| {
        if (byte == '\r') continue;
        case.bytes[output] = byte;
        output += 1;
    }
    case.length = output;
    try case.append("\n");
    case.outcome = .incomplete;
    assert(case.length == output + 1);
}
