//! Windows std.Io viability spike.
//!
//! Goal: prove that Io.Threaded on Windows can host a TCP listener, dispatch
//! accept + per-connection work via Io.async, and shuttle bytes through
//! Io.Reader / Io.Writer with the stream's IOCP-backed vtable.
//!
//! If this runs green on Windows, the redesign's assumption — "one Io-driven
//! path per platform, no comptime blockingMode() branch" — holds. If it
//! doesn't, we bail back to io-async-redesign-todo.md and rethink.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const port: u16 = 9223;
const message = "hello webzocket!"; // exactly 16 bytes

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("spike: listening on 127.0.0.1:{d}\n", .{port});

    // Spawn the server-side half. Accepts one connection, echoes 16 bytes,
    // closes. Running via Io.async proves concurrent dispatch works.
    var server_future = Io.async(io, serveOne, .{ io, &server });

    // Main acts as the client. Connect, write, read-back, verify.
    try runClient(io, &addr);

    // Wait for the server frame to finish.
    try server_future.await(io);

    std.debug.print("spike: OK — Io.Threaded + Io.async + TCP echo works on Windows\n", .{});
}

fn serveOne(io: Io, server: *net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);

    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var msg: [message.len]u8 = undefined;
    try reader.interface.readSliceAll(&msg);

    try writer.interface.writeAll(&msg);
    try writer.interface.flush();

    std.debug.print("spike/server: echoed {d} bytes\n", .{msg.len});
}

fn runClient(io: Io, addr: *const net.IpAddress) !void {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll(message);
    try writer.interface.flush();

    var got: [message.len]u8 = undefined;
    try reader.interface.readSliceAll(&got);

    if (!std.mem.eql(u8, &got, message)) {
        std.debug.print("spike/client: MISMATCH got='{s}'\n", .{got});
        return error.EchoMismatch;
    }

    std.debug.print("spike/client: got echo back: '{s}'\n", .{got});
}
