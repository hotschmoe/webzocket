//! Io-native WebSocket server.
//!
//! Architecture:
//!   - One accept loop per `Server(H)`, spawned via `Io.async`. Each
//!     accepted stream gets its own serve frame via `Io.Group.async`.
//!   - `std.Io.net` handles readiness. No direct epoll/kqueue/IOCP, no
//!     comptime `blockingMode()` branching.
//!   - Per-connection state is the serve frame's stack — no
//!     `ConnManager` / pending list / handshake-state pool-of-pools.
//!
//! Handler contract (`H`):
//!   - `init(*const Handshake, *Conn, ctx)` — construct handler. The
//!     `Ctx` type is derived from this third parameter; it must be
//!     concrete (not anytype), because `Io.async` needs `ArgsTuple`.
//!   - `clientMessage(...)` — 4 overloads (data only, + TextType,
//!     + Allocator, + both). Always takes `*H` first.
//!   - Optional: `afterInit`, `close`, `clientClose`, `clientPing`,
//!     `clientPong`.

const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

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

comptime {
    // thread_pool.zig is unused by the new server directly, but lands as
    // the backing store for `conn.offload` in task #4. Keep its tests in
    // scope in the meantime (Zig only walks direct declarations for
    // `refAllDecls`, not recursively into non-imported modules).
    _ = @import("thread_pool.zig");
}

const DEFAULT_BUFFER_SIZE = 2048;
const DEFAULT_MAX_MESSAGE_SIZE = 65_536;

pub const Config = struct {
    port: u16 = 9882,
    address: []const u8 = "127.0.0.1",
    unix_path: ?[]const u8 = null,

    // `worker_count` is accepted for API compatibility but unused in the
    // Io-native server — parallelism is per-connection-frame via
    // Io.Group.async, not via a fixed worker-thread pool.
    worker_count: ?u8 = null,

    max_conn: ?usize = null,
    max_message_size: ?usize = null,

    handshake: Config.Handshake = .{},
    thread_pool: ThreadPool = .{},
    buffers: Config.Buffers = .{},
    compression: ?Compression = null,

    pub const ThreadPool = struct {
        count: ?u16 = null,
        backlog: ?u32 = null,
        buffer_size: ?usize = null,
    };

    pub const Handshake = struct {
        timeout: u32 = 10,
        max_size: ?u16 = null,
        max_headers: ?u16 = null,
        max_res_headers: ?u16 = null,
        count: ?u16 = null,
    };

    pub const Buffers = struct {
        small_size: ?usize = null,
        small_pool: ?usize = null,
        large_size: ?usize = null,
        large_pool: ?u16 = null,
    };
};

// Shared server-wide state. Lived on the old `Server(H)` via a single
// `WorkerState`; preserved here because the handshake pool + buffer
// provider are still useful across every connection frame.
pub const WorkerState = struct {
    io: Io,
    config: Config,
    handshake_pool: *Handshake.Pool,
    buffer_provider: buffer.Provider,

    pub fn init(allocator: Allocator, io: Io, config: Config) !WorkerState {
        const handshake_pool_count = config.handshake.count orelse 32;
        const handshake_max_size = config.handshake.max_size orelse 1024;
        const handshake_max_headers = config.handshake.max_headers orelse 10;
        const handshake_max_res_headers = config.handshake.max_res_headers orelse 2;

        var handshake_pool = try Handshake.Pool.init(allocator, io, handshake_pool_count, handshake_max_size, handshake_max_headers, handshake_max_res_headers);
        errdefer handshake_pool.deinit();

        const max_message_size = config.max_message_size orelse DEFAULT_MAX_MESSAGE_SIZE;
        const large_buffer_pool = config.buffers.large_pool orelse 8;
        const large_buffer_size = config.buffers.large_size orelse @min((config.buffers.small_size orelse DEFAULT_BUFFER_SIZE) * 2, max_message_size);

        var buffer_provider = try buffer.Provider.init(allocator, io, .{
            .max = max_message_size,
            .size = large_buffer_size,
            .count = large_buffer_pool,
        });
        errdefer buffer_provider.deinit();

        return .{
            .io = io,
            .config = config,
            .handshake_pool = handshake_pool,
            .buffer_provider = buffer_provider,
        };
    }

    pub fn deinit(self: *WorkerState) void {
        self.handshake_pool.deinit();
        self.buffer_provider.deinit();
    }
};

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

