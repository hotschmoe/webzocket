const std = @import("std");
const assert = @import("assert").assert;
const wire = @import("sim_wire.zig");
const world_module = @import("sim_world.zig");
const adversary_module = @import("sim_adversary.zig");
const corpus_module = @import("sim_corpus.zig");

const World = world_module.World;
const Adversary = adversary_module.Adversary;
const Corpus = corpus_module.Corpus;
const seeds_max: u32 = 1 << 20;
const corpus_cases: u32 = 200;
const honest_percent: u64 = 70;
const corpus_session: u32 = std.math.maxInt(u32);
const lines_first: u32 = 16;
const lines_every: u32 = 256;

const Options = struct {
    seed: u64 = 1,
    steps: u64 = 20_000,
    seeds: u32 = 1,
    seconds: u16 = 0,
    replay: ?[]const u8 = null,
};

const Context = struct {
    io: std.Io,
    options: Options,
    world: World,
    adversary: Adversary,
    corpus: Corpus,
    session: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parse_options(args);
    assert(options.seeds >= 1);
    const context = try init.gpa.create(Context);
    defer init.gpa.destroy(context);
    context.io = init.io;
    context.options = options;
    std.debug.print("sim seed={d} steps={d} seeds={d} seconds={d}\n", .{
        options.seed, options.steps, options.seeds, options.seconds,
    });
    const start = std.Io.Clock.awake.now(init.io);
    const count = if (options.replay) |path|
        try run_replay(context, path)
    else
        try run(context, start);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    print_totals(context, count, elapsed);
    std.debug.print("sim: PASS\n", .{});
    assert(count > 0);
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
        } else if (std.mem.eql(u8, name, "--steps")) {
            options.steps = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            options.seeds = try std.fmt.parseInt(u32, value, 0);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            options.seconds = try std.fmt.parseInt(u16, value, 0);
        } else if (std.mem.eql(u8, name, "--replay")) {
            options.replay = value;
        } else return error.UnknownArgument;
    }
    if (options.seeds == 0 or options.seeds > seeds_max) return error.BadCount;
    if (options.steps == 0) return error.BadCount;
    if (options.seconds > 0) options.seeds = seeds_max;
    assert(options.seeds <= seeds_max and options.steps > 0);
    return options;
}

fn init_state(context: *Context) void {
    context.world.init();
    context.adversary.init();
    context.corpus.init();
    assert(context.world.totals.sessions == 0);
    assert(context.adversary.totals.sessions == 0);
}

fn run(context: *Context, start: std.Io.Timestamp) !u32 {
    const options = context.options;
    assert(options.seeds >= 1 and options.seeds <= seeds_max);
    init_state(context);
    for (0..options.seeds) |number| {
        const seed = options.seed +% number;
        const digest = run_seed(context, seed) catch |err| {
            try save_failure(context, seed);
            return err;
        };
        if (number < lines_first or number % lines_every == 0) {
            std.debug.print("seed={d} trace=0x{x:0>16}\n", .{ seed, digest });
        }
        if (options.seconds == 0) continue;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(context.io)).toSeconds();
        if (elapsed >= options.seconds) return @intCast(number + 1);
    }
    assert(options.seconds == 0);
    return options.seeds;
}

fn run_seed(context: *Context, seed: u64) !u64 {
    assert(context.options.steps > 0);
    const first = try run_seed_once(context, seed, 0xaa);
    const kept_world = context.world.totals;
    const kept_adversary = context.adversary.totals;
    const kept_corpus = context.corpus.rows;
    const second = try run_seed_once(context, seed, 0x55);
    context.world.totals = kept_world;
    context.adversary.totals = kept_adversary;
    context.corpus.rows = kept_corpus;
    if (first != second) {
        const report = &context.world.report;
        _ = report.fail(.determinism, "seed {d} gave two different traces", .{seed}) catch {};
        return error.Violation;
    }
    assert(first == second);
    return first;
}

fn run_seed_once(context: *Context, seed: u64, poison: u8) !u64 {
    assert(poison == 0xaa or poison == 0x55);
    const world = &context.world;
    const adversary = &context.adversary;
    const corpus = &context.corpus;
    const saved = .{ world.totals, world.report, adversary.totals, corpus.rows };
    @memset(std.mem.asBytes(world), poison);
    @memset(std.mem.asBytes(adversary), poison);
    @memset(std.mem.asBytes(corpus), poison);
    init_state(context);
    world.totals = saved[0];
    world.report = saved[1];
    adversary.totals = saved[2];
    corpus.rows = saved[3];
    var chain = std.hash.Wyhash.init(seed);
    context.session = corpus_session;
    try corpus.run(&world.report, seed, corpus_cases);
    chain.update(std.mem.asBytes(&corpus.cases));
    var used: u64 = 0;
    var session: u32 = 0;
    while (used < context.options.steps) : (session += 1) {
        const before = world.totals.steps + adversary.totals.steps;
        const digest = try run_session(context, seed, session);
        used += @max(world.totals.steps + adversary.totals.steps - before, 1);
        chain.update(std.mem.asBytes(&digest));
        if (session == corpus_session - 1) return error.SessionLimit;
    }
    assert(used >= context.options.steps);
    return chain.final();
}

