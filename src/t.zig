const std = @import("std");
const builtin = @import("builtin");
const proto = @import("proto.zig");

const posix = std.posix;
const ArrayList = std.ArrayList;

const Message = proto.Message;

pub const allocator = std.testing.allocator;

/// Io handle for use by tests. Returns std.testing.io which is initialized by
/// test_runner.main via std.testing.io_instance = std.Io.Threaded.global_single_threaded.*.
/// Using a property accessor avoids the cross-module initialization problem:
/// test_runner.zig cannot import src/t.zig directly (module path collision),
/// but std.testing.io is a global that's always valid after test_runner.main runs.
pub var test_io: std.Io = undefined;

/// Returns a valid Io for test code. Prefers the explicitly-set test_io (if
/// initialized by a beforeAll hook), falling back to std.testing.io.
pub fn getIo() std.Io {
    // std.testing.io_instance is set by test_runner.main before any test runs.
    return std.testing.io;
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const expectSlice = std.testing.expectEqualSlices;

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    // Use std.testing.io which is initialized by test_runner.main via
    // std.testing.io_instance. This avoids the cross-module assignment
    // problem (test_runner.zig cannot import src/t.zig directly because
    // websocket.zig already imports t.zig under a different canonical path).
    std.testing.io.random(std.mem.asBytes(&seed));
    return std.Random.DefaultPrng.init(seed);
}

pub var arena = std.heap.ArenaAllocator.init(allocator);
pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub const Writer = struct {
    pos: usize,
    buf: std.ArrayList(u8),
    random: std.Random.DefaultPrng,

    pub fn init() Writer {
        return .{
            .pos = 0,
            .buf = .empty,
            .random = getRandom(),
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(allocator);
    }

    pub fn ping(self: *Writer) void {
        return self.pingPayload("");
    }

    pub fn pong(self: *Writer) void {
        return self.frame(true, 10, "", 0);
    }

    pub fn pingPayload(self: *Writer, payload: []const u8) void {
        return self.frame(true, 9, payload, 0);
    }

    pub fn textFrame(self: *Writer, fin: bool, payload: []const u8) void {
        return self.frame(fin, 1, payload, 0);
    }

    pub fn cont(self: *Writer, fin: bool, payload: []const u8) void {
        return self.frame(fin, 0, payload, 0);
    }

    pub fn frame(self: *Writer, fin: bool, op_code: u8, payload: []const u8, reserved: u8) void {
        var buf = &self.buf;

        const l = payload.len;
        var length_of_length: usize = 0;

        if (l > 125) {
            if (l < 65536) {
                length_of_length = 2;
            } else {
                length_of_length = 8;
            }
        }

        // 2 byte header + length_of_length + mask + payload_length
        const needed = 2 + length_of_length + 4 + l;
        buf.ensureUnusedCapacity(allocator, needed) catch unreachable;

        if (fin) {
            buf.appendAssumeCapacity(128 | op_code | reserved);
        } else {
            buf.appendAssumeCapacity(op_code | reserved);
        }

        if (length_of_length == 0) {
            buf.appendAssumeCapacity(128 | @as(u8, @intCast(l)));
        } else if (length_of_length == 2) {
            buf.appendAssumeCapacity(128 | 126);
            buf.appendAssumeCapacity(@intCast((l >> 8) & 0xFF));
            buf.appendAssumeCapacity(@intCast(l & 0xFF));
        } else {
            buf.appendAssumeCapacity(128 | 127);
            buf.appendAssumeCapacity(@intCast((l >> 56) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 48) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 40) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 32) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 24) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 16) & 0xFF));
            buf.appendAssumeCapacity(@intCast((l >> 8) & 0xFF));
            buf.appendAssumeCapacity(@intCast(l & 0xFF));
        }

        var mask: [4]u8 = undefined;
        self.random.random().bytes(&mask);
        // var mask = [_]u8{1, 1, 1, 1};

        buf.appendSliceAssumeCapacity(&mask);
        for (payload, 0..) |b, i| {
            buf.appendAssumeCapacity(b ^ mask[i & 3]);
        }
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *Writer) void {
        self.pos = 0;
        self.buf.clearRetainingCapacity();
    }

    pub fn read(
        self: *Writer,
        buf: []u8,
    ) !usize {
        const data = self.buf.items[self.pos..];

        if (data.len == 0 or buf.len == 0) {
            return 0;
        }

        // randomly fragment the data
        const to_read = self.random.random().intRangeAtMost(usize, 1, @min(data.len, buf.len));
        @memcpy(buf[0..to_read], data[0..to_read]);
        self.pos += to_read;
        return to_read;
    }
};

