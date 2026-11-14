const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // nanoui draws the window; the `nullclaw` runtime is driven as a child
    // process (see src/runtime.zig) so the GUI never links the runtime.
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "nullclaw-gui's version") orelse "0.1.0");

    // The runtime as a module: the window links nullclaw's own library and
    // calls into it, rather than spawning a program.
    const runtime_dep = b.dependency("nullclaw", .{
        .target = target,
        .optimize = optimize,
    });
    const runtime_mod = runtime_dep.module("nullclaw");

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
    mod.addImport("nullclaw", runtime_mod);
    const exe = b.addExecutable(.{ .name = "nullclaw-gui", .root_module = mod });
    // A window of its own on Windows, without a console beside it.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the nullclaw desktop GUI").dependOn(&run.step);

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nanoui", .module = nanoui },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    test_module.addImport("nullclaw", runtime_mod);
    const tests = b.addTest(.{ .filters = filters, .root_module = test_module });
    b.step("test", "Run the GUI's tests").dependOn(&b.addRunArtifact(tests).step);

    // Renders the window's screens to PNGs in /tmp/nullclaw-gui-shots, so what
    // the tests assert about can also be looked at.
    const shots = b.addTest(.{ .filters = &.{"screenshots"}, .root_module = test_module });
    b.step("shots", "Render the window's screens to PNGs").dependOn(&b.addRunArtifact(shots).step);
}
