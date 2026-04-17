//! Io-native server implementation. Work in progress for task #3 of the
//! redesign. Once this passes the current server test set, it will replace
//! `src/server/server.zig`.
//!
//! Differences from the old implementation:
//!   - One Io-driven path. No comptime blockingMode() branching.
//!   - No Loop/EPoll/KQueue. `std.Io.net` handles readiness; Io.async
//!     spawns a frame per accepted connection.
//!   - No ConnManager / pending linked list. Per-connection state is the
//!     serve frame's stack.
//!   - No posix_compat usage. All socket ops go through std.Io.net.
//!   - ThreadPool is retained but demoted — it's wired as an opt-in CPU
//!     offload helper in task #4.
//!
//! API parity with the old server (for now):
//!   - Same `Server(H)` shape (init/deinit/listen/stop).
//!   - Same `Conn` public methods (write/writeText/writeBin/writePing/
//!     writePong/close/writeFramed/writeBuffer/isClosed).
//!   - Same `H` handler contract (init, afterInit, close, clientMessage,
//!     clientClose, clientPing, clientPong). clientMessage supports the
//!     four overloads the old server did.

const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");
const old_server = @import("server.zig");

const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const log = std.log.scoped(.websocket);

const OpCode = proto.OpCode;
const ProtoReader = proto.Reader;
const Message = proto.Message;
pub const Handshake = @import("handshake.zig").Handshake;
const Compression = @import("../websocket.zig").Compression;
const FallbackAllocator = @import("fallback_allocator.zig").FallbackAllocator;

// Config + WorkerState are unchanged from the old server — re-export so the
// public API shape matches while the swap is in flight.
pub const Config = old_server.Config;
pub const WorkerState = old_server.WorkerState;

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; // 1002

// ---------------------------------------------------------------------------
// Conn — public handle passed to handlers.
// ---------------------------------------------------------------------------
//
// The serve frame owns the underlying net.Stream. Conn holds a pointer to a
// net.Stream.Writer that also lives on the serve frame — all outbound writes
// go through it under `lock`. The read side is not on Conn; only the serve
// frame reads the socket (single consumer).
//
// Other threads may call Conn methods (write/close) concurrently with the
// serve frame's message loop. `lock` serializes them. The `_closed` flag is
// read without acquiring the lock so `isClosed()` stays cheap on the hot
// path.

pub const Conn = struct {
    io: Io,
    address: net.IpAddress,
    started: u32,
    stream: net.Stream,

    // Points at the net.Stream.Writer owned by the serve frame. The writer
    // is valid for the entire lifetime of the handler (init → close). All
    // access goes through `lock`.
    writer: *net.Stream.Writer,

    lock: Io.Mutex = .init,
    _closed: bool = false,

    // compression is disabled in the 0.16 branch (see websocket.zig note)
    compression: ?*Conn.CompressionState = null,

    pub const CompressionState = struct {
        // placeholder; real fields get filled when compression lands (#4).
        _unused: u8 = 0,
    };

    pub fn isClosed(self: *Conn) bool {
        return @atomicLoad(bool, &self._closed, .monotonic);
    }

    pub fn write(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeText(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeBin(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.binary, data);
    }

    pub fn writePing(self: *Conn, data: []u8) !void {
        return self.writeFrame(.ping, data);
    }

    pub fn writePong(self: *Conn, data: []u8) !void {
        return self.writeFrame(.pong, data);
    }

    pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
        var header_buf: [10]u8 = undefined;
        const header = proto.writeFrameHeader(&header_buf, op_code, data.len, false);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        if (self.isClosed()) return error.Closed;

        try self.writer.interface.writeAll(header);
        if (data.len > 0) try self.writer.interface.writeAll(data);
        try self.writer.interface.flush();
    }

    // Write a fully-framed byte slice (header already included). Used by
    // the handshake reply path and for pre-canned close/pong frames.
    pub fn writeFramed(self: *Conn, data: []const u8) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        if (self.isClosed()) return error.Closed;

        try self.writer.interface.writeAll(data);
        try self.writer.interface.flush();
    }

    pub const CloseOpts = struct {
        code: u16 = 1000,
        reason: []const u8 = "",
    };

    pub fn close(self: *Conn, opts: CloseOpts) !void {
        if (self.isClosed()) return;
        defer self.markClosed();

        const reason = opts.reason;
        if (reason.len == 0) {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, opts.code, .big);
            return self.writeFrame(.close, &buf);
        }

        if (reason.len > 123) return error.ReasonTooLong;

        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], opts.code, .big);
        @memcpy(payload[2 .. 2 + reason.len], reason);
        return self.writeFrame(.close, payload[0 .. 2 + reason.len]);
    }

    // Mark the conn as closed from the handler's perspective. The underlying
    // stream is closed by the serve frame on exit (defer stream.close). This
    // keeps stream lifetime tied to the frame, avoiding use-after-free if a
    // handler calls conn.close while the frame is still reading.
    fn markClosed(self: *Conn) void {
        _ = @atomicRmw(bool, &self._closed, .Xchg, true, .monotonic);
    }

    pub fn writeBuffer(self: *Conn, allocator: Allocator, op_code: OpCode) BufferedWriter {
        return .{
            .conn = self,
            .buf = .empty,
            .op_code = op_code,
            .allocator = allocator,
            .interface = .{
                .vtable = &.{ .drain = BufferedWriter.drain },
                .buffer = &.{},
            },
        };
    }

    pub const BufferedWriter = struct {
        conn: *Conn,
        op_code: OpCode,
        allocator: Allocator,
        buf: std.ArrayList(u8),
        interface: std.Io.Writer,

        pub const Error = Allocator.Error;

        pub fn deinit(self: *BufferedWriter) void {
            self.buf.deinit(self.allocator);
        }

        pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
            _ = splat;
            const self: *BufferedWriter = @alignCast(@fieldParentPtr("interface", io_w));
            self.buf.appendSlice(self.allocator, data[0]) catch return error.WriteFailed;
            return data[0].len;
        }

        pub fn send(self: *BufferedWriter) !void {
            return self.conn.writeFrame(self.op_code, self.buf.items);
        }
    };
};

