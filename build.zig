const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .whitelist = null, .default_target = .{} });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = null });

    const teams = b.addModule("teams", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    teams.linkFramework("CoreFoundation", .{ .needed = false, .weak = false });
    teams.linkFramework("Security", .{ .needed = false, .weak = false });

    const exe = b.addExecutable(.{
        .name = "teams-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "teams", .module = teams },
            },
        }),
    });
    b.installArtifact(exe);

    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    const run_step = b.step("run", "Run teams-zig");
    run_step.dependOn(&run_command.step);

    const run_teams_tests = b.addRunArtifact(b.addTest(.{ .root_module = teams }));
    const run_exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_teams_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
