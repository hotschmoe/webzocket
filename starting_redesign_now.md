# Starting the Io Async Redesign — Now

Companion to `io_async_redesign_todo.md`. That file was the parked-idea doc;
this one is the "we're actually doing it" doc. Scope, decisions, and the plan
for this branch (`io-async-spike`).

## Why now

Not driven by a downstream consumer or a stable 0.17. Driven by *us* wanting
to:

1. **Validate Zig 0.16 idioms.** Use `std.Io` the way the language now wants
   libraries to use it. Today's hybrid (comptime `blockingMode()` + raw
   epoll/kqueue + Thread.spawn) is 0.15-era thinking mechanically ported
   forward. We want the 0.16-native shape.
2. **Improve performance** — or at least measure honestly whether Io-native
   beats the current hybrid. Green frames per connection instead of a fixed
   ThreadPool should be cheaper at high connection counts; we want data, not
   speculation.
3. **Learn.** This is a dev branch. No downstream consumers are blocked on us.
   v0.2.2 is tagged and stable for anyone who needs today's shape.

Because there's no external pressure, we can be aggressive: break the public
API, delete the blocking-mode branch entirely, and rebuild around `Io` as the
only substrate.

## Development reality: Windows-primary

Dev environment is Windows 11. That changes the spike order from the parked
doc's "Linux first" recommendation:

- **Windows (IOCP-backed `std.Io`) is platform #1.** It's where we run the
  inner loop, and it's also the riskiest unknown — if `std.Io` on Windows
  isn't usable for a TCP listener + accept at the scale we need, the whole
  "unified surface" pitch collapses. Better to find that out in day one than
  week four.
- Linux and macOS fall in line after Windows works. They're easier backends
  for `std.Io`; if the API shape works on Windows it'll work there.

## Decisions on the open questions

### 1. CPU offload for handlers — keep a ThreadPool, exposed explicitly

Green threads on a single-threaded Io loop don't give real parallelism for
CPU-bound work (JSON parsing, business logic). Rather than push that problem
onto handler authors with a "keep it cheap" disclaimer, we keep a retained
thread pool and expose it via a handler-facing helper:

```zig
try conn.offload(work_fn, args);
```

The ThreadPool moves from being the *default* dispatch target (as today) to
being an *opt-in* escape hatch for CPU-heavy handlers. Small/cheap handlers
run inline on the green frame and never touch an OS thread.

Rationale: preserves the current parallelism story for heavy handlers without
forcing every handler into thread-pool semantics. Keeps the stdlib Io
primitives at the core of the architecture.

### 2. Handler API — `conn` carries `Io`

`clientMessage(conn, msg)` becomes the canonical shape. `Io` is reachable off
`conn` for handlers that need outbound I/O or want to spawn sub-tasks. Other
overloads (text-vs-binary, allocator) remain; they just all take `conn` as
the Io-bearing parameter.

This is a major version bump. Fine — no one is on trunk.

### 3. Cancellation — `Cancelable` token per connection

Each connection's serve-frame holds a `Cancelable`. Shutdown and per-conn
close signal it; handlers that honor cooperative cancellation exit cleanly;
handlers that ignore it get force-closed after a grace window (proposal:
500ms, tunable via `Config`).

Deletes `shutdown(.recv)` + poll-flag emulation.

### 4. Blocking mode — deleted

No `-Dforce_blocking`. No `fn Blocking(...)` / `fn NonBlocking(...)` split.
One Io-driven path per platform. If `std.Io` on a platform can't carry us,
that platform is unsupported on this branch (to be re-added later, not
papered over with a fallback).

### 5. Bundle #4 (compression) and #5 (TLS)? — Not yet

Tempting, but it triples the scope of the spike. Do the core Io port first
(handshake + framing + echo, 301/301 Autobahn cases, CPU offload wired up),
ship that as a 0.3-series prerelease, *then* do #4 and #5 on top. Both
benefit from `Io.Reader`/`Writer` being the substrate; neither is a hard
blocker for the core port.

## Scope of this branch

**In:**
- Delete `src/server/thread_pool.zig`'s current role; repurpose (or rewrite)
  as the offload pool behind `conn.offload`.
- Delete `src/server/posix_compat.zig`.
- Delete the comptime `blockingMode()` branching from `src/server/server.zig`.
- Rewrite server accept/serve loop as `Io.async`-dispatched per-connection
  green frames.
