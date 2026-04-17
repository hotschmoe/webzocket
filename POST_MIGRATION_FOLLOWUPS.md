# Post-Migration Follow-ups

Zig 0.15.2 → 0.16.0 migration landed with 301 Autobahn cases passing,
29/29 unit tests passing on Windows/Linux/macOS, and full CI
gate on PRs to `master`. This document tracks the **real protocol
bugs** that the migration PR worked around rather than fixed — each one
needs a proper fix before we can claim full feature parity with the
pre-0.15 library.

Authorship note: these are *not* regressions from the migration. Items 1–3
existed pre-migration too; the 0.15 Autobahn pipeline simply didn't
exercise them or they surfaced differently. Items 4–5 are scope we
deliberately deferred during migration.

Issues are ordered by **cost-to-fix × impact**.

---

## 1. Handshake parser 400s on unusual compression offers  *(P0, ~30 min)*

### Problem

Autobahn case 13.7.1 (and 17 peers in 13.7.*) consistently receive
`HTTP/1.1 400 Error: unknown` from our handshake. This happens even
though we don't claim to support compression — the client's offer
should simply be ignored, not rejected.

Evidence (from `support/autobahn/server/reports/non_blocking_bp_case_13_7_1.json`
in the CI artifact):

```json
{
  "behavior": "FAILED",
  "resultClose": "The WebSocket opening handshake was never completed!",
  "httpResponse": "HTTP/1.1 400\r\nConnection: Close\r\nError: unknown\r\nContent-Length: 0"
}
```

### Root cause

`Handshake.parseExtension` in `src/server/handshake.zig:170-214`. When
the client sends a compression offer with a bad `server_max_window_bits=`
value, we return `error.InvalidCompressionServerMaxBits`. That error
propagates up through `Handshake.parse` and causes the server to reply
400.

Two specific failure modes:

- **Multi-offer values**: Autobahn sends
  `permessage-deflate; server_max_window_bits=9, permessage-deflate; server_max_window_bits=0, permessage-deflate`.
  Our parser splits only on `;`, so the second offer's `server_max_window_bits=9, permessage-deflate`
  is fed to `parseInt` as a single token, which fails.
- Any non-integer value after `server_max_window_bits=` → parse error → 400.

The correct behavior per RFC 7692 §5.1: a server that does not accept
`permessage-deflate` MUST complete the handshake without including it in
the response. It SHOULD NOT reject the handshake.

### Fix

In `src/server/handshake.zig`:

1. Split the extension value by `,` first (multiple offers), then by `;`
   within each offer.
2. Change the `parseInt` catch prong from `return error.InvalidCompressionServerMaxBits`
   to `{ deflate = false; break; }`. Malformed offers are just skipped.
3. Also apply the graceful-fallback pattern to the outer caller at
   `src/server/handshake.zig:95` — if `parseExtension` returns any error,
   treat it as "no compression" and continue the handshake.

### Verification

Remove `"13.7.*"` from `support/autobahn/server/config.json`'s
`exclude-cases`. Run `make abs`. Expected: cases in 13.7 become
`UNIMPLEMENTED` (because server does not advertise compression), not
`FAILED`. No HTTP 400 responses in the artifact.

---

## 2. Memory leaks in `Fragmented.init` under fragment stress  *(P1, ~1–2 hr)*

### Problem

Running `autobahn-server` against a full suite run produced leak reports
from `DebugAllocator`, all pointing at `src/proto.zig:453`:

```
error(DebugAllocator): memory address 0x... leaked:
  std/array_list.zig:1235 in ensureTotalCapacityPrecise
  src/proto.zig:453 in init            ← Fragmented.init buffer
  src/proto.zig:347 in read            ← self.fragment = try Fragmented.init(...)
  src/server/server.zig:1668 in _handleClientData
```

At least 4 distinct addresses leaked in one run. These are
`Fragmented.buf` allocations that were never freed.

### Root cause analysis

`Reader.fragment` is allocated in `src/proto.zig:347` when we get a
non-final data frame. It is freed in two places:

- `Reader.deinit` at `src/proto.zig:112-118` — covers clean connection
  teardown.
- `Reader.done(message_type)` at `src/proto.zig:360-373` — covers
  the successful end-of-fragment-sequence case, but **only for `.text`
  and `.binary` types**.

The leak is almost certainly one of these paths:

- **Protocol-error drop**: the reader encounters an invalid frame
  mid-fragment (e.g., a control frame with bad flags). The server code at
  `src/server/server.zig:1668` catches the error, closes the connection,
  but the reader is reused-or-dropped in a way that skips `Reader.deinit`.