// Extract the `Ctx` type from `H.init(*const Handshake, *Conn, ctx: Ctx) !H`.
// Doing this avoids `anytype` parameters in internal dispatch functions —
// anytype trips `std.meta.ArgsTuple` which `Io.async` / `Group.async`
// need. The ctx type is therefore a property of H, fixed at the type level.
fn CtxType(comptime H: type) type {
    const params = @typeInfo(@TypeOf(H.init)).@"fn".params;
    if (params.len < 3) @compileError(@typeName(H) ++ ".init must take (*const Handshake, *Conn, ctx)");
    return params[2].type orelse
        @compileError(@typeName(H) ++ ".init's ctx parameter must have a concrete type (not anytype)");
}

// Inline doubly-linked list node, one per active serveOne frame. Lives
// on the serve frame's stack — Server holds only head/tail pointers.
// Exists so `stop()` can forcibly shut down active streams and unblock
// their reads; per-frame Cancelable plumbing arrives in task #5.
pub const ActiveConn = struct {
    stream: *net.Stream,
    prev: ?*ActiveConn = null,
    next: ?*ActiveConn = null,
};

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

        _conns_lock: Io.Mutex = .init,
        _conns_head: ?*ActiveConn = null,

        pub const Ctx = CtxType(H);
        const Self = @This();

        fn registerConn(self: *Self, node: *ActiveConn) void {
            self._conns_lock.lockUncancelable(self.io);
            defer self._conns_lock.unlock(self.io);
            node.prev = null;
            node.next = self._conns_head;
            if (self._conns_head) |head| head.prev = node;
            self._conns_head = node;
        }

        fn unregisterConn(self: *Self, node: *ActiveConn) void {
            self._conns_lock.lockUncancelable(self.io);
            defer self._conns_lock.unlock(self.io);
            if (node.prev) |prev| prev.next = node.next else self._conns_head = node.next;
            if (node.next) |next| next.prev = node.prev;
            node.prev = null;
            node.next = null;
        }

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

        // Bind + listen synchronously. After this returns the OS has the
        // listening socket and clients can connect. Call `run()` afterwards
        // to start the accept loop. Keeping these split means the caller
        // can spawn `run` on an async frame and know the port is bound by
        // the time `bind()` returns — no racy retry-connect logic needed.
        pub fn bind(self: *Self) !void {
            const port = self.config.port;
            const host = self.config.address;
            var addr = try net.IpAddress.parse(host, port);

            const server = try addr.listen(self.io, .{
                .reuse_address = true,
                .mode = .stream,
                .protocol = .tcp,
            });

            self._listener_lock.lockUncancelable(self.io);
            defer self._listener_lock.unlock(self.io);
            self._listener = server;

            log.info("listening on {s}:{d}", .{ host, port });
        }

        // Blocks the current frame running the accept loop. Returns when
        // stop() has been called and all in-flight serve frames have
        // drained via the group. Return type is `anyerror!void`
        // explicitly so `Io.Future(anyerror!void)` types cleanly at call
        // sites (inferred error sets don't line up across TU boundaries).
        pub fn run(self: *Self, ctx: Ctx) anyerror!void {
            if (self._listener == null) return error.NotBound;

            while (true) {
                var stream = (&self._listener.?).accept(self.io) catch |err| switch (err) {
                    error.Canceled, error.SocketNotListening => break,
                    error.ConnectionAborted, error.BlockedByFirewall => {
                        log.debug("accept rejected: {}", .{err});
                        continue;
                    },
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                        log.warn("accept transient resource pressure: {}", .{err});
                        std.Io.sleep(self.io, Io.Duration.fromMilliseconds(10), .awake) catch return;
                        continue;
                    },
                    else => return err,
                };

                // stop() wakes accept by self-connecting. We close that
                // dummy stream and exit here — no serveOne spawn.
                if (self._shutdown.load(.acquire)) {
                    stream.close(self.io);
                    break;
                }

                self._group.async(self.io, serveOne, .{ self, stream, ctx });
            }

            // Drain in-flight frames. Each frame exits when its client
            // closes or its stream is shut down (task #5 — proper
            // per-connection Cancelable).
            self._group.await(self.io) catch {};

            self._listener_lock.lockUncancelable(self.io);
            defer self._listener_lock.unlock(self.io);
            if (self._listener) |*listener| {
                listener.deinit(self.io);
                self._listener = null;
            }
        }

        // Convenience for callers that don't need the bind/run split.
        pub fn listen(self: *Self, ctx: Ctx) !void {
            try self.bind();
            try self.run(ctx);
        }

        pub fn stop(self: *Self) void {
            self._shutdown.store(true, .release);

            // Unblock run()'s accept loop by self-connecting. Closing the
            // listener directly panics on Windows (netAccept asserts
            // unreachable on CANCELLED).
            var addr = net.IpAddress.parse(self.config.address, self.config.port) catch return;
            var dummy = addr.connect(self.io, .{ .mode = .stream }) catch return;
            dummy.close(self.io);

            // NOTE: in-flight serveOne frames rely on their client
            // closing the socket to return EOF and unwind. Forced
            // server-initiated teardown of active connections belongs
            // to task #5 — on Windows the AFD_RECEIVE backend asserts
            // `CANCELLED => unreachable`, so we can't just shutdown or
            // closesocket the peer mid-recv without more plumbing.
            // `_conns_head` + `ActiveConn` are wired up for that work.
        }

        fn serveOne(
            self: *Self,
            stream_in: net.Stream,
            ctx: Ctx,
        ) Io.Cancelable!void {
            var stream = stream_in;
            defer stream.close(self.io);

            var active_node: ActiveConn = .{ .stream = &stream };
            self.registerConn(&active_node);
            defer self.unregisterConn(&active_node);

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

            const hs_state = self._state.handshake_pool.acquire() catch |err| {
                log.warn("handshake pool exhausted: {}", .{err});
                return;
            };
            defer hs_state.release();

            const parsed = readHandshake(&conn, &io_reader.interface, hs_state) catch |err| {
                respondHandshakeError(&conn, err);
                return;
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

            messageLoop(H, &handler, &conn, &reader, &io_reader.interface) catch |err| {
                log.debug("message loop exited with error: {}", .{err});
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

fn readHandshake(conn: *Conn, io_reader: *std.Io.Reader, state: *Handshake.State) !Handshake {
    while (true) {
        // Drain whatever the io_reader already buffered; only fetch more
        // bytes via a single fillMore if it's empty. See the comment in
        // proto.Reader.fillIo for why readSliceShort is not usable here.
        var available = io_reader.buffer[io_reader.seek..io_reader.end];
        if (available.len == 0) {
            io_reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                error.ReadFailed => return error.ConnectionClosed,
            };
            available = io_reader.buffer[io_reader.seek..io_reader.end];
            if (available.len == 0) continue;
        }

        if (state.len + available.len > state.buf.len) {
            return error.RequestTooLarge;
        }
        @memcpy(state.buf[state.len .. state.len + available.len], available);
        state.len += available.len;
        io_reader.seek = io_reader.end;

        if (Handshake.parse(state) catch |err| {
            log.debug("({f}) handshake parse error: {}", .{ conn.address, err });
            return err;
        }) |hs| {
            return hs;
        }
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

// Placeholder for the legacy `Conn.started` field. Io 0.16 timestamps
// aren't trivially coercible to a u32 epoch second; since nothing in the
// new server reads this yet (handshake timeouts will be reintroduced via
// `Io.Timeout` in task #5), return 0. Legacy consumers of Conn.started
// get a stable value during the transition.
fn nowSeconds(io: Io) u32 {
    _ = io;
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// Test infrastructure:
//   - `test_threaded` is a Threaded Io the tests own; used by the shared
//     test_server so Io.async can dispatch serveOne frames.
//   - test_server listens on port 9292 with TestHandler — same port the
//     old server's tests used, so client.zig tests connect to it.
//   - Client-side test helpers (`testServerStream`) connect through
//     `std.testing.io` (single-threaded): they don't need async, just
//     the netConnect vtable call.

const t = @import("../t.zig");

var test_threaded: std.Io.Threaded = undefined;
var test_threaded_alloc = std.heap.DebugAllocator(.{}).init;
var test_server: Server(TestHandler) = undefined;
var test_run_future: Io.Future(anyerror!void) = undefined;

const SmokeEcho = struct {
    conn: *Conn,

    pub fn init(_: *const Handshake, conn: *Conn, _: void) !SmokeEcho {
        return .{ .conn = conn };
    }

    pub fn clientMessage(self: *SmokeEcho, data: []const u8) !void {
        try self.conn.write(data);
    }
};

test "server_io: handshake + echo" {
    const gpa = std.testing.allocator;

    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try Server(SmokeEcho).init(gpa, io, .{
        .port = 19923,
        .address = "127.0.0.1",
    });
    defer server.deinit();

    try server.bind();
    var run_future = Io.async(io, Server(SmokeEcho).run, .{ &server, {} });

    var addr = try net.IpAddress.parse("127.0.0.1", 19923);
    var client = try addr.connect(io, .{ .mode = .stream });
    var client_closed = false;
    defer if (!client_closed) client.close(io);

    var client_read_buf: [1024]u8 = undefined;
    var client_write_buf: [1024]u8 = undefined;
    var client_reader = client.reader(io, &client_read_buf);
    var client_writer = client.writer(io, &client_write_buf);

    try client_writer.interface.writeAll(
        "GET / HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: my-key\r\n\r\n",
    );
    try client_writer.interface.flush();

    // Read reply until "\r\n\r\n".
    var resp_buf: [1024]u8 = undefined;
    var resp_pos: usize = 0;
    while (resp_pos < resp_buf.len) {
        const n = try client_reader.interface.readSliceShort(resp_buf[resp_pos .. resp_pos + 1]);
        if (n == 0) return error.HandshakeClosed;
        resp_pos += n;
        if (resp_pos >= 4 and std.mem.eql(u8, resp_buf[resp_pos - 4 .. resp_pos], "\r\n\r\n")) break;
    }
    try t.expectString(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: L8KGBs4w2MNLLzhfzlVoM0scCIE=\r\n\r\n",
        resp_buf[0..resp_pos],
    );

    // Send a masked text frame with payload "hello".
    var w = t.Writer.init();
    defer w.deinit();
    w.textFrame(true, "hello");
    try client_writer.interface.writeAll(w.bytes());
    try client_writer.interface.flush();

    // Server echoes back. Expect 7 bytes: FIN+text (0x81), len=5, "hello".
    var frame_buf: [7]u8 = undefined;
    try client_reader.interface.readSliceAll(&frame_buf);
    try t.expectEqual(@as(u8, 0x81), frame_buf[0]);
    try t.expectEqual(@as(u8, 0x05), frame_buf[1]);
    try t.expectString("hello", frame_buf[2..7]);

    // Close the client first so the server's serveOne read sees EOF and
    // unwinds through its defers. Then stop the listener via self-connect.
    client.close(io);
    client_closed = true;

    server.stop();
    run_future.await(io) catch {};
}

// ---------------------------------------------------------------------------
// Shared test server (port 9292) — drives the end-to-end tests below plus
// all the Client:* tests in client.zig.
// ---------------------------------------------------------------------------

test "tests:beforeAll" {
    test_threaded = std.Io.Threaded.init(test_threaded_alloc.allocator(), .{});
    const io = test_threaded.io();

    test_server = try Server(TestHandler).init(test_threaded_alloc.allocator(), io, .{
        .port = 9292,
        .address = "127.0.0.1",
    });
    try test_server.bind();
    test_run_future = Io.async(io, Server(TestHandler).run, .{ &test_server, {} });
}

test "tests:afterAll" {
    test_server.stop();
    test_run_future.await(test_threaded.io()) catch {};
    test_server.deinit();
    test_threaded.deinit();
    _ = test_threaded_alloc.deinit();
}

test "Server: invalid handshake" {
    var stream = try testServerStream(false);
    defer stream.close(std.testing.io);

    var io_writer_buf: [256]u8 = undefined;
    var io_reader_buf: [1024]u8 = undefined;
    var sw = stream.writer(std.testing.io, &io_writer_buf);
    var sr = stream.reader(std.testing.io, &io_reader_buf);

    try sw.interface.writeAll("GET / HTTP/1.1\r\n\r\n");
    try sw.interface.flush();

    var buf: [1024]u8 = undefined;
    const n = try sr.interface.readSliceShort(&buf);
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nError: missingheaders\r\nContent-Length: 0\r\n\r\n", buf[0..n]);
}

test "Server: read and write" {
    var stream = try testServerStream(true);
    defer stream.close(std.testing.io);

    var io_writer_buf: [64]u8 = undefined;
    var io_reader_buf: [64]u8 = undefined;
    var sw = stream.writer(std.testing.io, &io_writer_buf);
    var sr = stream.reader(std.testing.io, &io_reader_buf);

    try sw.interface.writeAll(&proto.frame(.text, "over"));
    try sw.interface.flush();

    var buf: [6]u8 = undefined;
    try sr.interface.readSliceAll(&buf);
    try t.expectSlice(u8, &.{ 129, 4, '9', '0', '0', '0' }, &buf);
}

test "Server: clientMessage allocator" {
    var stream = try testServerStream(true);
    defer stream.close(std.testing.io);

    var io_writer_buf: [64]u8 = undefined;
    var io_reader_buf: [64]u8 = undefined;
    var sw = stream.writer(std.testing.io, &io_writer_buf);
    var sr = stream.reader(std.testing.io, &io_reader_buf);

    try sw.interface.writeAll(&proto.frame(.text, "dyn"));
    try sw.interface.flush();

    var buf: [12]u8 = undefined;
    try sr.interface.readSliceAll(&buf);
    try t.expectSlice(u8, &.{ 129, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!' }, &buf);
}

test "Server: clientMessage writer" {
    var stream = try testServerStream(true);
    defer stream.close(std.testing.io);

    var io_writer_buf: [64]u8 = undefined;
    var io_reader_buf: [64]u8 = undefined;
    var sw = stream.writer(std.testing.io, &io_writer_buf);
    var sr = stream.reader(std.testing.io, &io_reader_buf);

    try sw.interface.writeAll(&proto.frame(.text, "writer"));
    try sw.interface.flush();

    var buf: [9]u8 = undefined;
    try sr.interface.readSliceAll(&buf);
    try t.expectSlice(u8, &.{ 129, 7, '9', '0', '0', '0', '!', '!', '!' }, &buf);
}

test "Server: dirty clientMessage allocator" {
    // In the old server this test deliberately left the client stream
    // open to exercise afterAll's forced teardown of active connections.
    // The new server will regain that behavior via per-conn Cancelable
    // in task #5; until then we close the client to let afterAll
    // quiesce cleanly on Windows AFD (where shutdown/close mid-recv
    // would trip netReadWindows's `CANCELLED => unreachable`).
    var stream = try testServerStream(true);
    defer stream.close(std.testing.io);

    var io_writer_buf: [64]u8 = undefined;
    var io_reader_buf: [64]u8 = undefined;
    var sw = stream.writer(std.testing.io, &io_writer_buf);
    var sr = stream.reader(std.testing.io, &io_reader_buf);

    try sw.interface.writeAll(&proto.frame(.text, "dyn"));
    try sw.interface.flush();

    var buf: [12]u8 = undefined;
    try sr.interface.readSliceAll(&buf);
    try t.expectSlice(u8, &.{ 129, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!' }, &buf);
}

test "Conn: close" {
    // plain close
    {
        var stream = try testServerStream(true);
        defer stream.close(std.testing.io);
        var io_writer_buf: [64]u8 = undefined;
        var io_reader_buf: [64]u8 = undefined;
        var sw = stream.writer(std.testing.io, &io_writer_buf);
        var sr = stream.reader(std.testing.io, &io_reader_buf);

        try sw.interface.writeAll(&proto.frame(.text, "close1"));
        try sw.interface.flush();

        var buf: [4]u8 = undefined;
        try sr.interface.readSliceAll(&buf);
        try t.expectSlice(u8, &.{ 136, 2, 3, 232 }, &buf);
    }
    // close with code
    {
        var stream = try testServerStream(true);
        defer stream.close(std.testing.io);
        var io_writer_buf: [64]u8 = undefined;
        var io_reader_buf: [64]u8 = undefined;
        var sw = stream.writer(std.testing.io, &io_writer_buf);
        var sr = stream.reader(std.testing.io, &io_reader_buf);

        try sw.interface.writeAll(&proto.frame(.text, "close2"));
        try sw.interface.flush();

        var buf: [4]u8 = undefined;
        try sr.interface.readSliceAll(&buf);
        try t.expectSlice(u8, &.{ 136, 2, 0, 0x7b }, &buf);
    }
    // close with reason
    {
        var stream = try testServerStream(true);
        defer stream.close(std.testing.io);
        var io_writer_buf: [64]u8 = undefined;
        var io_reader_buf: [64]u8 = undefined;
        var sw = stream.writer(std.testing.io, &io_writer_buf);
        var sr = stream.reader(std.testing.io, &io_reader_buf);

        try sw.interface.writeAll(&proto.frame(.text, "close3"));
        try sw.interface.flush();

        var buf: [7]u8 = undefined;
        try sr.interface.readSliceAll(&buf);
        try t.expectSlice(u8, &.{ 136, 5, 0, 0xea, 'b', 'y', 'e' }, &buf);
    }
}

// Connect a client to the shared test_server. If `upgrade` is true, drives
// the HTTP upgrade and validates the 101 reply before returning.
fn testServerStream(upgrade: bool) !net.Stream {
    const io = std.testing.io;
    var addr = try net.IpAddress.parse("127.0.0.1", 9292);
    var stream = try addr.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);

    if (!upgrade) return stream;

    var write_buf: [512]u8 = undefined;
    var read_buf: [512]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    var sr = stream.reader(io, &read_buf);

    try sw.interface.writeAll("GET / HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: my-key\r\n\r\n");
    try sw.interface.flush();

    // Consume reply up to "\r\n\r\n".
    var resp: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < resp.len) {
        const n = try sr.interface.readSliceShort(resp[pos .. pos + 1]);
        if (n == 0) return error.EndOfStream;
        pos += n;
        if (pos >= 4 and std.mem.eql(u8, resp[pos - 4 .. pos], "\r\n\r\n")) break;
    }
    try t.expectString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: L8KGBs4w2MNLLzhfzlVoM0scCIE=\r\n\r\n", resp[0..pos]);

    return stream;
}

const TestHandler = struct {
    conn: *Conn,

    pub fn init(h: *const Handshake, conn: *Conn, _: void) !TestHandler {
        try t.expectString("upgrade", h.headers.get("connection").?);
        return .{ .conn = conn };
    }

    pub fn clientMessage(self: *TestHandler, allocator: Allocator, data: []const u8) !void {
        if (std.mem.eql(u8, data, "over")) return self.conn.writeText("9000");
        if (std.mem.eql(u8, data, "dyn")) {
            return self.conn.writeText(try std.fmt.allocPrint(allocator, "over {d}!", .{9000}));
        }
        if (std.mem.eql(u8, data, "writer")) {
            var wb = self.conn.writeBuffer(allocator, .text);
            try wb.interface.print("{d}!!!", .{9000});
            return wb.send();
        }
        if (std.mem.eql(u8, data, "ping")) {
            var buf = [_]u8{ 'a', '-', 'p', 'i', 'n', 'g' };
            return self.conn.writePing(&buf);
        }
        if (std.mem.eql(u8, data, "pong")) {
            var buf = [_]u8{ 'a', '-', 'p', 'o', 'n', 'g' };
            return self.conn.writePong(&buf);
        }
        if (std.mem.eql(u8, data, "close1")) return self.conn.close(.{});
        if (std.mem.eql(u8, data, "close2")) return self.conn.close(.{ .code = 123 });
        if (std.mem.eql(u8, data, "close3")) return self.conn.close(.{ .code = 234, .reason = "bye" });
    }
};
