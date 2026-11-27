const std = @import("std");
const assert = @import("src/assert.zig").assert;

/// Single source of truth: build.zig.zon `.version` (docs/VERSIONING.md). `-Dversion-meta=<str>` appends "+<str>".
fn versionString(b: *std.Build) []const u8 {
    const base: []const u8 = @import("build.zig.zon").version;
    _ = std.SemanticVersion.parse(base) catch @panic("build.zig.zon .version is not valid semver");
    const meta = b.option([]const u8, "version-meta", "Semver build metadata appended as +<meta>") orelse return base;
    return b.fmt("{s}+{s}", .{ base, meta });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_module = b.addModule("webzocket", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/websocket.zig"),
        .link_libc = true,
    });
    const assert_module = b.createModule(.{ .root_source_file = b.path("src/assert.zig") });
    websocket_module.addImport("assert", assert_module);
    if (target.result.os.tag == .windows) websocket_module.linkSystemLibrary("ws2_32", .{});

    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_module.addOptions("build", options);
    }

    {
        const options = b.addOptions();
        options.addOption([]const u8, "version", versionString(b));
        options.addOption([]const u8, "manifest_version", @import("build.zig.zon").version);
        websocket_module.addOptions("build_options", options);
    }

    if (b.pkg_hash.len == 0) add_checks(b, websocket_module, assert_module);
}

fn add_checks(
    b: *std.Build,
    websocket_module: *std.Build.Module,
    assert_module: *std.Build.Module,
) void {
    const tidy = add_tidy(b);
    const fuzz_short = add_fuzz(b, websocket_module, assert_module);
    fuzz_short.step.dependOn(&tidy.step);
    const sim_short = add_sim(b, websocket_module, assert_module);
    sim_short.step.dependOn(&tidy.step);
    {
        const tests = b.addTest(.{
            .root_module = websocket_module,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", force_blocking);
        tests.root_module.addOptions("build", options);

        const run_test = b.addRunArtifact(tests);
        run_test.step.dependOn(&fuzz_short.step);
        run_test.step.dependOn(&sim_short.step);

        const test_step = b.step("test", "Tidy, short seeded protocol run, existing tests");
        test_step.dependOn(&run_test.step);
    }
}

fn add_tidy(b: *std.Build) *std.Build.Step.Run {
    const module = b.createModule(.{
        .root_source_file = b.path("tools/tidy.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    module.addImport("assert", b.createModule(.{
        .root_source_file = b.path("src/assert.zig"),
    }));
    const executable = b.addExecutable(.{ .name = "tidy", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("tidy", "Measure and enforce TigerStyle ratchets").dependOn(&run.step);
    return run;
}

fn add_fuzz(
    b: *std.Build,
    websocket_module: *std.Build.Module,
    assert_module: *std.Build.Module,
) *std.Build.Step.Run {
    assert(websocket_module.root_source_file != null);
    const module = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    module.addImport("webzocket", websocket_module);
    module.addImport("assert", assert_module);
    const executable = b.addExecutable(.{ .name = "fuzz", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("fuzz", "Seeded byte protocol oracle").dependOn(&run.step);
    const short = b.addRunArtifact(executable);
    short.addArgs(&.{ "--seed", "1", "--iterations", "128" });
    const heavy = b.addRunArtifact(executable);
    heavy.addArgs(&.{ "--seed", "72831", "--seconds", "30" });
    b.step("fuzz-heavy", "Background protocol budget").dependOn(&heavy.step);
    b.step("test-heavy", "Non-blocking background gate").dependOn(&heavy.step);
    return short;
}

fn add_sim(
    b: *std.Build,
    websocket_module: *std.Build.Module,
    assert_module: *std.Build.Module,
) *std.Build.Step.Run {
    assert(websocket_module.root_source_file != null);
    assert(assert_module.root_source_file != null);
    const module = b.createModule(.{
        .root_source_file = b.path("src/sim.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    module.addImport("webzocket", websocket_module);
    module.addImport("assert", assert_module);
    const executable = b.addExecutable(.{ .name = "sim", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("sim", "Seeded connection simulator").dependOn(&run.step);
    const short = b.addRunArtifact(executable);
    short.addArgs(&.{ "--seed", "1", "--steps", "3000", "--seeds", "2" });
    const heavy = b.addRunArtifact(executable);
    heavy.addArgs(&.{ "--seed", "90210", "--steps", "200000", "--seconds", "30" });
    b.step("sim-heavy", "Background simulator budget").dependOn(&heavy.step);
    if (b.top_level_steps.get("test-heavy")) |top| top.step.dependOn(&heavy.step);
    return short;
}
