# Io-Async Redesign — Living Progress Log

This is the pick-up-where-we-left-off doc. It's updated as we finish each
task. For *plan and decisions*, see `starting_redesign_now.md`. For the
original parked exploration, see `io_async_redesign_todo.md`.

Conventions:
- Entries are in reverse chronological order (newest first).
- Each entry: status, commit, what changed, what's still true, what to
  watch next.
- When something we thought was true turns out wrong, leave the old note
  *and* strike it through with a correction — history is useful.

---

## Task #3 — Rewrite server.zig around Io.async (IN PROGRESS)

**Step 1: map the current server.zig** — pending.

Plan of attack for this task (4 steps):
1. Read the full current `server.zig` (1700+ lines); summarize accept
   loop, Conn, handshake wiring, dispatch, shutdown.
2. Sketch the new structure in a short design note (inlined here).
3. Implement the new path alongside the old; only delete the old once
   the new one passes a smoke test.
4. Port server-side tests one by one.

---

## Task #2 — proto.zig Reader → Io.Reader input ✅

**Commit:** `373c0ad proto: add Reader.fillIo(*std.Io.Reader), port Reader tests to Io input`

What changed:
- New `Reader.fillIo(*std.Io.Reader) !void` drains via `readSliceShort`
  into the existing static/large buffer. Frame state machine is
  unchanged — the large-buffer exact-size contract is preserved.
- Legacy `Reader.fill(stream: anytype)` kept in place, used by
  `server.zig` / `client.zig` until task #3 rewrites them.
- Proto Reader tests (5 of them, including the 250-iteration fuzz) no
  longer go through a socket pair — they feed `std.Io.Reader.fixed`
  over bytes accumulated in `t.Writer`. Randomization that matters
  (message counts, fragment counts, buffer sizes, pool variants) is
  preserved; kernel round-trip for unit tests is removed.

Still true:
- `SocketPair` in `t.zig` is still used by `client.zig` tests and the
  `testing.zig` handler harness. Those exercise the real socket path
  and stay as-is until the server rewrite swaps them.
- 33/33 tests green in both blocking and non-blocking modes on Windows.

Watch next:
- `fillIo` flattens `error.ReadFailed` → `error.Closed`. The detailed
  diagnostic lives on the stream's Reader wrapper (`net.Stream.Reader.err`).
  If any caller in task #3 needs the detailed error, reach for it there.

---

## Task #1 — Windows std.Io viability spike ✅

**Commit:** `c6c48eb Spike: Windows std.Io TCP echo works (day-0 viability ✅)`

What changed:
- New `spike/io_echo/` throwaway binary. `Io.Threaded` +
  `Io.async` + `net.IpAddress.listen` + `Server.accept` +
  `Stream.reader/writer` round-trip 16 bytes cleanly on Windows 11.
  IOCP is entirely inside the stdlib vtable — no direct Win32 in our
  code.

Key Zig 0.16 facts (captured for the rest of the migration):
- `Io.Threaded` is the only Windows backend in 0.16. No fibers on
  Windows. Our "green frames" on Windows are Threaded-scheduled frames.
- TCP: `net.IpAddress.listen(&addr, io, opts)` → `Server`;
  `server.accept(io)` → `Stream`; `stream.reader(io, buf)` and
  `stream.writer(io, buf)` produce buffered `Io.Reader`/`Io.Writer`
  wrappers.
- `Io.async(io, fn, args)` is a plain function call (no keyword), returns
  `Future(Result)`; `.await(io)` waits, `.cancel(io)` requests
  cancellation.
- `Stream.Writer` is buffered. `writeAll` then explicit `flush` is
  mandatory — the drain only fires on flush or buffer pressure.
- 0.16 allocator rename: `GeneralPurposeAllocator` → `DebugAllocator`,
  init is `: .init` not `: .{}`.
- `std.Io.Reader.fixed(bytes)` wraps a byte slice as a Reader — useful
  for tests.

Still true: all of the above, as of 2026-04-17.

Watch next:
- There may be differences between Io.Threaded and the fiber backends
  (Linux Uring / macOS Dispatch) we don't see from Windows-only
  testing. When we add non-Windows CI, validate the same surface
  compiles and passes there.

---

## Branch setup (2026-04-17) ✅

**Commit:** `13ff0ee Kick off Io async redesign branch`

- New branch `io-async-spike` cut from `migrate-to-zig-0.16`
  (v0.2.2 shipped, stable).
- `starting_redesign_now.md` captures scope, decisions, 2-week plan,
  and success criteria.
- Out of scope for this branch: permessage-deflate (#4), TLS (#5),
  compat shim for old handler API.
- Trigger: our own curiosity + forward-leaning on 0.16 idioms. No
  downstream consumers blocking us.
