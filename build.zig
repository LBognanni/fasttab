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

    // Add raylib include and library paths
    exe.addIncludePath(b.path("lib/raylib-5.5_linux_amd64/include"));
    exe.addLibraryPath(b.path("lib/raylib-5.5_linux_amd64/lib"));

    // Add stb implementation with SIMD optimizations
    exe.addCSourceFile(.{
        .file = b.path("src/stb_impl.c"),
        .flags = &[_][]const u8{ "-std=c99", "-O3", "-msse4.1" },
    });

    // Link XCB libraries
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-composite");
    exe.linkSystemLibrary("xcb-image");

    // Link raylib and its dependencies
    exe.linkSystemLibrary("raylib");
    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("pthread");
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("rt");
    exe.linkSystemLibrary("X11");

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
    exe_unit_tests.addIncludePath(b.path("lib/raylib-5.5_linux_amd64/include"));
    exe_unit_tests.addLibraryPath(b.path("lib/raylib-5.5_linux_amd64/lib"));
    exe_unit_tests.linkSystemLibrary("xcb");
    exe_unit_tests.linkSystemLibrary("xcb-composite");
    exe_unit_tests.linkSystemLibrary("xcb-image");
    exe_unit_tests.linkSystemLibrary("raylib");
    exe_unit_tests.linkSystemLibrary("GL");
    exe_unit_tests.linkSystemLibrary("m");
    exe_unit_tests.linkSystemLibrary("pthread");
    exe_unit_tests.linkSystemLibrary("dl");
    exe_unit_tests.linkSystemLibrary("rt");
    exe_unit_tests.linkSystemLibrary("X11");
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Pure logic unit tests (no X11/raylib dependencies)
    // Each test file needs access to the modules it imports

    // Thumbnail test
    const thumbnail_test = b.addTest(.{
        .root_source_file = b.path("src/tests/thumbnail_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    thumbnail_test.root_module.addImport("color", b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
    }));
    test_step.dependOn(&b.addRunArtifact(thumbnail_test).step);

    // UI/Layout test
    const ui_test = b.addTest(.{
        .root_source_file = b.path("src/tests/ui_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_test.root_module.addImport("layout", b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
    }));
    test_step.dependOn(&b.addRunArtifact(ui_test).step);

    // Worker/Queue test
    const worker_test = b.addTest(.{
        .root_source_file = b.path("src/tests/worker_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    worker_test.root_module.addImport("queue", b.createModule(.{
        .root_source_file = b.path("src/queue.zig"),
    }));
    test_step.dependOn(&b.addRunArtifact(worker_test).step);

    // Navigation test
    const navigation_test = b.addTest(.{
        .root_source_file = b.path("src/tests/navigation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    navigation_test.root_module.addImport("navigation", b.createModule(.{
        .root_source_file = b.path("src/navigation.zig"),
    }));
    test_step.dependOn(&b.addRunArtifact(navigation_test).step);
}
