# Rules for rewritten and new code (webzocket)

These apply to every file that is new or rewritten under the TigerStyle rewrite. Old code is held by the
tidy ratchets: its counts may go down, never up. The decisions behind each rule are in
`docs/TIGERSTYLE-DECISIONS.md` (D1 to D11).

## Shape

- A function is at most 70 lines. A line is at most 100 columns.
- No recursion. Use an explicit stack with a declared maximum depth.
- Every loop has a bound that can be read off the code: a slice, a counted range, or a named maximum with
  an assertion that it was not reached. No `while (true)` without one.
- Sized integer types (`u32`, `u16`) for fields and parameters. `usize` only where the language demands
  it (indexing, slice lengths) and converted at the edge.
- At most four or five parameters; past that, pass a struct.

## Names

- `snake_case` for functions, variables and files. `PascalCase` for types and for functions that return a
  type. Units and qualifiers go last: `timeout_ms`, `width_px`, `count_max`.
- No abbreviations that need a glossary.

## Assertions

- Use the owned `assert`, which is checked in every optimize mode. Not `std.debug.assert`.
- Average at least two assertions per function, measured per directory: arguments on entry, results on
  exit, and invariants in between. Assert both what must hold and what must not.
- Assertions are for programmer errors. Anything the outside world can cause is a typed result.
- A check that costs more than constant time goes behind the `verify` flag (on in Debug and the simulator).

## Memory

- Allocate at startup, for declared limits. Nothing allocates after startup: no growable containers, no
  per-call allocation, no arena that grows.
- Every buffer and queue has a named limit. Reaching it skips the operation, counts it and reports it; it
  never crashes and is never silent.
- Zunk's build path (read a wasm module, emit files) uses the compiler variant: input limits are declared,
  memory is sized once from the input, nothing is freed.

## Determinism

- Outside `platform/` and `gpu/` (and zunk's IO layer): no clock, no environment variable, no file, no
  thread, no random source, no global mutable state. Each comes in as an argument from the entry point.
- One thread of control for all logic.

## Errors

- Every error is handled or returned. No `catch {}`, no `catch return` that hides a failed allocation, no
  `catch unreachable`.

## Dependencies

- None, apart from the Zig toolchain, what D2 names as platform, and packages from the owner's own
  repositories (`hotschmoe/*`), which are ours and held to this sheet. Tools and scripts are Zig programs
  run by `zig build`.

## Tests and comments (the owner's rules, `ENGINEERING.md`)

- No `test` blocks, no unit tests, no golden output. Checks are programs: tidy, the simulator, fuzzers,
  end-to-end runs. At most ten blocking end-to-end checks per repository.
- A comment only for a non-obvious invariant or a reference, in one line. Reasons go in `SRC.md`.
- No emojis. No compatibility shims: a rename or an API change is a full migration with a note.

Amendment 3 retains webzocket's 38 existing test declarations as a downward ratchet until the
generative tester replaces their checks. New files still contain no test declarations.
