<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

<!-- Add your project's toolchain, architecture, workflows here -->
<!-- This section will not be touched by haj.sh -->

# webzocket - Zig WebSocket Library

A high-performance WebSocket server and client implementation in Zig. Fork of websocket.zig by Karl Seguin, adapted for our ecosystem.

- **Minimum Zig**: 0.15.2
- **Dependencies**: None (self-contained)
- **License**: MIT

---

## Philosophy

- **Performance-first** - Dual execution modes (blocking + non-blocking via epoll/kqueue) for optimal throughput.
- **Zero unnecessary allocations** - Buffer pooling, pre-allocated connection slots, reusable message buffers.
- **Full RFC 6455 compliance** - Validated by the Autobahn test suite (500+ protocol conformance tests).
- **Generic handler pattern** - Applications define their own Handler type with lifecycle callbacks.

---

## Zig Toolchain

```bash
zig build                       # Build library
zig build test                  # Run all tests
zig fmt src/                    # Format before commits
```

### Makefile Shortcuts

```bash
make t                          # Run both blocking and non-blocking tests
make tn                         # Non-blocking tests only
make tb                         # Blocking tests only
make abs                        # Autobahn server compliance test
make abc                        # Autobahn client compliance test
```

---

## Architecture

```
    Client Request --> Handshake --> Connection --> Message Loop
         ^                                            |
         |____________________________________________|
```

### Execution Modes

```
+-----------------------------------------------------------+
|  Non-blocking mode (Linux, macOS, BSD)                    |
|  epoll/kqueue event loop + worker thread pool             |
+-----------------------------------------------------------+

+-----------------------------------------------------------+
|  Blocking mode (Windows, or forced via build option)      |
|  Thread-per-connection with blocking sockets              |
+-----------------------------------------------------------+
```

### Layer Stack

```
+--------------------------------------------------+
|              YOUR APPLICATION                     |
|  Handler struct with lifecycle callbacks:         |
|    init, afterInit, clientMessage, clientClose    |
+--------------------------------------------------+
                      |
                      v
+--------------------------------------------------+
|                  webzocket                        |
|  Server      Event loop, connection management   |
|  Client      Connect, read/write, TLS            |
|  Handshake   HTTP upgrade, header validation      |
|  Proto       Frame parsing, masking, compression  |
|  Buffer      Pooled buffer management             |
|  ThreadPool  Worker thread scheduling             |
+--------------------------------------------------+
                      |
                      v
+--------------------------------------------------+
|              OS Network Layer                     |
|  TCP/Unix sockets, epoll/kqueue, TLS 1.3         |
+--------------------------------------------------+
```

---

## Source Layout

| File | Purpose |
|------|---------|
| `src/websocket.zig` | Public API exports |
| `src/proto.zig` | WebSocket protocol: frames, messages, reader FSM |
| `src/buffer.zig` | Buffer pooling and management |
| `src/server/server.zig` | Server core (blocking/non-blocking modes) |
| `src/server/handshake.zig` | HTTP WebSocket handshake parsing |
| `src/server/thread_pool.zig` | Worker thread pool |
| `src/server/fallback_allocator.zig` | Allocator for blocking mode |
| `src/client/client.zig` | Client implementation |
| `src/testing.zig` | Test utilities |
| `test_runner.zig` | Custom test runner with leak detection |

---

## Key Patterns

### Server Handler

```zig
const Handler = struct {
    conn: *websocket.Conn,

    pub fn init(h: *Handler, _: *websocket.Conn) !void {
        // Called after successful handshake
    }

    pub fn clientMessage(h: *Handler, data: []const u8) !void {
        // Handle incoming message
        h.conn.write(data) catch {};  // Echo back
    }

    pub fn clientClose(h: *Handler) void {
        // Connection closing
    }
};
```

### Client Usage

```zig
var client = try websocket.Client.init(allocator, .{
    .host = "localhost",
    .port = 9882,
});
defer client.deinit();

try client.send("hello");
const msg = try client.read();
```

### Server Configuration

```zig
pub const Config = struct {
    port: u16 = 9882,
    address: []const u8 = "127.0.0.1",
    unix_path: ?[]const u8 = null,
    worker_count: ?u8 = null,
    max_conn: ?usize = null,
    max_message_size: ?usize = null,
    // ... handshake, thread_pool, buffers, compression
};
```

---

## Key Features

| Feature | Status |
|---------|--------|
| WebSocket server (non-blocking) | Complete |
| WebSocket server (blocking) | Complete |
| WebSocket client | Complete |
| TLS 1.3 support | Complete |
| Message compression (DEFLATE) | Temporarily disabled (Zig 0.15 upgrade) |
| Buffer pooling | Complete |
| Unix domain sockets | Complete |
| Autobahn compliance | Complete |
| Cross-platform (Linux, macOS, Windows) | Complete |

---

## Bug Severity

### Critical - Must Fix Immediately

- `.?` on null (panics)
- `unreachable` reached at runtime
- Index out of bounds
- Integer overflow in release builds (undefined behavior)
- Use-after-free or double-free
- Memory leaks in long-running paths
- Connection state corruption under concurrency

### Important - Fix Before Merge

- Missing error handling (`try` without proper catch/return)
- `catch unreachable` without justification
- Ignoring return values from `!T` functions
- Race conditions in threaded code
- Thread pool deadlocks or starvation

### Contextual - Address When Convenient

- TODO/FIXME comments
- Unused imports or variables
- Suboptimal comptime usage
- Excessive debug output

---

## Version Updates (SemVer)

When making commits, update `version` in `build.zig.zon`:

- **MAJOR** (X.0.0): Breaking changes or incompatible API modifications
- **MINOR** (0.X.0): New features, backward-compatible additions
- **PATCH** (0.0.X): Bug fixes, small improvements, documentation

---

## Roadmap

- [x] WebSocket server (non-blocking mode)
- [x] WebSocket server (blocking mode)
- [x] WebSocket client
- [x] TLS 1.3 support
- [x] Buffer pooling and management
- [x] Autobahn protocol compliance
- [x] Unix domain socket support
- [x] Cross-platform CI (Linux, macOS, Windows)
- [ ] Re-enable compression (DEFLATE) for Zig 0.15
- [ ] HTTP/2 WebSocket upgrade (RFC 8441)


<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress -> closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