- **Connection closed before the final frame arrives**: if the peer
  closes TCP while we have an in-flight fragment, and the connection
  teardown path doesn't call `Reader.deinit`, the buffer leaks.

### Fix

1. Audit every exit path in `Reader.read` that can leave `self.fragment`
   populated while returning an error. Guarantee `self.fragment = null`
   and `fragment.deinit()` is called on error exits too, not just
   success.
2. In `src/server/server.zig:1668` (and any similar `reader.read() catch`
   site), after a protocol error, explicitly call `self.reader.done(.text)`
   or add a `self.reader.dropFragment()` helper that deinits without
   requiring a message type.
3. Verify `conn_manager.create` / `ConnManager.remove` in
   `src/server/server.zig` always reaches `reader.deinit()` via the
   connection's `deinit` path — even when the handshake never
   completed (less relevant here but worth checking).
4. Add a unit test in `src/proto.zig` that simulates: start a
   fragmented message, then close the reader via `deinit` without
   sending the final frame. Verify no leak via `std.testing.allocator`.

### Verification

- New unit test passes under DebugAllocator.
- `make abs` produces no `error(DebugAllocator): ... leaked` lines in
  the job log. (Check by grepping the Autobahn Server job log after
  the suite exits.)

---

## 3. Handshake extension tolerance — broader audit  *(P2, folds into #1)*

After #1 lands, do a one-pass audit of every other header in
`src/server/handshake.zig` that can return an error from a
client-supplied value (e.g., `Sec-WebSocket-Version`, method parse,
URL length). For each, decide:

- Genuine protocol violation → respond 400 with a precise error reason
  in the body (not just "unknown").
- Advisory/optional value → ignore, accept the connection.

Today the error-to-400 path in `_handleHandshake` is coarse — every
parse error becomes 400 with no diagnostic, which is hostile to clients
debugging their offers. Surface the error name in the 400 body.

### Verification

Cases 1.*–10.* (non-compression) should remain at `OK` or better.
No regressions in the Autobahn OK count.

---

## 4. Re-enable `permessage-deflate` compression  *(P2, ~1–2 days)*

### Problem

`Config.compression != null` currently returns `error.InvalidConfiguraion`
(sic — typo intentional for back-compat) from `Server(H).init` at
`src/server/server.zig:114`. The `Compression` struct in
`src/websocket.zig:22-29` exists but is unreachable.

### Why it was disabled

The 0.15 compression path used `std.compress.deflate.Compressor` /
`Decompressor` which took byte slices. 0.16 rebuilt the deflate API
around `std.Io.Reader` / `std.Io.Writer`. Both the send path
(`Conn.write`) and receive path (`Reader.read` → `decompress_writer`)
need to be rewritten against the new abstractions, and per-connection
deflate state (the `window bits` / `context_takeover` machinery) needs
to be re-plumbed.

### 0.16 deflate API reference

Per the migration notes:

- `std.compress.deflate` (and flate/xz/lzma2) now use
  `std.Io.Reader` / `std.Io.Writer`.
- Compression is new in 0.16 (0.15 only decompressed); per release
  notes, ~10% faster than zlib at default level, ~1% worse ratio.

### Fix plan

1. **Spike**: read `C:/zig/lib/std/compress/flate.zig` (or wherever
   compression lives post-rename) for the current constructor pattern.
   Identify how to maintain persistent deflate state across calls (for
   `no_context_takeover = false`) — most likely via a stateful
   `Compressor` struct holding internal ring buffer.
2. Add `compression_ctx: ?*CompressionCtx` field to the server's
   `Conn` struct (Linux/mac non-blocking) and to the `Blocking` path's
   per-connection state. Allocate on first use if `Compression` is
   configured and the handshake negotiated `permessage-deflate`.
3. On `Conn.write` / `Conn.writeBin`: if ctx present and
   `payload.len >= write_threshold`, compress and set the RSV1 bit on
   the outgoing frame. Otherwise write uncompressed.
4. On `Reader.read`: if RSV1 set and ctx present, feed the frame
   payload to the decompressor before delivering the message.
5. Remove the blanket early-return in `server.zig:114`. Update
   `src/websocket.zig:22-29` to drop the "don't know how to support
   these" comment on `client_no_context_takeover` /
   `server_no_context_takeover` (or implement them).
6. Restore the commented `.compression = .{ .write_threshold = 0 }`
   in `support/autobahn/server/main.zig` and
   `support/autobahn/client/main.zig`.
7. Remove `"13.7.*"` from `support/autobahn/server/config.json`.

### Verification