// ---------------------------------------------------------------------------
// Minimal syscall shims for socket operations removed from std.posix in 0.16.
//
// On Linux (with or without libc), posix.system exposes socket(), bind(),
// listen(), accept(), connect(), close(), write(), fcntl(), getsockname().
// These return c_int (negative on error) on libc builds or raw syscall
// return codes on bare-Linux builds.
//
// These shims are scoped to the test SocketPair ONLY. A shared posix_compat.zig
// module is needed before server.zig / client.zig can be migrated (Phase 4).
//
// SocketPair is gated to non-Windows because:
//   • Windows sockets use SOCKET (usize/HANDLE), not the POSIX fd_t (i32).
//   • The library itself targets Linux (epoll); Windows tests do not exercise
//     the server/conn path.
// ---------------------------------------------------------------------------

const compat = @import("posix_compat.zig");
pub const Stream = compat.Stream;

// ---------------------------------------------------------------------------

pub const SocketPair = struct {
    writer: Writer,
    client: Stream,
    server: Stream,

    const Opts = struct {
        port: ?u16 = null,
    };

    pub fn init(opts: Opts) @This() {
        const ip4 = std.Io.net.Ip4Address.parse("127.0.0.1", opts.port orelse 0) catch unreachable;
        var addr_in = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = @bitCast(ip4.bytes),
            .zero = @splat(0),
        };
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const listener = compat.socket(posix.AF.INET, posix.SOCK.STREAM | compat.SOCK_CLOEXEC, posix.IPPROTO.TCP) catch unreachable;
        defer compat.close(listener);

        compat.bind(listener, @ptrCast(&addr_in), addr_len) catch unreachable;
        compat.listen(listener, 1) catch unreachable;
        compat.getsockname(listener, @ptrCast(&addr_in), &addr_len) catch unreachable;

        const client = compat.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch unreachable;
        // Non-blocking connect, then restore blocking flags so the caller sees a synchronous connection.
        // fcntl is not available on Windows; on Windows we just do a plain blocking connect.
        if (comptime builtin.os.tag != .windows) {
            const o_nonblock = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
            const getfl = @field(posix.F, "GETFL");
            const setfl = @field(posix.F, "SETFL");
            const flags = compat.fcntl(client, getfl, 0) catch unreachable;
            _ = compat.fcntl(client, setfl, flags | o_nonblock) catch unreachable;
            compat.connect(client, @ptrCast(&addr_in), addr_len) catch |err| switch (err) {
                error.WouldBlock => {},
                else => unreachable,
            };
            _ = compat.fcntl(client, setfl, flags) catch unreachable;
        } else {
            compat.connect(client, @ptrCast(&addr_in), addr_len) catch unreachable;
        }

        const server = compat.accept(listener, @ptrCast(&addr_in), &addr_len, 0) catch unreachable;

        return .{
            .client = .{ .handle = client },
            .server = .{ .handle = server },
            .writer = Writer.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.writer.deinit();
        // assume test closes self.server
        self.client.close();
    }

    pub fn pingPayload(self: *@This(), payload: []const u8) void {
        self.writer.pingPayload(payload);
    }

    pub fn textFrame(self: *@This(), fin: bool, payload: []const u8) void {
        self.writer.textFrame(fin, payload);
    }

    pub fn cont(self: *@This(), fin: bool, payload: []const u8) void {
        self.writer.cont(fin, payload);
    }

    pub fn sendBuf(self: *@This()) void {
        self.client.writeAll(self.writer.bytes()) catch unreachable;
        self.writer.clear();
    }
};
