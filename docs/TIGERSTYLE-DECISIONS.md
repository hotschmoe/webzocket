# TigerStyle rewrite: decisions D1 to D11 (teak, zunk, webzocket, rich_zig)

Made 2026-11-26 by Claude at the owner's direction ("i will need YOU to make d1 through d11 decisions").
Each entry gives the decision, the reason, the alternatives turned down, and what it would cost to reverse.
The working rules that follow from these are in `docs/TIGERSTYLE.md`. The plan and the quoted sources are kept outside this repository by the owner.

Three of these are cheap to change now and expensive later: D5 (naming), D6 (assertions in release builds)
and D7 (what happens at a limit). If the owner disagrees with any of them, before phase 4 is the time.

## D1. Rewrite in place, module by module

**Decision.** In place, on master, one module at a time under the simulator. No new repository, no
long-lived rewrite branch.

**Why.** Neither repository has a test that says what correct behaviour is. In place, the old module is the
oracle: old and new run side by side in the simulator on generated input until they agree, then the old one
goes in the same change. The examples, Kerf and Domino keep building the whole time, so a wrong turn shows
up within one module, not at the end.

**Turned down.**
- A new repository. Clean history and no ratchet friction, but nothing to compare against until it is
  complete, and two codebases to keep alive in the meantime.
- A long-lived branch. Same oracle as in place, but it drifts from master and every fix has to be made twice.

**To reverse.** Cheap at any point; nothing about working in place prevents starting a fresh tree later.

## D2. What counts as platform

**Decision.** Platform, and therefore not a dependency:
- the Zig toolchain and standard library;
- the kernel's system call interface;
- on Windows, the system DLLs (user32, gdi32, the Direct3D and DXGI libraries);
- on macOS, the Apple frameworks, reached through the Objective-C runtime as today;
- in the browser, the web APIs;
- on Linux, the X11 and Wayland wire protocols spoken over a socket, and (only for an optional GPU
  backend) libvulkan and the vendor's driver.