- Port `proto.zig`'s `Reader` / `Fragmented` to consume `Io.Reader` instead of
  raw buffer slices. *Keep the state machine.*
- Port handshake parsing to `Io.Reader` input.
- New handler contract: `clientMessage(conn, msg)` with `Io` on `conn`.
- `conn.offload(work, args)` for CPU-heavy handlers.
- `Cancelable` per connection; graceful cancel with forced close after grace.
- Autobahn suite at ≥301/301 on Linux (CI floor) and ideally on Windows too.

**Out (explicitly, for this branch):**
- permessage-deflate (#4).
- TLS client port (#5).
- Compatibility shim for the old handler API.
- Any attempt to keep the `-Dforce_blocking` branch.

## Plan

1. **Windows Io viability check (day 0–2). — DONE ✅**
   See `spike/io_echo/`. Single binary: `Io.Threaded` backend, listen on
   127.0.0.1:9223, spawn accept half via `Io.async`, client half runs on
   main, 16-byte echo round-trips cleanly. Key findings:
   - `Io.Threaded` is the only Windows backend in 0.16. No fibers on Windows
     — "green frames" on this platform are really Threaded-scheduled frames.
     That's fine for us; the vtable surface is identical.
   - TCP API shape: `net.IpAddress.listen(&addr, io, opts)` → `Server`;
     `server.accept(io)` → `Stream`; `stream.reader(io, buf)` and
     `stream.writer(io, buf)` produce buffered `Io.Reader`/`Io.Writer`
     wrappers. IOCP is hidden inside `Io.Threaded`'s vtable — we never
     touch Win32 directly.
   - `Io.async(io, fn, args)` is a plain function call (no `async`/`await`
     keywords in 0.16). Returns `Future(Result)`; `.await(io)` to wait,
     `.cancel(io)` to request cancellation.
   - `Stream.Writer` is buffered. `writeAll` then `flush` is mandatory —
     the drain only fires on flush or buffer pressure.
   - 0.16 allocator API note: `GeneralPurposeAllocator` → `DebugAllocator`,
     init pattern is `: .init` not `: .{}`.
   **Conclusion:** the "one Io-driven path per platform" bet holds on
   Windows. Proceed to the library rewrite.

2. **Port `Reader` to `Io.Reader` input (day 2–4).** Most invasive internal
   change, orthogonal to the handler API break. Do it with the current
   server scaffolding still in place; verify with existing unit tests before
   touching `server.zig`.
3. **Rewrite `server.zig` around `Io.async` per-connection (day 4–7).** New
   handler contract. Delete blocking-mode. Delete `posix_compat.zig`. Delete
   the old thread_pool role.
4. **Wire `conn.offload` (day 7–8).** Retained thread pool, hidden behind
   the conn-level API.
5. **Cancellation (day 8–9).** `Cancelable` per connection. Shutdown path
   signals; grace window forces close.
6. **Autobahn green on Windows first, then Linux (day 9–14).** 301/301 is
   the floor. Anything less is a regression.
7. **Benchmark vs v0.2.2 (day 14+).** Connection count scaling, message
   throughput. Confirm the redesign earned its keep.

Timeboxed to roughly two weeks of focused work. If at any point the Io
substrate on Windows proves a dead end, we bail back to `migrate-to-zig-0.16`
and write up the findings.

## Success criteria

- Autobahn 301/301 on Windows and Linux.
- No `blockingMode()` branching anywhere in `src/`.
- No direct epoll/kqueue/IOCP calls in `src/`; everything through `std.Io`.
- `conn.offload` demonstrably parallelizes a CPU-heavy handler.
- Cancellation: closing a server mid-handler force-closes within the grace
  window, no hang.
- Benchmarks: at minimum no regression vs v0.2.2 at moderate connection
  counts; ideally a win at high connection counts.

## Open risks (to watch, not to pre-solve)

- `std.Io` on Windows might not expose a competitive listener/accept in
  0.16. If so, step 1 of the plan catches it.
- `std.Io` multi-threaded green scheduler may not exist in 0.16 std — we
  may be stuck with threaded Io backend for real parallelism, which makes
  the ThreadPool deletion partial. That's fine; it just means "green frames"
  is really "Io-scheduled frames on a threaded backend" and we measure
  accordingly.
- Autobahn timing-sensitive cases (close-handshake timeouts, fragmented
  ping interleaving) are where framing rewrites usually regress. Budget
  extra time for those.
