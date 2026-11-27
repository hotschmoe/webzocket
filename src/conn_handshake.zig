const std = @import("std");
const assert = @import("assert").assert;

pub const HandshakeError = error{
    HandshakeTooLarge,
    BadLineEnding,
    BadByte,
    BadRequestLine,
    BadMethod,
    BadTarget,
    BadHost,
    BadHttpVersion,
    BadHeader,
    DuplicateHeader,
    MissingHost,
    BadUpgrade,
    BadConnection,
    BadWebSocketVersion,
    BadKey,
    BadStatusLine,
    BadStatus,
    BadAccept,
    ExtensionNotOffered,
    SubprotocolNotOffered,
};

pub const key_len: u8 = 24;
pub const accept_len: u8 = 28;
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const reply_head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
    "Connection: Upgrade\r\nSec-WebSocket-Accept: ";
pub const reply_len: u32 = reply_head.len + accept_len + 4;
pub const rejection = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n" ++
    "Content-Length: 0\r\nSec-WebSocket-Version: 13\r\n\r\n";
const request_fixed = " HTTP/1.1\r\nHost: ";
const request_middle = "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ";

pub const Request = struct {
    target: []const u8,
    key: [key_len]u8,
};

const Header = struct { name: []const u8, value: []const u8 };

const Lines = struct {
    rest: []const u8,

    fn next(self: *Lines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        assert(self.rest.len >= 2);
        const end = std.mem.find(u8, self.rest, "\r\n").?;
        const line = self.rest[0..end];
        self.rest = self.rest[end + 2 ..];
        return line;
    }
};

pub fn accept_key(key: []const u8, out: *[accept_len]u8) void {
    assert(key.len == key_len);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    assert(digest.len == 20 and key.len == key_len);
    const text = std.base64.standard.Encoder.encode(out, &digest);
    assert(text.len == accept_len);
}

pub fn encode_key(raw: *const [16]u8, out: *[key_len]u8) void {
    const text = std.base64.standard.Encoder.encode(out, raw);
    assert(text.len == key_len);
    assert(std.mem.endsWith(u8, text, "=="));
}

fn key_valid(text: []const u8) bool {
    if (text.len != key_len) return false;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return false;
    if (size != 16) return false;
    assert(text.len == key_len);
    var raw: [16]u8 = undefined;
    decoder.decode(&raw, text) catch return false;
    var again: [key_len]u8 = undefined;
    encode_key(&raw, &again);
    const same = std.mem.eql(u8, &again, text);
    assert(!same or std.mem.endsWith(u8, text, "=="));
    return same;
}

// Returns the length of the head once CRLFCRLF has been seen; scan resumes where it stopped.
pub fn scan_head(buf: []const u8, scan: *u32) HandshakeError!?u32 {
    assert(scan.* <= buf.len);
    var index: usize = scan.*;
    while (index < buf.len) : (index += 1) {
        const byte = buf[index];
        if (byte == '\n') {
            if (index == 0 or buf[index - 1] != '\r') return error.BadLineEnding;
            if (index >= 3 and std.mem.eql(u8, buf[index - 3 .. index + 1], "\r\n\r\n")) {
                scan.* = @intCast(index + 1);
                return scan.*;
            }
        } else if (byte == '\r') {
            if (index + 1 == buf.len) break;
            if (buf[index + 1] != '\n') return error.BadLineEnding;
        } else if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.BadByte;
    }
    scan.* = @intCast(index);
    assert(index <= buf.len and scan.* <= buf.len);
    return null;
}