// ---------------------------------------------------------------------------
// Server(H) — generic over the user handler.
// ---------------------------------------------------------------------------

pub fn Server(comptime H: type) type {
    return struct {
        io: Io,
        allocator: Allocator,
        config: Config,
        _state: WorkerState,

        _listener: ?net.Server = null,
        _shutdown: std.atomic.Value(bool) = .init(false),
        _group: Io.Group = .init,
        _listener_lock: Io.Mutex = .init,

        const Self = @This();

        pub fn init(allocator: Allocator, io: Io, config: Config) !Self {
            if (config.compression != null) {
                log.err("Compression is disabled as part of the 0.15 upgrade.", .{});
                return error.InvalidConfiguraion;
            }

            const state = try WorkerState.init(allocator, io, config);
            return .{
                .io = io,
                .allocator = allocator,
                .config = config,
                ._state = state,
            };
        }

        pub fn deinit(self: *Self) void {
            self._state.deinit();
        }

        // Blocks the current frame. Accepts connections until stop() is
        // called or the listener fails. Each accepted socket is spawned as
        // a child frame in `_group`, so shutdown waits for in-flight
        // handlers to exit via the group.
        pub fn listen(self: *Self, ctx: anytype) !void {
            const port = self.config.port;
            const host = self.config.address;
            var addr = try net.IpAddress.parse(host, port);

            const server = try addr.listen(self.io, .{
                .reuse_address = true,
                .mode = .stream,
                .protocol = .tcp,
            });

            {
                self._listener_lock.lockUncancelable(self.io);
                defer self._listener_lock.unlock(self.io);
                self._listener = server;
            }

            log.info("listening on {f}:{d}", .{ host, port });

            const Ctx = @TypeOf(ctx);

            while (!self._shutdown.load(.acquire)) {
                const stream = (&self._listener.?).accept(self.io) catch |err| switch (err) {
                    error.Canceled, error.SocketNotListening => break,
                    error.ConnectionAborted, error.BlockedByFirewall => {
                        log.debug("accept rejected: {}", .{err});
                        continue;
                    },
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                        log.warn("accept transient resource pressure: {}", .{err});
                        // brief backoff so we don't tight-loop
                        std.Io.sleep(self.io, .{ .millis = 10 }, .monotonic) catch return;
                        continue;
                    },
                    else => return err,
                };

                self._group.async(self.io, serveOne, .{ self, stream, ctx, Ctx });
            }

            // Drain in-flight frames.
            self._group.await(self.io) catch {};

            // Explicit listener deinit — ownership moved back here after the loop.
            self._listener_lock.lockUncancelable(self.io);
            defer self._listener_lock.unlock(self.io);
            if (self._listener) |*listener| {
                listener.deinit(self.io);
                self._listener = null;
            }
        }

        pub fn stop(self: *Self) void {
            self._shutdown.store(true, .release);

            // Cancel the listener so accept() returns error.SocketNotListening.
            // We take the lock to observe the listener state safely, but the
            // actual deinit happens on the listen() thread after the accept loop
            // exits, to avoid racing with it.
            self._listener_lock.lockUncancelable(self.io);
            defer self._listener_lock.unlock(self.io);
            if (self._listener) |*listener| {
                // shutdown the socket; accept() will wake with SocketNotListening.
                _ = listener.socket.shutdown(self.io, .both) catch {};
            }

            // Cancel all in-flight serve frames. Each frame's next Io call
            // will observe error.Canceled and exit through its normal defers.
            self._group.cancel(self.io) catch {};
        }

        pub const HandlerCtx = anyopaque; // erased for the Io.Group.async tuple

        fn serveOne(
            self: *Self,
            stream_in: net.Stream,
            ctx: anytype,
            comptime Ctx: type,
        ) Io.Cancelable!void {
            _ = Ctx;
            var stream = stream_in;
            defer stream.close(self.io);

            // One buffer for reads, one for writes. Sized from config.
            const small_size = self.config.buffers.small_size orelse 2048;
            const read_buf = self.allocator.alloc(u8, small_size) catch |err| {
                log.warn("failed to allocate conn read buffer: {}", .{err});
                return;
            };
            defer self.allocator.free(read_buf);
            const write_buf = self.allocator.alloc(u8, small_size) catch |err| {
                log.warn("failed to allocate conn write buffer: {}", .{err});
                return;
            };
            defer self.allocator.free(write_buf);

            var io_reader = stream.reader(self.io, read_buf);
            var io_writer = stream.writer(self.io, write_buf);

            var conn: Conn = .{
                .io = self.io,
                .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } }, // TODO: peer addr via getpeername
                .started = nowSeconds(self.io),
                .stream = stream,
                .writer = &io_writer,
            };

            // --- Handshake phase ---
            const hs_state = self._state.handshake_pool.acquire() catch |err| {
                log.warn("handshake pool exhausted: {}", .{err});
                return;
            };
            defer hs_state.release();

            const parsed = readHandshake(&conn, &io_reader.interface, hs_state) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    respondHandshakeError(&conn, err);
                    return;
                },
            };

            var handshake = parsed;
            var handler = H.init(&handshake, &conn, ctx) catch |err| {
                if (comptime std.meta.hasFn(H, "handshakeErrorResponse")) {
                    conn.writeFramed(H.handshakeErrorResponse(err)) catch {};
                } else {
                    respondHandshakeError(&conn, err);
                }
                log.debug("{s}.init rejected: {}", .{ @typeName(H), err });
                return;
            };
            defer if (comptime std.meta.hasFn(H, "close")) handler.close();

            var reply_buf: [2048]u8 = undefined;
            const reply = Handshake.createReply(
                handshake.key,
                handshake.res_headers,
                false, // compression disabled
                &reply_buf,
            ) catch |err| {
                log.warn("failed to build handshake reply: {}", .{err});
                return;
            };
            conn.writeFramed(reply) catch |err| {
                log.debug("failed to send handshake reply: {}", .{err});
                return;
            };

            if (comptime std.meta.hasFn(H, "afterInit")) {
                const params = @typeInfo(@TypeOf(H.afterInit)).@"fn".params;
                const res = if (params.len == 1) handler.afterInit() else handler.afterInit(ctx);
                res catch |err| {
                    log.debug("{s}.afterInit error: {}", .{ @typeName(H), err });
                    return;
                };
            }

            // --- Message phase ---
            const static_buf = self.allocator.alloc(u8, small_size) catch return;
            defer self.allocator.free(static_buf);

            var reader = ProtoReader.init(static_buf, &self._state.buffer_provider, null);
            defer reader.deinit();

            messageLoop(H, &handler, &conn, &reader, &io_reader.interface) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.debug("message loop exited with error: {}", .{err});
                },
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

