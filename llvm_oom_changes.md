# LLVM OOM workaround — cleanup checklist

Context: While working through post-migration follow-ups (#1/#2/#3/#6) on an
aarch64-Windows machine running x86_64 Zig under Prism emulation, `zig build
test` was intermittently failing with `LLVM ERROR: out of memory` /
`std::bad_alloc`. Peak LLVM memory during the Debug test build apparently
exceeds Prism's per-process ceiling (even though the host has ~28 GB free).

None of the fix code itself is emulation-specific. The only scaffolding added
for the emulation environment is a single opt-in build option. This doc lists
exactly what to undo once you're back on a native x86_64 machine and have
confirmed the build is clean without it.

## What was added

### `build.zig` — `-Dno-llvm=true` option

```zig
if (b.option(bool, "no-llvm", "Use self-hosted codegen (workaround for LLVM OOM under emulation)") orelse false) {
    tests.use_llvm = false;
}
```

- Defaults to `false`. CI and anyone doing `zig build test` without the flag
  is unaffected.
- It never actually worked as a workaround on this machine — the self-hosted
  codegen path immediately fails with
  `sub-compilation of compiler_rt failed: failed to link with LLD:
  LibCInstallationNotAvailable` because `link_libc = true` is set on the
  `webzocket` module and Zig can't resolve a libc install without LLVM's
  path logic engaged.
- It is therefore dead code as far as this machine is concerned. The build
  just happens to pass after 1–3 retries through straight `zig build test`,
  because LLVM memory pressure is non-deterministic.

## What to do on the x86_64 machine

1. **Confirm the baseline compiles and tests pass without any flags.**
   ```
   zig build test
   zig build test -Dforce_blocking=true
   zig fmt --check src/
   ```
   Expect: 33/33 tests pass in both modes, formatter clean. No retries.

2. **Remove the opt-in block from `build.zig`.**
   Delete these three lines in `build.zig` (the block just before
   `const run_test = b.addRunArtifact(tests);`):
   ```zig
   if (b.option(bool, "no-llvm", "Use self-hosted codegen (workaround for LLVM OOM under emulation)") orelse false) {
       tests.use_llvm = false;
   }
   ```
   That restores `build.zig` to the same shape as pre-follow-up work.

3. **Re-run the full matrix to prove the delete is safe.** Same commands as
   step 1.

4. **Run the Autobahn suites.** These need Docker and haven't been validated
   yet since Prism-emulated Autobahn is not a trustworthy signal:
   ```
   make abs     # server fuzzing; check that 13.7.* are no longer FAILED
                # and the job log has zero DebugAllocator leak lines
   make abc     # client fuzzing; confirm unchanged
   ```
   This is the real validation for fix #1 (13.7.*) and fix #2 (no leaks) —
   both were verified only at unit-test level on the ARM machine.

5. **Commit the cleanup** as a small follow-up: `chore: remove LLVM-OOM
   emulation workaround from build.zig` or similar. Keep it separate from
   any Autobahn-result commits.

## What to keep

Everything else. All of the following is legitimate production code, not
emulation scaffolding, and should not be touched:

- `src/server/server.zig` — comptime import of `thread_pool.zig` (fix #6),
  `reader.deinit()` calls in non-blocking cleanup paths (fix #2), expanded
  else branch in `respondToHandshakeError` (fix #3).
- `src/server/handshake.zig` — rewritten `parseExtension`, new regression
  tests (fix #1).
- `src/proto.zig` — new `"Reader: deinit during in-flight fragment"` test
  (fix #2).
- `support/autobahn/server/config.json` — empty `exclude-cases` (fix #1).
- `build.zig.zon` — version bumped to `0.2.1`.
- `POST_MIGRATION_FOLLOWUPS.md` — status block and per-item DONE markers.
- `io_async_redesign_todo.md` — parked design doc for a future `std.Io`
  rewrite.

## Things to NOT carry back

There are none — no hidden flags, no temporary files, no skipped tests.
The only emulation-specific item is the `-Dno-llvm=true` block in
`build.zig` described above.
