# Zig 0.15.2 → 0.16.0 Migration Guide for LLM Coding Assistants

> **Purpose**: This document is a reference for LLM coding assistants working on Zig projects originally targeting 0.15.x. It covers mandatory syntax/API migrations AND proactive opportunities to adopt new 0.16.0 features. When reviewing or writing code, assistants should apply these rules automatically without being asked.

> **Source**: Official release notes at https://ziglang.org/download/0.16.0/release-notes.html

---

## Table of Contents

1. [Critical: Mandatory Breaking Changes](#1-critical-mandatory-breaking-changes)
2. [Standard Library API Renames and Moves](#2-standard-library-api-renames-and-moves)
3. [std.Io Migration (The Big One)](#3-stdio-migration-the-big-one)
4. [Build System Changes](#4-build-system-changes)
5. [Compiler and Toolchain Notes](#5-compiler-and-toolchain-notes)
6. [Proactive Feature Adoption](#6-proactive-feature-adoption-suggest-when-relevant)
7. [Patterns to Watch For](#7-patterns-to-watch-for)
8. [Quick Reference: Error Set Renames](#8-quick-reference-error-set-renames)
9. [Quick Reference: Removed APIs](#9-quick-reference-removed-apis)

---

## 1. Critical: Mandatory Breaking Changes

These WILL cause compile errors. Fix them first.

### 1.1 `@cImport` is Deprecated

`@cImport` / `@cInclude` / `@cDefine` are deprecated. C translation now goes through the build system.

**Before (0.15.x):**
```zig
pub const c = @cImport({
    @cInclude("header.h");
});
```

**After (0.16.0):**

Create a C header file (e.g., `src/c.h`):
```c
#include "header.h"
```

In `build.zig`:
```zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
// Link any required system libraries:
// translate_c.linkSystemLibrary("libname", .{});

const c_module = translate_c.createModule();

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_module },
        },
    }),
});
```

In source files:
```zig
const c = @import("c");
```

For more customization, use the official translate-c package from `https://codeberg.org/ziglang/translate-c`.

### 1.2 `@Type` Replaced with Individual Builtins

`@Type` is removed. Replace with the specific builtin for each type kind.

**Integer types:**
```zig
// BEFORE
@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })
// AFTER
@Int(.unsigned, 10)
```

**Pointer types:**
```zig
// BEFORE
@Type(.{ .pointer = .{
    .size = .one,
    .is_const = true,
    .is_volatile = false,
    .alignment = @alignOf(u32),
    .address_space = .generic,
    .child = u32,
    .is_allowzero = false,
    .sentinel_ptr = null,
} })
// AFTER
@Pointer(.one, .{ .@"const" = true }, u32, null)
```

**Struct types:**
```zig
// BEFORE
@Type(.{ .@"struct" = .{ .layout = .auto, .fields = &.{...}, .decls = &.{}, .is_tuple = false } })
// AFTER
@Struct(.auto, null, &.{"field1", "field2"}, &.{Type1, Type2}, &@splat(.{}))
```

**Union types:**
```zig
// BEFORE
@Type(.{ .@"union" = .{ .layout = .auto, .tag_type = MyEnum, .fields = &.{...}, .decls = &.{} } })
// AFTER
@Union(.auto, MyEnum, &.{"foo", "bar"}, &.{i64, f64}, &@splat(.{}))
```

**Enum types:**
```zig
// BEFORE
@Type(.{ .@"enum" = .{ .tag_type = u32, .fields = &.{...}, .decls = &.{}, .is_exhaustive = true } })
// AFTER
@Enum(u32, .exhaustive, &.{"foo", "bar"}, &.{0, 1})
```

**Tuple types:**
```zig
// BEFORE
@Type(.{ .@"struct" = .{ .layout = .auto, .fields = &.{...}, .decls = &.{}, .is_tuple = true } })
// AFTER
@Tuple(&.{ u32, [2]f64 })
```

**Function types:**
```zig
// BEFORE
@Type(.{ .@"fn" = .{ .calling_convention = .c, .is_generic = false, .is_var_args = false,
    .return_type = u32, .params = &.{...} } })
// AFTER
@Fn(&.{f64, *const anyopaque}, &.{.{}, .{ .@"noalias" = true }}, u32, .{ .@"callconv" = .c })
```

**Enum literal type:**
```zig
// BEFORE
@TypeOf(.something)
// AFTER
@EnumLiteral()
```

**Types with no new builtin (use existing syntax):**
- Array: use `[len]Elem` or `[len:s]Elem`
- Optional: use `?T`
- Error Union: use `E!T`
- Error Set: use `error{ ... }` (reifying error sets is no longer possible)
- Opaque: use `opaque {}`
- Float: use `std.meta.Float(bits)` (only 5 runtime float types exist)

**Tip for `&@splat(.{})`:** When all fields/params share the same attributes, use `&@splat(.{})` to fill defaults. This is idiomatic 0.16.0.

### 1.3 `@intFromFloat` Deprecated

Use `@trunc` instead. Additionally, `@floor`, `@ceil`, `@round`, and `@trunc` can now convert float → integer directly.

```zig
// BEFORE
const i: u32 = @intFromFloat(some_float);
const j: u32 = @intFromFloat(@round(some_float));
// AFTER
const i: u32 = @trunc(some_float);
const j: u32 = @round(some_float);
```

### 1.4 Pointers Forbidden in Packed Structs and Unions

Pointer-type fields inside `packed struct` or `packed union` are now a compile error.

```zig
// BEFORE (compiles in 0.15.x)
const Foo = packed struct {
    ptr: *u32,
    flags: u32,
};

// AFTER
const Foo = packed struct {
    ptr_raw: usize,  // store as integer
    flags: u32,

    pub fn getPtr(self: Foo) *u32 {
        return @ptrFromInt(self.ptr_raw);
    }
    pub fn setPtr(self: *Foo, p: *u32) void {
        self.ptr_raw = @intFromPtr(p);
    }
};
```

### 1.5 Packed Unions: All Fields Must Have Same Bit Size

All fields of a `packed union` must have the same `@bitSizeOf` as the backing integer.

```zig
// BEFORE (compiles in 0.15.x)
const U = packed union { x: u8, y: u16 };

// AFTER
const U = packed union(u16) {
    x: packed struct(u16) { data: u8, _pad: u8 = 0 },
    y: u16,
};
```

### 1.6 Explicit Backing Types Required in Extern Contexts

Enums, packed structs, and packed unions with inferred/implicit backing types cannot be used in extern contexts (exported, extern struct fields, etc.).

```zig
// BEFORE (compiles in 0.15.x)
const MyEnum = enum { a, b, c };
export var e: MyEnum = .a;  // ERROR in 0.16.0

// AFTER
const MyEnum = enum(u8) { a, b, c };
export var e: MyEnum = .a;  // OK
```

Same applies to `packed struct` → `packed struct(u8)` and `packed union` → `packed union(u8)`.

### 1.7 Runtime Vector Indexing Forbidden

You can no longer index a `@Vector` with a runtime-known index.

```zig
// BEFORE
for (0..vec_len) |i| {
    _ = my_vector[i];
}

// AFTER
const array: [vec_len]T = my_vector;  // coerce to array
for (&array) |elem| {
    _ = elem;
}
```

### 1.8 Vector/Array In-Memory Coercion Removed

If using `@ptrCast` to convert between array and vector memory, use language-level coercion instead.

```zig
// BEFORE
const vec_ptr: *@Vector(4, f32) = @ptrCast(array_ptr);

// AFTER
const vec: @Vector(4, f32) = array.*;  // value-level coercion
```

If coercing from `anyerror![4]i32` to `anyerror!@Vector(4, i32)`, unwrap the error first.

### 1.9 Returning Address of Local Variable is a Compile Error

```zig
// BEFORE (undefined behavior at runtime)
fn foo() *i32 {
    var x: i32 = 1234;
    return &x;
}

// AFTER: This is now a compile error.
// Allocate on the heap, accept a buffer, or restructure.
```

### 1.10 Switch on Void No Longer Requires `else`

Minor: if you had `else` prongs on void switches just to satisfy the compiler, you can remove them. Not breaking, but worth cleaning up.

### 1.11 Zero-bit Tuple Fields No Longer Implicitly `comptime`

If you relied on `@typeInfo(T).@"struct".fields[i].is_comptime` being `true` for zero-bit tuple fields, it now returns `false`. The field values are still comptime-known when the source is comptime, but the metadata flag changed.

### 1.12 Explicitly-Aligned Pointers Are Now Distinct Types

`*u8` and `*align(1) u8` are now technically different types (they were identical before). They still coerce to each other freely, so this only matters if you're comparing types with `==` in comptime code.

```zig
// This changes behavior:
comptime {
    if (*u8 == *align(1) u8) { ... }  // was true in 0.15, false in 0.16
}
```

---

## 2. Standard Library API Renames and Moves

### 2.1 Memory Functions

| Old | New |
|-----|-----|
| `std.mem.indexOf` | `std.mem.find` |
| `std.mem.lastIndexOf` | `std.mem.findLast` |
| New: `std.mem.cut` functions | Split a slice at a delimiter |

### 2.2 Formatting

| Old | New |
|-----|-----|
| `std.fmt.Formatter` | `std.fmt.Alt` |
| `std.fmt.format(writer, fmt, args)` | `writer.print(fmt, args)` |
| `std.fmt.FormatOptions` | `std.fmt.Options` |
| `std.fmt.bufPrintZ` | `std.fmt.bufPrintSentinel` |

### 2.3 Data Structures

| Old | New |
|-----|-----|
| `std.SegmentedList` | Removed, no replacement. Use `ArrayList` or custom. |
| `BitSet.initEmpty()` / `initFull()` | Use decl literals (e.g., `.{}`) |
| `EnumSet.initEmpty()` / `initFull()` | Use decl literals |
| Containers: "managed" style | Migrating to "unmanaged" containers |
| `std.PriorityQueue` | Reworked |
| `std.PriorityDequeue` | New addition |

### 2.4 I/O Types Removed

| Removed | Replacement |
|---------|-------------|
| `std.Io.GenericWriter` | Use `std.Io.Writer` directly |
| `std.Io.AnyWriter` | Use `std.Io.Writer` directly |
| `std.Io.GenericReader` | Use `std.Io.Reader` directly |
| `std.Io.AnyReader` | Use `std.Io.Reader` directly |
| `std.Io.null_writer` | Removed |
| `std.Io.CountingReader` | Removed |
| `std.Io.FixedBufferStream` | Removed |

### 2.5 Threading

| Old | New |
|-----|-----|
| `std.Thread.ResetEvent` | `std.Io.Event` |
| `std.Thread.WaitGroup` | `std.Io.Group` |
| `std.Thread.Futex` | `std.Io.Futex` |
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.Thread.Condition` | `std.Io.Condition` |
| `std.Thread.Semaphore` | `std.Io.Semaphore` |
| `std.Thread.RwLock` | `std.Io.RwLock` |
| `std.Thread.Mutex.Recursive` | Removed |
| `std.Thread.Pool` | Removed |
| `std.once` | Removed. Hand-roll or avoid global state. |

### 2.6 Allocators

| Old | New |
|-----|-----|
| `std.heap.ArenaAllocator` | Same name, now lock-free and thread-safe by default |
| `std.heap.ThreadSafeAllocator` | Removed entirely (anti-pattern). Make allocators natively thread-safe instead. |

### 2.7 Crypto

New additions (no migration needed, just awareness):
- `std.crypto`: AES-SIV, AES-GCM-SIV, Ascon-AEAD, Ascon-Hash, Ascon-CHash

### 2.8 Compression

- Deflate compression added (from scratch, competitive with zlib)
- `compress.lzma`, `compress.lzma2`, `compress.xz` updated to `Io.Reader` / `Io.Writer`
- Decompression bit reading simplified

### 2.9 Math

| Old | New |
|-----|-----|
| `std.math.sign` | Now returns the smallest integer type that fits |

### 2.10 Miscellaneous

| Old | New |
|-----|-----|
| `std.meta.Int` | Deprecated, use `@Int` builtin |
| `std.meta.Tuple` | Deprecated, use `@Tuple` builtin |
| `std.meta.declList` | Removed |
| `std.builtin.subsystem` | Removed. Use `zig.Subsystem`. |
| `std.Target.SubSystem` | `zig.Subsystem` with updated field names |
| `std.DynLib` (Windows) | Removed. Use `LoadLibraryExW` / `GetProcAddress` directly. |
| `fs.getAppDataDir` | Removed |
| `std.Options.crypto_always_getrandom` | Use `Io.randomSecure` instead of `Io.random` |
| `std.Options.crypto_fork_safety` | Use `Io.randomSecure` |

---

## 3. std.Io Migration (The Big One)

All I/O now flows through an `std.Io` instance. This is the largest API migration in 0.16.0.

### 3.1 Getting an Io Instance

**In `main`** (preferred — "Juicy Main"):
```zig
// BEFORE
pub fn main() !void {
    // ...
}

// AFTER
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena;
    // ...
}
```

The old `pub fn main() !void` signature still compiles but you won't have access to `Io`.

**Standalone fallback** (when you don't have an Io and aren't in main):
```zig
var threaded: Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

**In tests:**
```zig
const io = std.testing.io;
```

### 3.2 File System Migration

All `std.fs` types and functions moved. Every file/dir operation now takes an `Io` parameter.

**Types:**
```zig
// BEFORE           // AFTER
std.fs.File      → std.Io.File
std.fs.Dir       → std.Io.Dir
```

**Common operations:**
```zig
// BEFORE
file.close();
// AFTER
file.close(io);

// BEFORE
const file = try std.fs.cwd().openFile("data.bin", .{});
// AFTER
const file = try std.Io.Dir.cwd().openFile(io, "data.bin", .{});

// BEFORE
try file.writeAll(data);
// AFTER
try file.writeStreamingAll(io, data);

// BEFORE
const n = try file.read(&buf);
// AFTER
const n = try file.readStreaming(io, &buf);

// BEFORE
try file.seekTo(pos);
// AFTER
try file.reader().seekTo(io, pos);

// BEFORE
const len = try file.getEndPos();
// AFTER
const len = try file.length(io);
```

**Directory operations:**
```zig
// BEFORE                              // AFTER
fs.cwd()                            → std.Io.Dir.cwd()
fs.openDirAbsolute(path, .{})       → std.Io.Dir.openDirAbsolute(io, path, .{})
fs.makeDirAbsolute(path)            → std.Io.Dir.createDirAbsolute(io, path)
fs.deleteFileAbsolute(path)         → std.Io.Dir.deleteFileAbsolute(io, path)
dir.makeDir(name)                   → dir.createDir(io, name)
dir.makePath(path)                  → dir.createDirPath(io, path)
dir.makeOpenDir(path, .{})          → dir.createDirPathOpen(io, path, .{})
dir.setAsCwd()                      → std.process.setCurrentDir(io, dir)
dir.rename(old, new)                → dir.rename(io, src_dir, old, dst_dir, new)
dir.realpath(path, &buf)            → dir.realPathFile(io, path, &buf)
dir.atomicSymLink(target, link)     → dir.symLinkAtomic(io, target, link)
dir.chmod(mode)                     → dir.setPermissions(io, perms)
dir.chown(uid, gid)                 → dir.setOwner(io, uid, gid)
```

**File metadata:**
```zig
// BEFORE                              // AFTER
file.mode()                         → file.stat(io).permissions.toMode()
file.setEndPos(len)                 → file.setLength(io, len)
file.getEndPos()                    → file.length(io)
file.chmod(mode)                    → file.setPermissions(io, perms)
file.chown(uid, gid)               → file.setOwner(io, uid, gid)
file.updateTimes(a, m)             → file.setTimestamps(io, a, m)
```

**File permissions type:**
```zig
// BEFORE                              // AFTER
fs.File.Mode                        → std.Io.File.Permissions
fs.File.default_mode                → std.Io.File.Permissions.default_file
```

**Path utilities:**
```zig
// BEFORE                              // AFTER
fs.path                             → std.Io.Dir.path (deprecated alias exists)
fs.max_path_bytes                   → std.Io.Dir.max_path_bytes
```

**Self-exe:**
```zig
// BEFORE                              // AFTER
fs.openSelfExe()                    → std.process.openExecutable(io)
fs.selfExePathAlloc(alloc)          → std.process.executablePathAlloc(io, alloc)
fs.selfExePath(&buf)                → std.process.executablePath(io, &buf)
```

### 3.3 Process Migration

```zig
// BEFORE
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
try child.spawn();

// AFTER
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
});

// BEFORE
const result = std.process.Child.run(allocator, .{ ... });

// AFTER
const result = std.process.run(allocator, io, .{ ... });

// BEFORE
const err = std.process.execv(arena, argv);

// AFTER
const err = std.process.replace(io, .{ .argv = argv });
```

### 3.4 Entropy / Random

```zig
// BEFORE
var buf: [64]u8 = undefined;
std.crypto.random.bytes(&buf);

// AFTER
var buf: [64]u8 = undefined;
io.random(&buf);

// BEFORE (Random interface)
const rng = std.crypto.random;

// AFTER
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();
```

### 3.5 Time

```zig
// BEFORE                     // AFTER
std.time.Instant           → std.Io.Timestamp
std.time.Timer             → std.Io.Timestamp
std.time.timestamp()       → std.Io.Timestamp.now(io)
```

### 3.6 Networking

All `std.net` APIs now take `Io`. `Io.Evented` does not yet implement networking.

### 3.7 Sync Primitives

All sync primitives now integrate with `Io` for proper cancelation and evented I/O support. See section 2.5 for the mapping.

---

## 4. Build System Changes

### 4.1 Local Package Overrides

You can now override any dependency with a local path for development:

```zig
// In build.zig
const dep = b.dependency("some_package", .{});
// Override at command line:
// zig build --override some_package=/path/to/local/checkout
```

### 4.2 Project-Local Package Fetching

Packages can now be fetched into a project-local directory instead of the global cache.

### 4.3 Unit Test Timeouts

Tests can now have timeouts, preventing infinite loops from hanging CI:

```
zig test --timeout 30000  // 30 seconds
```

### 4.4 New CLI Flags

- `--error-style` — controls error output formatting
- `--multiline-errors` — enables multi-line error messages

### 4.5 Temporary Files API

New build system API for creating temporary files during build steps.

---

## 5. Compiler and Toolchain Notes

### 5.1 LLVM 21

Zig 0.16.0 ships with LLVM 21.

**CRITICAL: Loop vectorization is DISABLED** due to an upstream LLVM regression. This affects release-mode performance for tight loops that previously auto-vectorized. If you have performance-critical inner loops (matrix math, SIMD-friendly data processing), verify they still perform well. Consider hand-vectorizing with explicit `@Vector` types if needed.

### 5.2 Self-Hosted Backends

- **x86_64 backend**: Default for debug mode on x86_64 (since 0.15.x), continued improvements.
- **aarch64 backend**: Major progress, approaching default-ready status.
- **WebAssembly backend**: Improvements to codegen.

### 5.3 New ELF Linker

A new ELF linker implementation ships in 0.16.0. Should be transparent but may surface edge cases in freestanding/baremetal linking.

### 5.4 Updated System Libraries

- musl 1.2.5
- glibc 2.43
- Linux 6.19 headers
- macOS 26.4 headers
- FreeBSD 15.0 libc
- WASI libc updates
- MinGW-w64 updates

### 5.5 Fuzzer Improvements

- **Smith**: AST-level fuzzer for finding compiler bugs
- **Multiprocess fuzzing**: Run fuzz tests across multiple processes
- **Infinite mode**: Run fuzzing indefinitely
- **Crash dumps**: Better crash reproduction

---

## 6. Proactive Feature Adoption (Suggest When Relevant)

These are NOT migration fixes — they are opportunities to improve code quality by adopting new 0.16.0 features. Suggest these when you see matching patterns in code you're reviewing or writing.

### 6.1 WHEN you see `@floatFromInt` on small integers → suggest removing it

If the integer type has fewer bits of precision than the float's significand, the coercion is now implicit.

```zig
// Suggest changing:
const x: f32 = @floatFromInt(my_u16);
// To:
const x: f32 = my_u16;  // u16 fits losslessly in f32 (24-bit significand)

// Keep explicit for types that DON'T fit:
const y: f32 = @floatFromInt(my_u25);  // 25 bits > 24-bit significand
```

Safe implicit coercions: u1–u24 → f32, u1–u53 → f64, u1–u11 → f16.

### 6.2 WHEN you see `@intFromFloat(@round(...))` → suggest direct conversion

```zig
// Suggest changing:
const px: u32 = @intFromFloat(@round(pos_x));
// To:
const px: u32 = @round(pos_x);
```

Same for `@floor`, `@ceil`, `@trunc`. All four now produce integer results when the result type is an integer.

### 6.3 WHEN you see `@Type(.{ .int = ... })` → suggest `@Int`

```zig
// Suggest changing:
const T = @Type(.{ .int = .{ .signedness = .unsigned, .bits = N } });
// To:
const T = @Int(.unsigned, N);
```

### 6.4 WHEN you see `std.meta.Int` → suggest `@Int`

```zig
// Suggest changing:
const T = std.meta.Int(.unsigned, bit_count);
// To:
const T = @Int(.unsigned, bit_count);
```

### 6.5 WHEN you see `std.meta.Tuple` → suggest `@Tuple`

```zig
// Suggest changing:
const T = std.meta.Tuple(&.{ u32, f64 });
// To:
const T = @Tuple(&.{ u32, f64 });
```

### 6.6 WHEN you see complex `@Type(.{ .@"struct" = ... })` → suggest `@Struct`

Especially when building types with `&@splat(.{})` for default attributes. The new `@Struct` is dramatically more readable for metaprogramming.

### 6.7 WHEN you see `ThreadSafeAllocator` wrapping anything → remove it

`ThreadSafeAllocator` is gone. `ArenaAllocator` is now natively lock-free and thread-safe. Other allocators should be made natively thread-safe rather than wrapped.

```zig
// REMOVE this pattern entirely:
var arena = std.heap.ArenaAllocator.init(backing);
var ts_alloc = std.heap.ThreadSafeAllocator{ .allocator = arena.allocator() };
// Arena is already thread-safe now, just use it directly.
```

### 6.8 WHEN writing a new `pub fn main` → suggest Juicy Main

If the project uses file I/O, networking, timers, or randomness, suggest the new signature:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    // ...
}
```

If the project does NOT need `Io` (e.g., pure computation, GPU-only I/O through C APIs), the old `pub fn main() !void` is fine and avoids unnecessary ceremony.

### 6.9 WHEN writing async/concurrent code → suggest Futures and Groups

For independent operations that can run concurrently:

```zig
var file_future = io.async(loadFile, .{ io, "data.bin" });
defer if (file_future.cancel(io)) |f| f.close(io) else |_| {};

var net_future = io.async(fetchConfig, .{ io, url });
defer if (net_future.cancel(io)) |r| r.deinit() else |_| {};

const file = try file_future.await(io);
const config = try net_future.await(io);
```

For many similar tasks:
```zig
var group: Io.Group = .init;
defer group.cancel(io);
for (items) |item| group.async(io, processItem, .{ io, item });
try group.await(io);
```

### 6.10 WHEN using packed unions in switches or equality → note new capability

Packed structs and packed unions can now be switch prong items and support equality comparisons based on their backing integer. This enables pattern-matching on register values, protocol fields, etc.

### 6.11 WHEN you see decl literals or result types in unusual places → note expanded support

Decl literals and constructs requiring a result type (like `@enumFromInt`) can now be used as switch prong items. Float builtins (`@sqrt`, `@sin`, etc.) now forward result types, so nested conversions work:

```zig
// Now works (0.16.0):
const x: f64 = @sqrt(@floatFromInt(N));
```

### 6.12 WHEN working with comptime type slices → note pointers-to-comptime-only relaxation

Pointers to comptime-only types (like `*comptime_int` or `[]const std.builtin.Type.StructField`) are no longer themselves comptime-only. You can pass `[]const StructField` to runtime functions that only access runtime-typed fields like `.name`.

### 6.13 WHEN you see namespace-only type usage → lazy field analysis helps

If a type is used only as a namespace (accessing decls, not fields), its fields are no longer analyzed. This reduces compilation overhead and binary bloat. Even `*T` doesn't require `T` to be resolved if never dereferenced.

### 6.14 WHEN building cross-platform apps → note Windows NtDll migration

Windows networking no longer depends on ws2_32.dll. The full NtDll migration is complete, reducing DLL dependencies on Windows targets.

### 6.15 WHEN using deflate/zlib → note native deflate compression

`std.compress.deflate` now has compression (not just decompression). Performance is competitive with zlib (~10% faster wall time, ~1% worse ratio at default level). Consider dropping a zlib C dependency.

### 6.16 WHEN testing → note new testing features

- `std.testing.io` provides an `Io` instance for tests
- Unit test timeouts prevent hung tests
- Fuzzer improvements (multiprocess, infinite mode, crash dumps)

---

## 7. Patterns to Watch For

### 7.1 The `io` Parameter Threading Pattern

The most common migration pattern is adding `io` as a parameter throughout call chains. When you see a function that calls any `std.Io` API, it needs to either accept `io: std.Io` as a parameter or obtain one locally.

**Do NOT** sprinkle `Io.Threaded.init_single_threaded` everywhere. Thread the `io` parameter from main down through your call graph, just like you would an `Allocator`.

### 7.2 Error Set Changes

Watch for these renamed errors in `catch` / `switch` blocks:
- `error.RenameAcrossMountPoints` → `error.CrossDevice`
- `error.NotSameFileSystem` → `error.CrossDevice`
- `error.SharingViolation` → `error.FileBusy`
- `error.EnvironmentVariableNotFound` → `error.EnvironmentVariableMissing`

New: `std.Io.Dir.rename` returns `error.DirNotEmpty` rather than `error.PathAlreadyExists`.

### 7.3 Cancelation (Single L)

The Zig project spells it "cancelation" (one L). All APIs use this spelling: `error.Canceled`, `cancel()`, `checkCancel()`, etc.

### 7.4 `Io.failing` for Testing Edge Cases

`Io.failing` simulates a system with no I/O support. Use it to verify your code handles `error.Canceled` and I/O failures gracefully.

---

## 8. Quick Reference: Error Set Renames

| Old (0.15.x) | New (0.16.0) |
|---|---|
| `error.RenameAcrossMountPoints` | `error.CrossDevice` |
| `error.NotSameFileSystem` | `error.CrossDevice` |
| `error.SharingViolation` | `error.FileBusy` |
| `error.EnvironmentVariableNotFound` | `error.EnvironmentVariableMissing` |

---

## 9. Quick Reference: Removed APIs

These are gone with no direct replacement. Restructure code accordingly.

| Removed | Notes |
|---|---|
| `std.SegmentedList` | Use `ArrayList` or custom implementation |
| `std.Io.GenericWriter` | Use `std.Io.Writer` |
| `std.Io.AnyWriter` | Use `std.Io.Writer` |
| `std.Io.GenericReader` | Use `std.Io.Reader` |
| `std.Io.AnyReader` | Use `std.Io.Reader` |
| `std.Io.null_writer` | Removed |
| `std.Io.CountingReader` | Removed |
| `std.Io.FixedBufferStream` | Removed |
| `std.Thread.Pool` | Use `Io.Group` or manual task management |
| `std.Thread.Mutex.Recursive` | Removed |
| `std.once` | Hand-roll or eliminate global state |
| `std.heap.ThreadSafeAllocator` | Anti-pattern. Make allocators natively thread-safe. |
| `std.DynLib` (Windows) | Use `LoadLibraryExW` / `GetProcAddress` directly |
| `std.fs.getAppDataDir` | Removed |
| `std.builtin.subsystem` | Use `zig.Subsystem` |
| Most `std.posix.*` functions | Go higher (`std.Io`) or lower (`std.posix.system`) |
| Most `std.os.windows.*` functions | Go higher (`std.Io`) or lower (direct NT API calls) |
| All `*Z` and `*W` path function variants | Use the platform-agnostic versions |

---

*Document version: 2026-04-16. Based on Zig 0.16.0 official release notes.*