fn run_session(context: *Context, seed: u64, session: u32) !u64 {
    assert(session != corpus_session);
    context.session = session;
    if (wire.mix64(seed ^ 0x5e55, session) % 100 < honest_percent) {
        try context.world.run_session(seed, session);
        assert(context.world.totals.sessions > 0);
        return context.world.digest();
    }
    const digest = try context.adversary.run_session(&context.world.report, seed, session);
    assert(context.adversary.totals.sessions > 0);
    return digest;
}

fn run_replay(context: *Context, path: []const u8) !u32 {
    assert(path.len > 0);
    var content: [64]u8 = undefined;
    const bytes = try std.Io.Dir.cwd().readFile(context.io, path, &content);
    var tokens = std.mem.tokenizeAny(u8, bytes, " \r\n");
    const seed = try std.fmt.parseInt(u64, tokens.next() orelse return error.InvalidReplay, 10);
    const second = tokens.next() orelse return error.InvalidReplay;
    if (tokens.next() != null) return error.InvalidReplay;
    init_state(context);
    const only_corpus = std.mem.eql(u8, second, "corpus");
    assert(second.len > 0);
    const session = if (only_corpus) corpus_session else try std.fmt.parseInt(u32, second, 10);
    context.session = session;
    if (only_corpus) {
        context.corpus.run(&context.world.report, seed, corpus_cases) catch |err| {
            try report_failure(context, seed);
            return err;
        };
    } else {
        _ = run_session(context, seed, session) catch |err| {
            try report_failure(context, seed);
            return err;
        };
    }
    std.debug.print("replay seed={d} session={s}: PASS\n", .{ seed, second });
    return 1;
}

fn save_failure(context: *Context, seed: u64) !void {
    assert(context.world.report.checker != null);
    try report_failure(context, seed);
    var name: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&name, "zig-out/sim/seed-{d}-session-{d}.txt", .{
        seed, context.session,
    });
    var content: [64]u8 = undefined;
    const text = if (context.session == corpus_session)
        try std.fmt.bufPrint(&content, "{d} corpus\n", .{seed})
    else
        try std.fmt.bufPrint(&content, "{d} {d}\n", .{ seed, context.session });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(context.io, "zig-out/sim");
    try cwd.writeFile(context.io, .{ .sub_path = path, .data = text });
    std.debug.print("replay with: zig build sim -- --replay {s}\n", .{path});
    assert(path.len < name.len);
}

fn report_failure(context: *Context, seed: u64) !void {
    const report = &context.world.report;
    assert(report.length <= report.text.len);
    assert(report.checker != null);
    std.debug.print("FAIL seed={d} session={d} checker={s} detail={s}\n", .{
        seed,
        if (context.session == corpus_session) 0 else context.session,
        if (report.checker) |checker| @tagName(checker) else "none",
        report.message(),
    });
}

fn print_totals(context: *const Context, count: u32, elapsed_ns: i96) void {
    const totals = &context.world.totals;
    assert(count > 0);
    assert(totals.closes <= totals.sessions * 2);
    std.debug.print("sessions={d} steps={d} messages={d} bytes={d}\n", .{
        totals.sessions, totals.steps, totals.messages, totals.bytes,
    });
    std.debug.print("pings={d} pongs={d} coalesced={d} closes={d} refused={d}\n", .{
        totals.pings, totals.pongs, totals.coalesced, totals.closes, totals.refused,
    });
    std.debug.print("old_reader_messages={d} scenarios graceful={d} cut={d} ", .{
        totals.old_messages, totals.scenarios[0], totals.scenarios[1],
    });
    std.debug.print("stall_handshake={d} stall_close={d}\n", .{
        totals.scenarios[2], totals.scenarios[3],
    });
    const seconds = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / 1000000000;
    std.debug.print("seeds={d} seconds={d:.3}\n", .{ count, seconds });
    print_adversary(&context.adversary.totals);
    print_corpus(&context.corpus);
}

fn print_adversary(totals: *const adversary_module.Totals) void {
    var covered: u32 = 0;
    for (totals.classes) |count| covered += @intFromBool(count > 0);
    std.debug.print("adversary sessions={d} rejected={d} accepted={d} ", .{
        totals.sessions, totals.rejected, totals.accepted,
    });
    std.debug.print("truncated={d} limit_hits={d} classes={d}/{d}\n", .{
        totals.truncated, totals.limit_hits, covered, adversary_module.class_count,
    });
    assert(covered <= adversary_module.class_count);
    assert(totals.rejected + totals.accepted + totals.truncated == totals.sessions);
}

fn print_corpus(corpus: *const Corpus) void {
    var cases: u64 = 0;
    var stricter: u64 = 0;
    var looser: u64 = 0;
    for (corpus.rows) |row| {
        cases += row.cases;
        stricter += row.stricter;
        looser += row.looser;
    }
    std.debug.print("old generator cases={d} conn_stricter={d} conn_looser={d}\n", .{
        cases, stricter, looser,
    });
    for (corpus.rows, 0..) |row, class| {
        if (row.stricter == 0) continue;
        const name = std.mem.sliceTo(&row.last_error, 0);
        std.debug.print("  class {d}: cases={d} old_accept={d} conn_accept={d} ", .{
            class, row.cases, row.old_accept, row.conn_accept,
        });
        std.debug.print("conn_stricter={d} last={s}\n", .{ row.stricter, name });
    }
    assert(cases > 0 or looser == 0);
    assert(looser <= cases and stricter <= cases);
}