- Autobahn section 13.* no longer in UNIMPLEMENTED (198 → few or zero
  cases). 13.7.* moves from FAILED/excluded to OK.
- `zig fmt --check` passes.
- Unit tests still 29/29.
- Package smoke still passes.

---

## 5. TLS client — port to 0.16 `std.crypto.tls.Client` API  *(P2, ~1 day)*

### Problem

`Client.init(..., .{ .tls = true, ... })` currently returns
`error.TlsNotYetMigrated`. The client compiles and runs fine for
`ws://`; `wss://` is broken.

### Why it was deferred

The 0.15 `tls.Client.init(net_stream)` was a simple wrapper around a
stream. 0.16's signature:

```zig
pub fn init(input: *Reader, output: *Writer, options: Options) InitError!Client
```

where `options` requires caller-provided `entropy: *const [entropy_len]u8`,
`realtime_now: std.Io.Timestamp`, and pre-allocated `read_buffer` /
`write_buffer`. See `C:/zig/lib/std/crypto/tls/Client.zig:87-140`.

### Fix plan

1. Build Reader/Writer adapters over our `posix_compat.Stream`
   (fd → `Io.Reader` / `Io.Writer`). These need to pump bytes
   through blocking recv/send calls, honoring `Cancelable`.
2. Allocate `read_buffer` / `write_buffer` (each at least
   `tls.max_ciphertext_record_len` = 16KB + overhead).
3. Draw 32 bytes of entropy via `client.io.randomSecure(...)` at
   handshake time.
4. Pass `client.io.clockNow(.real)` for `realtime_now`.
5. For `ca` verification, accept an `Options.ca` field (at minimum
   `self_signed`; ideally a `Certificate.Bundle` constructed from
   the OS trust store — that's a deeper rabbit hole).
6. Route `Client.write` / `Client.readLoop` through the TLS client's
   methods when `config.tls` is true.

### Verification

- Integration test: connect to a known-good TLS WebSocket server
  (e.g., `wss://echo.websocket.events`) and round-trip a message.
- Unit test using a local TLS server with a self-signed cert plus
  `ca = .self_signed`.
- No regression in existing 5 `Client:` tests (they use `ws://`).

---

## 6. `ThreadPool` fuzz tests not discovered by test runner  *(P3, ~30 min)*

### Problem

`src/server/thread_pool.zig` defines two tests — `"ThreadPool: small fuzz"`
and `"ThreadPool: large fuzz"` — that aren't in the test-run output.
Only 29 tests run; these two are silently skipped. On Linux they would
have caught the `std.Thread.sleep` removal during migration
(we only hit it during CI compile because Linux eagerly analyses the
file).

### Root cause

The root module (`src/websocket.zig`) does
`std.testing.refAllDecls(@This())` — but that only refs `@This()`'s
direct declarations, not recursively into `src/server/thread_pool.zig`
which is imported by `src/server/server.zig` without being a public
surface element.

### Fix

Add an explicit `_ = @import("server/thread_pool.zig");` at module
scope in `src/server/server.zig` (inside a `comptime` block, or a
`test { refAllDecls(@This()) }` at the bottom of `thread_pool.zig`
itself).

### Verification

Unit test count goes from 29 to 31. The two ThreadPool fuzz tests run
and pass in all four matrix combos.

---

## Scope + priority summary

| #  | Issue                          | Size    | Priority |
|----|--------------------------------|---------|----------|
| 1  | Handshake extension tolerance  | ~30 min | **P0**   |
| 2  | `Fragmented` leak audit         | 1–2 hr  | **P1**   |
| 3  | Handshake error diagnostics    | ~30 min | P2       |
| 4  | Re-enable compression          | 1–2 day | P2       |
| 5  | TLS client port                | ~1 day  | P2       |
| 6  | ThreadPool test discovery      | ~30 min | P3       |

Recommended order: **1 → 6 → 2 → 3 → 4 → 5**. Items 1 and 6 are cheap
and each shrinks the "known-bad-but-gated" surface. Item 2 is
correctness, so it ships before the big features. Item 3 is a natural
follow-on once 1 is merged. Items 4 and 5 are both feature scope;
tackle whichever has active downstream demand.

## Definition of done

All items closed when:

1. `support/autobahn/server/config.json` has `exclude-cases: []`.
2. Autobahn Server gate runs with `OK + NON-STRICT + INFORMATIONAL >=
   515` out of 517 cases.
3. Autobahn Client gate stays green.
4. `zig build test` runs **31** tests (after item 6) with zero
   DebugAllocator leaks.
5. `wss://` smoke test against a real TLS WebSocket endpoint passes.
