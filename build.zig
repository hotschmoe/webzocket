const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_module = b.addModule("webzocket", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/websocket.zig"),
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        websocket_module.linkSystemLibrary("ws2_32", .{});
    }

    {
        // run tests
        const tests = b.addTest(.{
            .root_module = websocket_module,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });

        const run_test = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }
}
