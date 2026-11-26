const std = @import("std");
const generate = @import("fuzz_generate.zig");
const checker = @import("fuzz_check.zig");
const assert = @import("assert.zig").assert;

const iterations_max: u32 = 10000000;
const Options = struct {
    seed: u64 = 1,
    iterations: u32 = 256,
    seconds: u16 = 0,
    replay: ?[]const u8 = null,
    probe: ?[]const u8 = null,
};
const Context = struct {
    io: std.Io,
    options: Options,
    number: u32 = 0,
    case: generate.Case = .{},
    work: checker.Workspace = undefined,
    counters: checker.Counters = .{},
};
var active: ?*Context = null;
pub const panic = std.debug.FullPanic(panic_handler);

fn panic_handler(message: []const u8, address: ?usize) noreturn {
    _ = address;
    if (active) |context| {
        save_failure(context, message) catch |err| {
            std.debug.print("saving panic failed: {s}\n", .{@errorName(err)});
        };
    }
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parse_options(args);
    const context = try init.gpa.create(Context);
    defer init.gpa.destroy(context);
    context.* = .{ .io = init.io, .options = options };
    active = context;
    defer active = null;
    std.debug.print("fuzz seed={d} iterations={d} seconds={d}\n", .{
        options.seed, options.iterations, options.seconds,
    });
    const start = std.Io.Clock.awake.now(init.io);
    const count = try run(context, start);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    print_counters(&context.counters, count, elapsed);
    if (options.replay == null and options.probe == null)
        try checker.verify_coverage(&context.counters);
    std.debug.print("fuzz: PASS\n", .{});
    assert(count > 0);
    assert(count <= iterations_max);
}

fn parse_options(args: []const []const u8) !Options {
    assert(args.len > 0);
    var options = Options{};
    var index: u32 = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingArgument;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, name, "--iterations")) {
            options.iterations = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            options.seconds = try std.fmt.parseInt(u16, value, 0);
            if (options.seconds == 0 or options.seconds > 3600) return error.TimeLimit;
        } else if (std.mem.eql(u8, name, "--replay")) {
            options.replay = value;
        } else if (std.mem.eql(u8, name, "--probe")) {
            options.probe = value;
        } else return error.UnknownArgument;
    }
    if (options.seconds > 0) options.iterations = iterations_max;
    if (options.replay != null) options.iterations = 1;
    if (options.probe != null) options.iterations = 1;
    if (options.iterations == 0 or options.iterations > iterations_max) return error.IterationLimit;
    assert(options.iterations <= iterations_max);
    return options;
}

fn run(context: *Context, start: std.Io.Timestamp) !u32 {
    assert(context.number == 0);
    for (0..context.options.iterations) |number| {
        context.number = @intCast(number);
        if (context.options.replay) |path| {
            try load_replay(context, path);
        } else if (context.options.probe) |name| {
            try generate.generate_probe(&context.case, name);
        } else try generate.generate(&context.case, context.options.seed, @intCast(number));
        assert(context.case.count <= context.case.messages.len);
        assert((context.case.expected_error != null) == (context.case.outcome == .rejected));
        checker.check(&context.case, &context.work, context.io, &context.counters) catch |err| {
            try save_failure(context, @errorName(err));
            return err;
        };
        if (context.options.seconds > 0 and number % 64 == 63) {
            const elapsed = start.durationTo(std.Io.Clock.awake.now(context.io)).toSeconds();
            if (elapsed >= context.options.seconds) return @intCast(number + 1);
        }
    }
    assert(context.options.iterations > 0);
    return context.options.iterations;
}

fn save_failure(context: *const Context, reason: []const u8) !void {
    assert(context.case.length <= generate.input_max);
    if (context.options.replay) |path| {
        std.debug.print("FAIL replay={s} reason={s}\n", .{ path, reason });
        return;
    }
    var name_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buffer, "zig-out/fuzz/seed-{d}-case-{d}.bin", .{
        context.options.seed, context.number,
    });
    std.debug.print("FAIL seed={d} case={d} class={d} reason={s} replay={s}\n", .{
        context.options.seed, context.number, context.case.class, reason, path,
    });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(context.io, "zig-out/fuzz");
    try cwd.writeFile(context.io, .{
        .sub_path = path,
        .data = context.case.bytes[0..context.case.length],
    });
    var meta_name: [176]u8 = undefined;
    const metadata = try std.fmt.bufPrint(&meta_name, "{s}.meta", .{path});
    var content: [80]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&content, "{d} {d} {s}\n", .{
        context.options.seed, context.number, context.options.probe orelse "generated",
    });
    try cwd.writeFile(context.io, .{ .sub_path = metadata, .data = bytes });
    assert(path.len < name_buffer.len);
}

fn load_replay(context: *Context, path: []const u8) !void {
    assert(context.options.replay != null);
    var meta_name: [4096]u8 = undefined;
    const metadata = try std.fmt.bufPrint(&meta_name, "{s}.meta", .{path});
    var content: [80]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFile(context.io, metadata, &content);
    var tokens = std.mem.tokenizeAny(u8, bytes, " \r\n");
    context.options.seed = try std.fmt.parseInt(
        u64,
        tokens.next() orelse return error.InvalidReplay,
        10,
    );
    context.number = try std.fmt.parseInt(u32, tokens.next() orelse return error.InvalidReplay, 10);
    const profile = tokens.next() orelse return error.InvalidReplay;
    if (tokens.next() != null or context.number >= iterations_max) return error.InvalidReplay;
    if (std.mem.eql(u8, profile, "generated")) {
        try generate.generate(&context.case, context.options.seed, context.number);
    } else {
        try generate.generate_probe(&context.case, profile);
    }
    const input = try cwd.readFile(context.io, path, &context.case.bytes);
    if (input.len != context.case.length) return error.ReplayLengthChanged;
    assert(context.number < iterations_max);
}

fn print_counters(counters: *const checker.Counters, count: u32, elapsed_ns: i96) void {
    assert(count > 0);
    assert(counters.accepted + counters.rejected + counters.incomplete == count);
    inline for (comptime std.meta.fieldNames(checker.Counters)) |name| {
        std.debug.print("{s}={any}\n", .{ name, @field(counters, name) });
    }
    for (checker.error_names, counters.errors) |name, value| {
        std.debug.print("error.{s}={d}\n", .{ name, value });
    }
    const seconds = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / 1000000000;
    std.debug.print("cases={d} seconds={d:.3} cases_per_second={d:.0}\n", .{
        count, seconds, @as(f64, @floatFromInt(count)) / seconds,
    });
}
