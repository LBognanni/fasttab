const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fasttab",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add include path for stb headers
    exe.addIncludePath(b.path("include"));

    // Add stb implementation
    exe.addCSourceFile(.{
        .file = b.path("src/stb_impl.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });

    // Link XCB libraries
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-composite");
    exe.linkSystemLibrary("xcb-image");
    exe.linkLibC();

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run fasttab");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.addIncludePath(b.path("include"));
    exe_unit_tests.linkSystemLibrary("xcb");
    exe_unit_tests.linkSystemLibrary("xcb-composite");
    exe_unit_tests.linkSystemLibrary("xcb-image");
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