fn readHandshake(conn: *Conn, io_reader: *std.Io.Reader, state: *Handshake.State) !Handshake {
    var buf = state.buf;
    while (true) {
        if (state.len == buf.len) {
            return error.RequestTooLarge;
        }
        const n = io_reader.readSliceShort(buf[state.len..]) catch |err| switch (err) {
            error.ReadFailed => return error.ConnectionClosed,
        };
        if (n == 0) return error.ConnectionClosed;
        state.len += n;

        if (Handshake.parse(state) catch |err| {
            log.debug("({f}) handshake parse error: {}", .{ conn.address, err });
            return err;
        }) |hs| {
            return hs;
        }
        // else: need more bytes; loop
    }
}

fn respondHandshakeError(conn: *Conn, err: anyerror) void {
    if (err == error.Close) return;
    var stack_buf: [256]u8 = undefined;
    const response: []const u8 = switch (err) {
        error.RequestTooLarge => buildError(400, "too large"),
        error.Timeout => buildError(400, "timeout"),
        error.InvalidProtocol => buildError(400, "invalid protocol"),
        error.InvalidRequestLine => buildError(400, "invalid requestline"),
        error.InvalidHeader => buildError(400, "invalid header"),
        error.InvalidUpgrade => buildError(400, "invalid upgrade"),
        error.InvalidVersion => buildError(400, "invalid version"),
        error.InvalidConnection => buildError(400, "invalid connection"),
        error.MissingHeaders => buildError(400, "missingheaders"),
        error.Empty => buildError(400, "invalid request"),
        error.ConnectionClosed => return,
        else => std.fmt.bufPrint(
            &stack_buf,
            "HTTP/1.1 400 \r\nConnection: Close\r\nError: {s}\r\nContent-Length: 0\r\n\r\n",
            .{@errorName(err)},
        ) catch buildError(400, "unknown"),
    };
    conn.writeFramed(response) catch {};
}