fn token_char(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'z', 'A'...'Z' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn split_header(text: []const u8) HandshakeError!Header {
    if (text.len == 0 or text[0] == ' ' or text[0] == '\t') return error.BadHeader;
    const colon = std.mem.findScalar(u8, text, ':') orelse return error.BadHeader;
    const name = text[0..colon];
    assert(name.len == colon);
    if (name.len == 0) return error.BadHeader;
    for (name) |byte| if (!token_char(byte)) return error.BadHeader;
    const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
    assert(value.len <= text.len and colon < text.len);
    return .{ .name = name, .value = value };
}

fn has_token(value: []const u8, token: []const u8) bool {
    assert(token.len > 0);
    var items = std.mem.splitScalar(u8, value, ',');
    while (items.next()) |item| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \t"), token)) return true;
    }
    assert(!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token));
    return false;
}

fn is_name(header: Header, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(header.name, name);
}

fn visible(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    for (text) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    assert(text.len == 0 or (text[0] >= 0x21 and text[text.len - 1] <= 0x7e));
    return text.len > 0;
}

fn parse_request_line(line: []const u8) HandshakeError![]const u8 {
    assert(std.mem.findScalar(u8, line, '\r') == null);
    const first = std.mem.findScalar(u8, line, ' ') orelse return error.BadRequestLine;
    if (first == 0) return error.BadRequestLine;
    const rest = line[first + 1 ..];
    const second = std.mem.findScalar(u8, rest, ' ') orelse return error.BadRequestLine;
    if (!std.mem.eql(u8, line[0..first], "GET")) return error.BadMethod;
    const target = rest[0..second];
    if (!visible(target)) return error.BadTarget;
    if (!std.mem.eql(u8, rest[second + 1 ..], "HTTP/1.1")) return error.BadHttpVersion;
    assert(target.len > 0 and target.len < line.len);
    return target;
}

const Seen = struct {
    host: bool = false,
    upgrade: bool = false,
    connection: bool = false,
    version: bool = false,
    key: bool = false,
    accept: bool = false,
};

fn note_request(seen: *Seen, header: Header, request: *Request) HandshakeError!void {
    assert(header.name.len > 0 and std.mem.findScalar(u8, header.name, ':') == null);
    if (is_name(header, "host")) {
        if (seen.host) return error.DuplicateHeader;
        if (header.value.len == 0) return error.MissingHost;
        seen.host = true;
    } else if (is_name(header, "upgrade")) {
        seen.upgrade = seen.upgrade or has_token(header.value, "websocket");
    } else if (is_name(header, "connection")) {
        seen.connection = seen.connection or has_token(header.value, "upgrade");
    } else if (is_name(header, "sec-websocket-version")) {
        if (seen.version) return error.DuplicateHeader;
        if (!std.mem.eql(u8, header.value, "13")) return error.BadWebSocketVersion;
        seen.version = true;
    } else if (is_name(header, "sec-websocket-key")) {
        if (seen.key) return error.DuplicateHeader;
        if (!key_valid(header.value)) return error.BadKey;
        @memcpy(&request.key, header.value);
        seen.key = true;
    }
    assert(!seen.key or key_valid(&request.key));
}

pub fn parse_request(head: []const u8) HandshakeError!Request {
    assert(std.mem.endsWith(u8, head, "\r\n\r\n"));
    const line_end = std.mem.find(u8, head, "\r\n").?;
    const target = try parse_request_line(head[0..line_end]);
    var request: Request = .{ .target = target, .key = undefined };
    var seen: Seen = .{};
    var lines = Lines{ .rest = head[line_end + 2 ..] };
    while (lines.next()) |text| {
        if (text.len == 0) break;
        try note_request(&seen, try split_header(text), &request);
    }
    if (!seen.host) return error.MissingHost;
    if (!seen.upgrade) return error.BadUpgrade;
    if (!seen.connection) return error.BadConnection;
    if (!seen.key) return error.BadKey;
    if (!seen.version) return error.BadWebSocketVersion;
    assert(lines.rest.len == 0);
    return request;
}

fn parse_status_line(line: []const u8) HandshakeError!void {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    if (!std.mem.startsWith(u8, line, "HTTP/1.1 ")) return error.BadStatusLine;
    const status = line[9..];
    if (status.len < 3 or (status.len > 3 and status[3] != ' ')) return error.BadStatusLine;
    for (status[0..3]) |byte| if (byte < '0' or byte > '9') return error.BadStatusLine;
    if (!std.mem.eql(u8, status[0..3], "101")) return error.BadStatus;
    assert(line.len >= 12);
}

