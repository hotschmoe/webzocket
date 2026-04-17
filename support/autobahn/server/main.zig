const std = @import("std");
const websocket = @import("webzocket");

const Conn = websocket.Conn;
const Message = websocket.Message;
const Handshake = websocket.Handshake;
const Allocator = std.mem.Allocator;

pub const std_options = std.Options{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .warn },
} };

var nonblocking_server: websocket.Server(Handler) = undefined;
var nonblocking_bp_server: websocket.Server(Handler) = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    if (@import("builtin").os.tag != .windows) {
        std.posix.sigaction(.TERM, &.{
            .handler = .{ .handler = shutdown },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
    }

    const t1 = try startNonBlocking(allocator, io);
    const t2 = try startNonBlockingBufferPool(allocator, io);

    t1.join();
    t2.join();

    nonblocking_server.deinit();
    nonblocking_bp_server.deinit();
}

fn startNonBlocking(allocator: Allocator, io: std.Io) !std.Thread {
    nonblocking_server = try websocket.Server(Handler).init(allocator, io, .{
        .port = 9224,
        .address = "127.0.0.1",
        .buffers = .{
            .small_pool = 0,
            .small_size = 8192,
        },
        .max_message_size = 20_000_000,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 10,
        },
    });
    return try nonblocking_server.listenInNewThread({});
}

fn startNonBlockingBufferPool(allocator: Allocator, io: std.Io) !std.Thread {
    nonblocking_bp_server = try websocket.Server(Handler).init(allocator, io, .{
        .port = 9225,
        .address = "127.0.0.1",
        .buffers = .{
            .small_pool = 3,
            .small_size = 8192,
        },
        .max_message_size = 20_000_000,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 10,
        },
    });
    return try nonblocking_bp_server.listenInNewThread({});
}

const Handler = struct {
    conn: *Conn,

    pub fn init(_: *const Handshake, conn: *Conn, ctx: void) !Handler {
        _ = ctx;
        return .{ .conn = conn };
    }

    pub fn clientMessage(self: *Handler, data: []const u8, tpe: websocket.Message.TextType) !void {
        switch (tpe) {
            .binary => try self.conn.writeBin(data),
            .text => {
                if (std.unicode.utf8ValidateSlice(data)) {
                    try self.conn.writeText(data);
                } else {
                    self.conn.close(.{ .code = 1007 }) catch {};
                }
            },
        }
    }
};

fn shutdown(_: c_int) callconv(.c) void {
    nonblocking_server.stop();
    nonblocking_bp_server.stop();
}