fn buildError(comptime status: u16, comptime err: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nError: {s}\r\nContent-Length: 0\r\n\r\n",
        .{ status, err },
    );
}

// ---------------------------------------------------------------------------
// Message loop — reads frames, dispatches to handler.
// ---------------------------------------------------------------------------

fn messageLoop(
    comptime H: type,
    handler: *H,
    conn: *Conn,
    reader: *ProtoReader,
    io_reader: *std.Io.Reader,
) !void {
    while (!conn.isClosed()) {
        reader.fillIo(io_reader) catch |err| switch (err) {
            error.Closed => return,
        };

        while (true) {
            const tup = reader.read() catch |err| {
                handleProtocolError(conn, err);
                return;
            } orelse break; // need more data

            const more = tup.@"0";
            const message = tup.@"1";
            const message_type = message.type;
            defer reader.done(message_type);

            try dispatchMessage(H, handler, conn, message);

            if (conn.isClosed()) return;
            if (!more) break;
        }
    }
}

fn handleProtocolError(conn: *Conn, err: anyerror) void {
    switch (err) {
        error.LargeControl,
        error.ReservedFlags,
        error.CompressionDisabled,
        error.CompressionError,
        error.UnfragmentedContinuation,
        error.NestedFragment,
        error.FragmentedControl,
        error.InvalidMessageType,
        => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
        else => {},
    }
    log.debug("({f}) invalid frame: {}", .{ conn.address, err });
}

fn dispatchMessage(comptime H: type, handler: *H, conn: *Conn, message: Message) !void {
    switch (message.type) {
        .text, .binary => try dispatchDataMessage(H, handler, message),
        .pong => if (comptime std.meta.hasFn(H, "clientPong")) {
            try handler.clientPong(message.data);
        },
        .ping => {
            const data = message.data;
            if (comptime std.meta.hasFn(H, "clientPing")) {
                try handler.clientPing(data);
            } else if (data.len == 0) {
                try conn.writeFramed(EMPTY_PONG);
            } else {
                try conn.writeFrame(.pong, data);
            }
        },
        .close => try handleClose(H, handler, conn, message.data),
    }
}

fn dispatchDataMessage(comptime H: type, handler: *H, message: Message) !void {
    const params = @typeInfo(@TypeOf(H.clientMessage)).@"fn".params;
    const needs_allocator = comptime needsAllocator(H);

    var arena: std.heap.ArenaAllocator = undefined;
    var aa: Allocator = undefined;
    if (comptime needs_allocator) {
        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        aa = arena.allocator();
    }
    defer if (comptime needs_allocator) arena.deinit();

    const tt: Message.TextType = if (message.type == .text) .text else .binary;

    switch (comptime params.len) {
        2 => try handler.clientMessage(message.data),
        3 => if (needs_allocator) {
            try handler.clientMessage(aa, message.data);
        } else {
            try handler.clientMessage(message.data, tt);
        },
        4 => try handler.clientMessage(aa, message.data, tt),
        else => @compileError(@typeName(H) ++ ".clientMessage has invalid parameter count"),
    }
}

fn handleClose(comptime H: type, handler: *H, conn: *Conn, data: []const u8) !void {
    if (comptime std.meta.hasFn(H, "clientClose")) {
        try handler.clientClose(data);
        return;
    }

    const l = data.len;
    if (l == 0) {
        try conn.close(.{});
        return;
    }
    if (l == 1) {
        try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
        return;
    }

    const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
    if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
        try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
        return;
    }

    if (l == 2) {
        try conn.writeFramed(CLOSE_NORMAL);
        return;
    }

    const payload = data[2..];
    if (!std.unicode.utf8ValidateSlice(payload)) {
        try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
    } else {
        try conn.close(.{});
    }
}

fn needsAllocator(comptime H: type) bool {
    const params = @typeInfo(@TypeOf(H.clientMessage)).@"fn".params;
    return comptime params[1].type == Allocator;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn nowSeconds(io: Io) u32 {
    const now = Io.Clock.Timestamp.now(io, .realtime) catch return 0;
    return @intCast(@divTrunc(now.raw, std.time.ns_per_s));
}
