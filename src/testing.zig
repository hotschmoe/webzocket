//! Test helpers for handlers. Users of webzocket write unit tests against
//! their H type; the `Testing` harness wires a *Conn backed by a real
//! loopback socket pair so `conn.write(...)` actually sends bytes. The
//! harness reads the other end of the pair and exposes `expectMessage` /
//! `expectClose` to assert what the handler wrote.
//!
//! Self-standing Io: tests run under test_runner's std.testing.io which
//! is single-threaded and won't support `Io.async`. The Testing harness
//! carries its own `std.Io.Threaded` backend so vtable calls to
//! netListenIp / netConnectIp / netAccept / netRead / netWrite work on
//! every platform.

const std = @import("std");
const t = @import("t.zig");
const ws = @import("websocket.zig");

const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const Conn = ws.Conn;
const Message = ws.Message;

pub fn init(opts: Opts) *Testing {
    return Testing.initAlloc(opts) catch |err| std.debug.panic("Testing.init failed: {}", .{err});
}

pub const Opts = struct {
    port: ?u16 = null,
};

pub const Testing = struct {
    // Owned resources (freed in deinit, in reverse order).
    threaded: *std.Io.Threaded,
    io: Io,
    server_stream: net.Stream,
    client_stream: net.Stream,
    server_write_buf: []u8,
    client_read_buf: []u8,
    reader_buf: []u8,
    arena: *std.heap.ArenaAllocator,
    buffer_provider: *ws.buffer.Provider,

    // Stream wrappers. `server_writer` is pointed at by `conn.writer`;
    // `client_reader` is used internally to drain frames for
    // expectMessage. Both must be stable in memory because the Io.Reader
    // / Io.Writer interfaces use @fieldParentPtr on their addresses.
    server_writer: net.Stream.Writer,
    client_reader: net.Stream.Reader,

    // Public surface used by tests.
    conn: Conn,
    reader: ws.proto.Reader,
    closed: bool,
    received: std.ArrayList(Message),
    received_index: usize,

    fn initAlloc(opts: Opts) !*Testing {
        const gpa = t.allocator;
        const self = try gpa.create(Testing);
        errdefer gpa.destroy(self);
        try self.initInPlace(opts);
        return self;
    }

    fn initInPlace(self: *Testing, opts: Opts) !void {
        const gpa = t.allocator;

        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = std.Io.Threaded.init(gpa, .{});
        errdefer threaded.deinit();
        const io = threaded.io();

        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        // Bind an ephemeral loopback port, then connect + accept on the
        // same thread. On TCP, connect() completes on SYN-ACK from the
        // kernel (no app-level accept needed) so these can be sequenced.
        const port: u16 = opts.port orelse 0;
        var addr = try net.IpAddress.parse("127.0.0.1", port);
        var listener = try addr.listen(io, .{
            .reuse_address = true,
            .mode = .stream,
            .protocol = .tcp,
        });
        // After accept succeeds we no longer need the listener; close it
        // immediately to avoid lingering fd.
        defer listener.deinit(io);

        var client_stream = try addr.connect(io, .{ .mode = .stream });
        errdefer client_stream.close(io);
        var server_stream = try listener.accept(io);
        errdefer server_stream.close(io);

        const server_write_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(server_write_buf);
        const client_read_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(client_read_buf);
        const reader_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(reader_buf);

        const bp = try gpa.create(ws.buffer.Provider);
        errdefer gpa.destroy(bp);
        bp.* = try ws.buffer.Provider.init(arena.allocator(), io, .{
            .size = 0,
            .count = 0,
            .max = 20_971_520,
        });
        errdefer bp.deinit();

        self.* = .{
            .threaded = threaded,
            .io = io,
            .server_stream = server_stream,
            .client_stream = client_stream,
            .server_write_buf = server_write_buf,
            .client_read_buf = client_read_buf,
            .reader_buf = reader_buf,
            .arena = arena,
            .buffer_provider = bp,
            .server_writer = server_stream.writer(io, server_write_buf),
            .client_reader = client_stream.reader(io, client_read_buf),
            .conn = .{
                .io = io,
                .address = addr,
                .started = 0,
                .stream = server_stream,
                // Patched below — we need &self.server_writer to point
                // at the heap-stable copy, which only exists after this
                // struct-init assigns it.
                .writer = undefined,
            },
            .reader = ws.proto.Reader.init(reader_buf, bp, null),
            .closed = false,
            .received = .empty,
            .received_index = 0,
        };
        self.conn.writer = &self.server_writer;
    }

    pub fn deinit(self: *Testing) void {
        const gpa = t.allocator;
        self.received.deinit(gpa);
        self.reader.deinit();
        self.buffer_provider.deinit();
        gpa.destroy(self.buffer_provider);
        self.arena.deinit();
        gpa.destroy(self.arena);
        gpa.free(self.reader_buf);
        gpa.free(self.client_read_buf);
        gpa.free(self.server_write_buf);
        self.client_stream.close(self.io);
        self.server_stream.close(self.io);
        self.threaded.deinit();
        gpa.destroy(self.threaded);
        gpa.destroy(self);
    }

    pub fn expectMessage(self: *Testing, op: Message.Type, data: []const u8) !void {
        try self.ensureMessage();

        const message = self.received.items[self.received_index];
        self.received_index += 1;

        try t.expectEqual(op, message.type);
        if (op == .text) {
            try t.expectString(data, message.data);
        } else {
            try t.expectSlice(u8, data, message.data);
        }
    }

    pub fn expectClose(self: *Testing) !void {
        if (self.closed) return;

        self.fill() catch if (self.closed) return;

        return error.NotClosed;
    }

    fn ensureMessage(self: *Testing) !void {
        if (self.received_index < self.received.items.len) return;
        return self.fill();
    }

    fn fill(self: *Testing) !void {
        self.reader.fillIo(&self.client_reader.interface) catch |err| switch (err) {
            error.Closed => {
                self.closed = true;
                return err;
            },
        };

        while (true) {
            const result = (try self.reader.read()) orelse return error.NoMoreData;
            const more = result.@"0";
            const message = result.@"1";
            try self.received.append(t.allocator, message);
            if (!more) return;
        }
    }
};
