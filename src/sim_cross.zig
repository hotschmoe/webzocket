const std = @import("std");
const ws = @import("webzocket");
const assert = @import("assert").assert;
const core = @import("sim_core.zig");

pub const static_max: u32 = 4096;
pub const backing_bytes: u32 = 1 << 20;
pub const log_capacity: u32 = 2048;
const drain_max: u32 = 4096;

pub const Record = struct { tag: u8, length: u32, hash: u64 };

pub const OldStream = struct {
    static_buffer: [static_max]u8 = undefined,
    backing: [backing_bytes]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    provider: ws.buffer.Provider = undefined,
    reader: ws.proto.Reader = undefined,
    head_state: u8 = 0,
    head_done: bool = false,
    log: core.Ring(Record, log_capacity) = .{},
    messages: u64 = 0,

    pub fn start(self: *OldStream, static_len: u32) void {
        assert(static_len >= 16 and static_len <= static_max);
        self.fba = std.heap.FixedBufferAllocator.init(&self.backing);
        self.provider = .{
            .pool = undefined,
            .pool_buffer_size = 0,
            .max_buffer_size = 1 << 19,
            .allocator = self.fba.allocator(),
            .io = undefined,
        };
        self.reader = ws.proto.Reader.init(self.static_buffer[0..static_len], &self.provider, null);
        self.head_state = 0;
        self.head_done = false;
        self.log.clear();
        self.messages = 0;
        assert(self.log.count == 0 and !self.head_done);
    }

    pub fn finish(self: *OldStream) void {
        self.reader.deinit();
    }

    fn skip_head(self: *OldStream, bytes: []const u8) u32 {
        assert(self.head_state <= 4);
        var used: u32 = 0;
        for (bytes) |byte| {
            if (self.head_done) break;
            used += 1;
            const state = self.head_state;
            if (byte == '\r' and (state == 0 or state == 2)) {
                self.head_state += 1;
            } else if (byte == '\n' and (state == 1 or state == 3)) {
                self.head_state += 1;
            } else self.head_state = if (byte == '\r') 1 else 0;
            if (self.head_state == 4) self.head_done = true;
        }
        assert(used <= bytes.len and self.head_state <= 4);
        return used;
    }

    pub fn feed(self: *OldStream, bytes: []const u8) !void {
        assert(self.reader.pos <= self.reader.buf.data.len);
        var rest = bytes[self.skip_head(bytes)..];
        while (rest.len > 0) {
            const space = self.reader.buf.data.len - self.reader.pos;
            if (space == 0) return error.ReaderStalled;
            const take = @min(rest.len, space);
            @memcpy(self.reader.buf.data[self.reader.pos..][0..take], rest[0..take]);
            self.reader.pos += take;
            rest = rest[take..];
            try self.drain();
        }
        assert(rest.len == 0);
    }

    fn drain(self: *OldStream) !void {
        assert(self.reader.pos <= self.reader.buf.data.len);
        for (0..drain_max) |_| {
            const result = (try self.reader.read()) orelse break;
            const message = result[1];
            if (self.log.is_full()) return error.LogFull;
            self.log.push(.{
                .tag = tag_of(message.type),
                .length = @intCast(message.data.len),
                .hash = core.hash_bytes(message.data),
            });
            self.messages += 1;
            self.reader.done(message.type);
            if (!result[0]) break;
        } else return error.DrainLimit;
        if (self.reader.isEmpty()) self.fba.reset();
        assert(self.log.count <= log_capacity);
    }
};

pub fn tag_of(kind: ws.MessageType) u8 {
    return switch (kind) {
        .text => 1,
        .binary => 2,
        .close => 8,
        .ping => 9,
        .pong => 10,
    };
}

pub fn old_accepts_request(bytes: []const u8, target: []const u8, key: []const u8) bool {
    assert(bytes.len <= 4096);
    assert(target.len > 0 and key.len > 0);
    var storage: [4096]u8 = undefined;
    var keys: [32][]const u8 = undefined;
    var values: [32][]const u8 = undefined;
    @memcpy(storage[0..bytes.len], bytes);
    var state = ws.Handshake.State{
        .buf = storage[0..bytes.len],
        .len = bytes.len,
        .req_headers = .{ .len = 0, .keys = &keys, .values = &values },
        .res_headers = .{ .len = 0, .keys = &.{}, .values = &.{} },
        .pool = undefined,
    };
    const parsed = ws.Handshake.parse(&state) catch return false;
    const request = parsed orelse return false;
    return std.mem.eql(u8, request.url, target) and std.mem.eql(u8, request.key, key);
}
