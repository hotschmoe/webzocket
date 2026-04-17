# Io-Async Redesign TODO

A parked design exploration: replace the OS-thread `ThreadPool` + epoll/kqueue
hybrid with a redesign built around Zig 0.16's `std.Io` async primitives. Not
part of the current polish pass (#1/#2/#3/#6). Revisit alongside #4
(permessage-deflate compression) and #5 (TLS client port), since all three
touch the core I/O path.

## What we have today

- **Non-blocking server** (`src/server/server.zig`): epoll (Linux) or kqueue
  (BSD/macOS) accept + readiness loop. One I/O thread drives readiness events.
  When a socket has data, the loop parses whatever frames are complete and
  dispatches user message handling via a `ThreadPool` (`src/server/thread_pool.zig`).
- **Blocking server** (`src/server/server.zig`): one OS thread per connection.
  Used on Windows and any non-Unix target, or under `-Dforce_blocking=true`.
- **ThreadPool** (`src/server/thread_pool.zig`): fixed-size worker pool with
  per-worker scratch buffer. Work item = tuple of `(args..., buffer)` where the
  last argument is the per-worker buffer injected at dispatch. Uses
  `Io.Mutex` + `Io.Condition` — already 0.16-clean.
- **Handler contract** (`src/websocket.zig`): user provides a type `H` with
  `init`, `clientMessage` (4 overloads), and optional hooks (`afterInit`,
  `close`, `clientClose`, `clientPing`, `clientPong`). Thread-safety invariant:
  at most one `clientXxx` call per connection runs concurrently; the library
  serializes them.
- **Readers and buffers** (`src/proto.zig`, `src/buffer.zig`): per-connection
  `Reader` with static buffer; overflow goes to a pooled large-buffer provider
  sized exactly to the current message.

## Why consider a redesign

1. **Fewer OS threads.** Per-connection blocking mode scales poorly; even in
   non-blocking mode, the ThreadPool burns threads proportional to parallelism
   target, not connection count. `Io.async` green threads could give us
   per-connection cheap stacks without OS thread cost.
2. **Unified Io surface.** We'd stop branching at comptime on `blockingMode()`.
   Every platform would use the same path driven by `std.Io`. The
   `Thread.spawn` / `Thread.sleep` / native epoll/kqueue code would disappear
   (or at least move below an `Io` implementation).
3. **Cancellation.** 0.16's `Io` supports cooperative cancellation via the
   `Cancelable` token threaded through stdlib I/O. Today we emulate cancellation
   with `shutdown(.recv)` and flag polling — fine but ad-hoc.
4. **Per-connection state is simpler without thread pools.** The ThreadPool
   buffer injection exists because we have N workers sharing M connections. If
   each connection is its own green frame with its own stack-local buffer, the
   buffer-injection machinery goes away.
5. **Composition with downstream callers.** Users embedding `webzocket`
   alongside `httz` or other 0.16-native Io servers would share an `Io`
   instance instead of managing two concurrency substrates.

## Why not (yet)

1. **0.16 async maturity.** The `std.Io` surface landed in 0.16 but `Io.async`,
   green-thread implementations, and cancellation semantics are still being
   exercised across the ecosystem. Betting the library's architecture on APIs
   that may shift in 0.17/0.18 is risky immediately after completing a
   0.15 → 0.16 migration.
2. **Public API break.** `Handler.clientMessage` would likely need to become
   `Io`-aware — new parameter, new error set, possibly new return semantics.
   Every downstream consumer rewrites their handler. The package-smoke CI job
   validates the current surface; changing it is a versioning event.
3. **CPU parallelism.** For CPU-bound `clientMessage` work (JSON parsing,
   business logic), OS threads give real parallelism; green threads on a
   single-threaded event loop do not. Any redesign must still offer a way to
   offload CPU-heavy handlers — either keep a ThreadPool alongside the Io
   runtime or document that `clientMessage` must be cheap.
4. **Testing matrix grows.** Today CI matrix is {Linux, macOS, Windows} ×
   {Debug, ReleaseSafe, ReleaseFast, ReleaseSmall} × {blocking, non-blocking}.
   An `Io` redesign adds another axis: `Io` backend (threaded vs. green) or
   replaces the blocking/non-blocking axis entirely.
5. **Autobahn gate.** 301 cases currently pass. A rewrite risks regressing
   subtle framing/timeout behavior until all of Autobahn is green again. That's
   weeks of fuzz-driven debugging, not days.

## Sketch of the target shape

(Non-binding — this is the shape we'd iterate on, not a commitment.)

```zig
pub fn Server(comptime H: type) type {
    return struct {
        io: Io,
        listener: Io.net.TcpListener,
        ctx: Ctx,
        // no thread_pool, no Loop, no force_blocking branch

        pub fn run(self: *Self) !void {
            while (true) {
                const conn = try self.listener.accept(self.io);
                _ = try Io.async(self.io, serveOne, .{ self, conn });
            }
        }

        fn serveOne(self: *Self, raw: Io.net.Stream) !void {
            defer raw.close();
            var handshake_state = ...;
            const hs = try doHandshake(self.io, raw, &handshake_state);
            var handler = try H.init(&hs, &conn, self.ctx);
            defer if (hasClose(H)) handler.close();

            var reader = Reader.init(...);
            defer reader.deinit();

            while (true) {
                const frame = reader.readFrame(self.io, raw) catch |err| switch (err) {
                    error.Canceled, error.Closed => break,
                    else => return err,
                };
                try dispatch(H, &handler, &conn, frame);
            }
        }
    };
}
```

What disappears:
- `src/server/thread_pool.zig` (or repurposed as an optional CPU-offload
  helper).
- The comptime `blockingMode()` branch and all of `fn Blocking(...)` vs.
  `fn NonBlocking(...)`.
- `src/server/posix_compat.zig` (the raw-syscall shim) — `Io.net` becomes
  the abstraction.
- Manual `shutdown(.recv)` + poll-flag cancellation.

What stays:
- `Reader` state machine, `Fragmented`, buffer provider (with tweaks to take
  `Io` readers instead of `read(fd, ...)`).
- Handshake parsing (but wired to Io reads).
- Handler contract structure, though `clientMessage` signatures likely gain
  an `Io` parameter or become `!void` with Io threaded via conn.

## Rollout approach (if/when we do this)

1. **Spike on a throwaway branch.** Rebuild the non-blocking path as pure `Io`
   on a single platform (Linux first). No blocking mode, no compat shim. Prove
   the handshake + echo test works end-to-end against Autobahn case 1.1.1.
2. **Port Reader / Fragmented** to consume an `Io.Reader` instead of a raw
   buffer slice. Keep the state machine, swap the input source. This is the
   single most invasive change; do it before touching handler API.
3. **Decide the handler API break.** Proposal: `clientMessage(conn, msg)`
   where `conn` carries `Io` — handler code that needs to do outbound I/O
   pulls `Io` off `conn`. Opt-in CPU-offload via an explicit
   `conn.offload(work)` helper that wraps a (retained) thread pool.
4. **Cancelation model.** Pick one. Likely: each connection's serve-frame
   holds a `Cancelable` that the shutdown path signals. Document the
   guarantee: handlers must return within N ms of cancel or their connection
   is force-closed.
5. **Run Autobahn on the spike.** 301 cases is the floor. Iterate until at
   least matching current pass count.
6. **Bring platforms back in order.** Linux → macOS (kqueue via Io backend)
   → Windows (IOCP via Io backend). If Io backend on Windows isn't ready, keep
   blocking-mode Windows as a temporary fallback, but tag it as a known-limitation.
7. **Keep package-consumer CI green the whole time.** The downstream
   import-and-build smoke test is the canary for the API break — freeze a
   compatibility shim if needed during migration, then drop it.
8. **Version bump.** This would be a major version — callers need to rewrite
   handlers.

## Open questions to resolve before committing

- Does `std.Io` on Windows (0.16 / 0.17) actually provide a usable listener
  + accept that's on par with blocking-per-conn for moderate connection counts?
- Is there a stable green-thread implementation in std, or do we need to
  bring our own scheduler? (As of 0.16 the built-in backends are Threaded and
  green-single-threaded; multi-green-thread runtime is community territory.)
- CPU offload for handlers: keep an optional ThreadPool, expose a generic
  `conn.offload(work)`, or document "handlers must be cheap"?
- TLS: #5 is already a redesign; doing it on top of the `Io`-first architecture
  would be simpler than doing it against the current hybrid. Argues for bundling
  TLS into this work rather than doing #5 standalone.
- Compression: same — #4 against `Io.Reader`/`Writer` is likely cleaner once
  the whole stack is Io-based. Argues for bundling #4 too.

## Suggested trigger for doing this

Any of:
- Downstream consumer requests integration with a 0.16 `Io`-native HTTP server
  and the dual-concurrency story becomes a pain point.
- Zig 0.17 ships a stable `Io.async` with a multi-threaded green scheduler.
- We decide to do #4 + #5 together — the Io redesign and those two items all
  benefit from being done as one coherent refactor.

Until one of those fires, the current ThreadPool + epoll/kqueue hybrid is the
right shape.
