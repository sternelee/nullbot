const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // nanoui draws the window; the `nullclaw` runtime is driven as a child
    // process (see src/runtime.zig) so the GUI never links the runtime.
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "nullclaw-gui's version") orelse "0.1.0");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nanoui", .module = nanoui },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const exe = b.addExecutable(.{ .name = "nullclaw-gui", .root_module = mod });
    // A window of its own on Windows, without a console beside it.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    // The runtime the window drives is built from the repository above and
    // installed beside `nullclaw-gui`, so `zig build` in this directory
    // produces a window with its own nullclaw. Without this the window has no
    // runtime to run: every page would spawn a missing program and report
    // FileNotFound.
    const runtime_dep = b.dependency("nullclaw", .{
        .target = target,
        .optimize = optimize,
    });
    const runtime = runtime_dep.artifact("nullclaw");
    b.installArtifact(runtime);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    // `zig build run` executes the cached binary in .zig-cache, whose
    // directory holds no `nullclaw`: the window would resolve its runtime to
    // a bare PATH name and fail to start. Point the run at the installed
    // runtime so the gateway and every page find it.
    run.step.dependOn(b.getInstallStep());
    run.setEnvironmentVariable("NULLCLAW_BIN", "zig-out/bin/nullclaw");
    b.step("run", "Run the nullclaw desktop GUI").dependOn(&run.step);

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    const tests = b.addTest(.{ .filters = filters, .root_module = test_module });
    b.step("test", "Run the GUI's tests").dependOn(&b.addRunArtifact(tests).step);

    // Renders the window's screens to PNGs in /tmp/nullclaw-gui-shots, so what
    // the tests assert about can also be looked at.
    const shots = b.addTest(.{ .filters = &.{"screenshots"}, .root_module = test_module });
    b.step("shots", "Render the window's screens to PNGs").dependOn(&b.addRunArtifact(shots).step);
}