Ours, and therefore not a dependency to remove: any package in the owner's own repositories
(`hotschmoe/*`). Today that is rich_zig (written by the owner) and webzocket (the owner's fork). See
amendment 1 at the end.

Everything else is a dependency and has to be owned or removed: libX11, libwayland-client, libxkbcommon,
libwayland-cursor, wgpu-native, stb_truetype, HarfBuzz, bash, PowerShell, Python, Node and its packages,
third-party CI actions. Chromium stays as the thing under test in the background gate.

The Linux rule in one sentence: a teak app must be able to open a window and draw with no `dlopen` at all
(CPU backend over shared memory); a GPU backend may load libvulkan at run time, and must never be required.

**Why.** The line is "the vendor's only interface to the machine". On Windows and macOS that interface is a
library; on Linux it is the wire protocol, and libX11 or libwayland are conveniences over it. A GPU driver
on Linux is a user-space library with no lower interface, so it is platform in the same sense d3d11.dll is,
but only for the backend that uses it.

**Turned down.**
- Strict zero on Linux (CPU rendering only, no libvulkan ever). It settles D3 before anything has been
  measured.
- Keeping the dlopened Linux libraries as platform. They are loaded at run time, so nothing is fetched or
  built, but their behaviour is not ours, cannot be simulated or fuzzed, and differs between distributions.

**To reverse.** The line can be loosened at any time. Tightening it later costs whatever was built on the
looser line.

## D3. GPU route

**Decision.**
1. Write a CPU rasterizer first and ship it as a real backend. It is also the simulator's pixel mode and
   the reference image for any other backend.
2. wgpu-native stays, unchanged, until something replaces it on a given platform. No new work is built on
   it.
3. Whether to write native GPU backends (Direct3D, Metal, Vulkan, WebGPU) is decided after phase 3, from
   the existing gates (input latency, idle memory, size) run on the CPU backend with the real examples.
4. The Gpu interface does not grow before then. Pull request teak #175 (retained canvas geometry) is
   parked as a draft: it adds two required Gpu functions for a backend that may be removed, and its
   measured win is in tessellation, which phase 4 redesigns anyway ("render to vertices").

**Why.** The CPU rasterizer is needed whatever the answer to point 3 is, so it cannot be wasted work. It
removes the GPU driver from every gate, and it turns "is our renderer correct" into a comparison of two
images. The GPU question is a performance question, and there are no performance numbers for a backend
that does not exist yet.

**Turned down.**
- Native GPU backends first. Four backends with four shader languages and nothing to check them against.
- Keeping wgpu-native for good. It is 7 to 9.5 MB of prebuilt Rust per platform, the largest thing in the
  tree that is not ours, and the opposite of what the owner asked for.
- CPU only, decided now. Possibly where this ends up; deciding it without measurements would be a guess.

**To reverse.** Nothing to reverse until point 3. Parking #175 costs a merge with master when it is
picked up again.

## D4. Text shaping without HarfBuzz

**Decision.** The HarfBuzz option is removed in phase 3, together with stb_truetype. Teak states which
scripts it shapes itself: Latin, Greek, Cyrillic, and CJK without contextual forms, with kerning,
ligatures and combining marks from the existing shaper and the existing bidirectional algorithm. Arabic
and Indic scripts are documented as not shaped until an owned OpenType layout engine exists. That engine is
not scheduled.

**Why.** HarfBuzz is a large C++ library behind an opt-in build flag used by one showcase. Owning all
dependencies rules it out, and writing a full OpenType shaper is a project the size of a rewrite phase on
its own. Saying plainly what is supported is better than shipping an option that contradicts the rule.

**Turned down.**
- Keep HarfBuzz as an opt-in exception. An exception to "we must own all dependencies" on day one.
- Write Arabic and Indic shaping now. No consumer needs it today; the owned font reader of phase 3 has to
  exist first in any case.

**To reverse.** Adding shaping later is additive. The `Shaper` interface stays.

## D5. Naming: snake_case

**Decision.** Functions, variables and files are `snake_case`, as TigerStyle says. Types stay
`PascalCase` and functions that return a type stay `PascalCase`, as in Zig and in TigerBeetle.
- New code (tidy, the simulator, the CPU rasterizer, the font reader, zunk's owned replacements) is
  snake_case from the first commit.
- Existing public API is renamed module by module in phase 4, when each module is rewritten and its API
  changes anyway. Each rename ships with a migration note. No aliases, no compatibility layer.
- There is no repository-wide rename now. A bulk rename is the kind of codemod the owner's rules forbid,
  it would break every consumer before the simulator exists to catch mistakes, and it buys nothing.
- tidy counts camelCase function names per directory as a ratchet, so the number only goes down.

**Why.** The owner asked for TigerStyle by name, and this is one of its rules that a tool can check. Phase 4
breaks every signature for other reasons (declared limits, typed results), so consumers pay for one
migration either way; renaming in the same step makes it one migration instead of two. TigerBeetle lives
with the same seam this creates (its own snake_case next to the standard library's camelCase).

**Turned down.**
- Keep Zig's camelCase. Consistent with the standard library and with what Zig programmers expect, and no
  rename cost. It would mean adopting TigerStyle "except the naming", and the question would come back.
- Rename everything now. Covered above.

**Cost, stated plainly.** For the length of phase 4 the public API is mixed. Kerf, Domino and every
example change their call sites as each module lands.

**To reverse.** Cheap until phase 4 starts (only new, internal code is affected). After that, a second
migration for every consumer.

## D6. Assertions stay on in release builds

**Decision.**
- One owned `assert`, checked in every optimize mode. `std.debug.assert` is not used in rewritten code,
  because in ReleaseFast and ReleaseSmall a failed one is undefined behaviour, not a stop.
- Assertions are for programmer errors only. Anything the outside world can cause (a bad font file, a lost
  surface, a refused upload, a full buffer, malformed input from a server or a wasm module) is a typed
  result and is never asserted.
- Checks that cost more than constant time per call (walking a whole buffer to verify it) sit behind one
  comptime flag, on in Debug and in the simulator, off in release.
- When an assertion fails in an app, the runtime's panic path first hands the input recording to the Host
  to be written out, so the failure can be replayed in the simulator from a seed or a recording.
- Keeping the user's work safe across a crash is the app's job, through ordinary Msgs (autosave). The
  framework does not add a crash hook into the Model.

**Why.** An assertion that is compiled out in the build people actually run only documents an invariant.
One that is on stops the program at the first wrong state, before it draws or saves something wrong, and
the simulator turns each stop into a reproducible seed. The existing `oom()` policy already works this way.

**Turned down.**
- Assertions in Debug only. Smaller and faster release builds, and silent corruption instead of a stop.
- Assertions that log and continue. The program is then running in a state its author said was impossible.
- A framework hook that lets the app save on panic. It runs app code on top of a state known to be wrong.

**Cost.** Size and time in release builds, wasm most of all. The gates from #172 measure both; if a hot
loop shows up there, the fix is to hoist the check, not to turn assertions off.

**To reverse.** One constant.

## D7. Reaching a declared limit

**Decision.**
- An app declares its limits once, in one struct, at startup (commands per frame, text bytes, vertices,
  glyphs, queue lengths, resources). Defaults fit the examples. The runtime allocates for exactly those
  limits at startup and never again.
- Reaching a limit is not an error value on every call and not a crash. The operation that does not fit is
  skipped, counted, and reported: the frame carries a limit report, the app receives it as a Msg, and Debug
  builds draw a visible banner naming the limit.
- View emitters stay non-failing, as they are today. `view` remains a pure function with no error paths.
- The simulator runs with limits set low on purpose and checks that the report matches what was skipped
  (checker 10).

**Why.** In a database a limit follows from configuration, so exceeding it is a bug and a crash is right.
In a UI the size of the content is the user's data: a document can always be longer than the limit. That
makes a limit an operating condition, which D6 says is never an assertion. Making every emitter return an
error would put `try` on every line of every view.

**Turned down.**
- Panic at the limit. Loses the user's work over a long document.
- Error unions on emitters. Honest, and unusable.
- Grow on demand. That is today's behaviour and exactly what static allocation removes.
- Drop silently. The one outcome nobody can debug.

**To reverse.** The report mechanism is additive; the allocation rule is the part that would be costly to
undo once modules are written against it.

## D8. Where the simulator sits in the test policy

**Decision.**
- There are no `test` blocks and no unit tests, as `ENGINEERING.md` says. The simulator, the fuzzers and
  tidy are programs, built and run by `zig build`.
- Blocking gate, at most ten end-to-end checks: the existing canaries, then one short fixed-seed simulator
  run per example as each comes under simulation. When that passes ten, the CLI canaries go first, since a
  simulator run of the same example covers them. tidy runs in the blocking gate as part of the build check;
  it is a lint, not a test.
- Background gate: random seeds for as long as the machine has, the fuzzers, the differential runs of
  phase 4, the live hosts, the browser.
- A failing seed is fixed or filed; it is not added to the blocking list as a regression test. Seeds stop
  reproducing when the code changes, so a list of old seeds becomes a set of tests that can never fail.
- The old-against-new comparison of phase 4 lives in the simulator and is deleted with the old module.

**Why.** It is the owner's policy applied as written: `ENGINEERING.md` already puts long simulation runs
in the background gate "unless a short run is one of the ten".

**Turned down.**
- Unit tests beside the simulator, as TigerBeetle has. Contradicts the owner's rule.
- All simulation in the background. Then a change that breaks determinism is found the next day.

**To reverse.** Trivial.

## D9. Comments

**Decision.** The owner's rule stands: a comment only for a non-obvious invariant or a reference, in one
line; reasons go in `SRC.md`, one section per module. Recorded as a deliberate difference from
TigerStyle, which says "Always say why" in the code. Assertions carry part of what TigerStyle would put in
comments: an assertion states an invariant and is checked.

**Turned down.** TigerStyle's rule as written. It is a reasonable rule, and it is not the owner's.

**To reverse.** Trivial.

## D10. Two repositories

**Decision.** Teak and zunk stay separate. tidy is copied into each, not shared.

**Why.** Zunk is a wasm build tool with a browser runtime and is usable without teak. After Z1 it brings
nothing else into teak's tree. The one place they must change together is the import protocol of Z5, and a
written protocol with a version is the right tool for that, not a shared repository. A shared tidy package
would be a dependency between the two for the sake of a few hundred lines.

**Turned down.** One repository. Atomic changes across the boundary and one simulator, in exchange for
every zunk user fetching a UI framework.

**To reverse.** Moderate; merging two histories is mechanical.

## D11. Zig version

**Decision.** One shared toolchain, the current release (0.17.1 today), the same in both repositories and
on every machine, moved in one wave when a release lands, as `ENGINEERING.md` says. tidy fails if
`build.zig.zon`, the example manifests and the CI files disagree on the version. The third-party
`setup-zig` action is replaced by a short script that downloads the release and checks its SHA-256
against a value stored in the repository; that script is the one piece of shell allowed to remain, since
there is no Zig to run before it. It is replaced when CI is next touched, not as its own task.

**Turned down.**
- Pin per repository. Contradicts the shared-toolchain rule.
- Track Zig master. Nothing here needs it.

**To reverse.** Trivial.

## What these decisions start

In order, with the plan's phase names:

1. Phase 0 in both repositories: tidy with ratchets, in the blocking gate; these decisions and the rule
   sheet in each repository; a tag on each master so "before the rewrite" has a name.
2. Zunk: generative testing of the build path (Z3) first, since it needs nothing else. Z1 as first
   written is withdrawn (amendment 1).
3. Phase 1 in teak: close the seam (options struct in place of environment reads, clocks and files behind
   the Host, text caches as passed-in state, a recorder that captures everything the Host delivers).
4. Phase 2 in teak: the simulator. Nothing in phase 4 starts until its checkpoint passes.

## Amendment 1 (2026-11-26): webzocket and rich_zig are ours

The first version of D2 listed webzocket and rich_zig as dependencies to replace, and a first agent was
started on step Z1 to write in-tree replacements. That was my mistake: both are fetched from
`github.com/hotschmoe/...`, and the owner pointed out that those are their own repositories. The agent was
stopped before it changed any tracked file.

**Decision.**
- Both stay as zunk's packages. "We must own all dependencies" is already true of them.
- Being ours, they are inside the rules, not outside them. tidy reports on each (report only, no ratchet
  in their repositories until the owner wants one there), so the distance from the rule sheet is a number.
- They are not rewritten as part of this effort. The request was teak and zunk.
- Where zunk's simulation needs something from them, the change is made in them. The known case is step
  Z4: the dev server has to run on one thread over an injected IO interface, so webzocket has to be usable
  without owning the socket or a thread. If it is not, that is a change to webzocket, not a reason to go
  around it.
- Console output (rich_zig) is a sink. Zunk's logic must not depend on it for anything the simulator
  checks; the JSON report path already bypasses it.

**Turned down.**
- Carrying on with in-tree replacements because zunk uses a small part of each (about four call sites and
  about 110 print calls against roughly 30,000 lines). It would shrink what has to meet the rules, and it
  would mean the owner's own libraries are not good enough for the owner's own tool. If they fall short,
  they get fixed.
- Rewriting both now, to the full rule sheet. Not asked for, and larger than zunk itself.

**Open point for the owner.** webzocket is a fork. Owning it means its upstream is no longer a source of
changes we take without reading; whether to keep merging from upstream is the owner's call.

## Amendment 2 (2026-11-26): the owner's rulings after the first rewrite session

Four questions were put to the owner with a recommendation each; the owner agreed with all four.

- **Assertion average.** tidy leaves a function whose body is a single statement out of the
  two-assertions-per-function average. Files held individually in the ratchet must be at zero deficit, so the
  rule is at full strength where new code is written. Turned down: the strict count over every function,
  which is met in practice by filler assertions in getters.
- **rich_zig in teak's root manifest.** Accepted for now as a lazy dependency used only by
  `zig build sim`, because the simulator builds examples/counter_greeter and that example's app module
  imports it. To be removed by moving the terminal library out of the example's app module. Turned down:
  dropping the example from the simulator.
- **zunk CI.** Runs for pull requests into any branch, so stacked pull requests are tested on Linux, macOS
  and Windows. Turned down: master only, which left stacked work untested on two of the three systems.
- **webzocket upstream.** This closes the open point of amendment 1. The fork's upstream is no longer
  merged wholesale. webzocket is treated as the owner's own code; a protocol or security fix from upstream
  is read and brought over by hand. Turned down: tracking upstream, which would keep undoing any work to
  bring the package inside the rules.

Stacked pull requests are merged in order with merge commits, not squashed.

## Amendment 3 (2026-11-26): rich_zig and webzocket join the rewrite; a correction

**Scope.** Amendment 1 said the two packages "are not rewritten as part of this effort. The request was teak
and zunk." The owner has now asked for them: the TigerStyle and simulation work extends to rich_zig and
webzocket. The same decisions D1 to D11 and the same rule sheet apply in each, and each carries the shared
`tools/tidy.zig` with its own configuration block.

**Order.**
- webzocket first. It parses bytes from the network, which is where a seeded generative tester pays most,
  and zunk's dev server simulation depends on it. Its 38 `test` declarations are the only oracle it has
  today, so they stay until a seeded tester covers what they cover; tidy holds the count as a ratchet, so
  it can only go down.
- rich_zig second. It is an output sink with one input-facing part, the markup parser, which teak's
  counter_greeter example also uses; that parser gets the first tester. The rest starts with phase 0 only
  (tidy, assert, rule sheet) and an inventory of what a simulator would have to stand in for (terminal
  size and capabilities, environment, time for progress and live displays, threads).

**Turned down.** Rewriting either in one pass. Together they are about 22,000 lines, more than zunk; the
order above is the same one teak and zunk followed (measure, build the oracle, then rewrite).

**Correction to amendment 2.** It said rich_zig would leave teak's root manifest once "the terminal library"
moved out of counter_greeter's app module. That rested on a guess I had not checked. The example uses
rich_zig's markup parser in its view (`src/rich_zig_adapter.zig`); that is the point of the example. The
lazy `sim_rich_zig` entry in teak's root manifest stays for as long as the simulator builds that example.

## Amendment 4 (2026-11-26): rulings from the first pass over webzocket and rich_zig

Made while reviewing the first agents' work on the two packages. Each was a place where the brief was
silent or wrong.

- **The test count is a ratchet, not a ban.** The shared tidy failed on any `test` declaration. webzocket's
  38 are its only oracle until the seeded tester covers them, so the count is stored and may only fall, like
  every other number. In teak and zunk it is stored as zero, which is the same rule as before. Turned down:
  a per-repository switch in tidy's configuration, which is a second rule where one will do.
- **A crash that outside bytes can cause is fixed when found, not saved for the rewrite.** The first brief
  said "nothing is rewritten yet" and the agent left two crashes in webzocket (a 64-bit frame length that
  overflowed, a short request line that sliced out of range). Both are now typed errors. Looseness against
  RFC 6455 that is not a crash stays for the rewrite and is listed per module in webzocket's SRC.md.
- **webzocket's maximum bounds overflow storage only.** I first ruled that the configured maximum should
  apply to every message. That would have made zunk's dev server reject every frame: it sets the maximum to
  zero to forbid overflow storage and reads frames from a static buffer. The check was removed again, the
  tester gained zunk's configuration as an ordinary accepted case, and the mismatch (a maximum below the
  static buffer has no effect) is listed for the rewrite.
- **In rich_zig markup, a tag that is not a style is text.** The agent made unclosed and unknown tags an
  error on the strength of an error table in SPEC.md. Before that, `Text.fromMarkup` silently dropped an
  unknown tag, so zunk's `[green][OK][/]` printed no label. Neither is right. An unknown opening tag or
  closer is kept as written in every API, an unclosed style runs to the end of the text, and a Text owns
  the link addresses it returns. Turned down: strict errors (breaks every caller that prints brackets) and
  keeping the silent drop (loses the caller's text).
- **A package's build.zig adds its own tools only when it is the root package.** Tidy, the testers and the
  examples are behind `b.pkg_hash.len == 0`; a project that depends on webzocket or rich_zig gets the
  module and nothing else, and `.paths` does not grow.