fn note_reply(seen: *Seen, header: Header, expected: *const [accept_len]u8) HandshakeError!void {
    assert(header.name.len > 0);
    if (is_name(header, "upgrade")) {
        seen.upgrade = seen.upgrade or has_token(header.value, "websocket");
    } else if (is_name(header, "connection")) {
        seen.connection = seen.connection or has_token(header.value, "upgrade");
    } else if (is_name(header, "sec-websocket-accept")) {
        if (seen.accept) return error.DuplicateHeader;
        if (!std.mem.eql(u8, header.value, expected)) return error.BadAccept;
        seen.accept = true;
    } else if (is_name(header, "sec-websocket-extensions")) {
        return error.ExtensionNotOffered;
    } else if (is_name(header, "sec-websocket-protocol")) {
        return error.SubprotocolNotOffered;
    }
    assert(seen.accept or !is_name(header, "sec-websocket-accept"));
}

pub fn parse_reply(head: []const u8, key: *const [key_len]u8) HandshakeError!void {
    assert(std.mem.endsWith(u8, head, "\r\n\r\n"));
    const line_end = std.mem.find(u8, head, "\r\n").?;
    try parse_status_line(head[0..line_end]);
    var expected: [accept_len]u8 = undefined;
    accept_key(key, &expected);
    var seen: Seen = .{};
    var lines = Lines{ .rest = head[line_end + 2 ..] };
    while (lines.next()) |text| {
        if (text.len == 0) break;
        try note_reply(&seen, try split_header(text), &expected);
    }
    if (!seen.upgrade) return error.BadUpgrade;
    if (!seen.connection) return error.BadConnection;
    if (!seen.accept) return error.BadAccept;
    assert(lines.rest.len == 0);
}

pub fn request_len(host: []const u8, target: []const u8) HandshakeError!u32 {
    assert(host.len <= std.math.maxInt(u32) and target.len <= std.math.maxInt(u32));
    if (!visible(host)) return error.BadHost;
    if (!visible(target)) return error.BadTarget;
    const total = 4 + target.len + request_fixed.len + host.len + request_middle.len + key_len + 4;
    if (total > std.math.maxInt(u32)) return error.HandshakeTooLarge;
    assert(total >= request_fixed.len + request_middle.len + key_len + 4);
    return @intCast(total);
}

fn copy_at(out: []u8, position: u32, text: []const u8) u32 {
    assert(position + text.len <= out.len);
    @memcpy(out[position..][0..text.len], text);
    const end = position + @as(u32, @intCast(text.len));
    assert(end >= position);
    return end;
}

pub fn write_request(out: []u8, host: []const u8, target: []const u8, key: []const u8) u32 {
    assert(key.len == key_len);
    assert(out.len >= 4 + target.len + host.len + key_len + 4);
    var position = copy_at(out, 0, "GET ");
    position = copy_at(out, position, target);
    position = copy_at(out, position, request_fixed);
    position = copy_at(out, position, host);
    position = copy_at(out, position, request_middle);
    position = copy_at(out, position, key);
    position = copy_at(out, position, "\r\n\r\n");
    const fixed = 4 + target.len + request_fixed.len + host.len;
    assert(position == fixed + request_middle.len + key_len + 4);
    return position;
}

pub fn write_reply(out: []u8, key: []const u8) u32 {
    assert(key.len == key_len);
    assert(out.len >= reply_len);
    var accept: [accept_len]u8 = undefined;
    accept_key(key, &accept);
    var position = copy_at(out, 0, reply_head);
    position = copy_at(out, position, &accept);
    position = copy_at(out, position, "\r\n\r\n");
    assert(position == reply_len);
    return position;
}
