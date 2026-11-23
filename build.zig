const std = @import("std");

/// The release binary's target: Apple silicon Macs (the owner's answer, docs/PLAN.md M8).
const release_target_query: std.Target.Query = .{ .cpu_arch = .aarch64, .os_tag = .macos };
const release_name = "teams-zig-aarch64-macos";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .whitelist = null, .default_target = .{} });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = null });

    const teams = b.addModule("teams", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkMacos(b, teams, target);
    const exe = addExe(b, teams, target, optimize);
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

    const release_target = b.resolveTargetQuery(release_target_query);
    const release_teams = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = release_target,
        .optimize = .ReleaseSafe,
    });
    linkMacos(b, release_teams, release_target);
    const release_exe = addExe(b, release_teams, release_target, .ReleaseSafe);
    const install_release = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
        .dest_sub_path = release_name,
    });
    const release_step = b.step("release", "Build zig-out/release/" ++ release_name);
    release_step.dependOn(&install_release.step);
}

fn addExe(
    b: *std.Build,
    teams: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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
    // The MCP server's `serverInfo` names this version.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", build_options);
    return exe;
}

/// Links the Apple frameworks teams-zig uses. For a named target, even the host's own, Zig
/// doesn't look for the macOS SDK, so its framework and library folders are added from
/// `xcrun` (docs/PLAN.md M8, facts checked on this Mac).
fn linkMacos(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    // Without an SDK this adds nothing, and only a build for that target fails, at the link.
    if (!target.query.isNativeOs()) {
        const result = &target.result;
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, result)) |sdk| {
            const frameworks = b.pathJoin(&.{ sdk, "System/Library/Frameworks" });
            module.addSystemFrameworkPath(.{ .cwd_relative = frameworks });
            module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    module.linkFramework("CoreFoundation", .{ .needed = false, .weak = false });
    module.linkFramework("Security", .{ .needed = false, .weak = false });
}
