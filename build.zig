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

    // Add raylib include path and static library
    exe.addIncludePath(b.path("lib/raylib-5.5_linux_amd64/include"));

    // Note: STB implementations (stb_image, stb_image_resize2) are already
    // compiled into libraylib.a, so we do NOT compile stb_impl.c separately.
    // The headers in include/ are used only for type/function declarations.

    // Link XCB libraries
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-composite");
    exe.linkSystemLibrary("xcb-image");
    exe.linkSystemLibrary("xcb-keysyms");
    exe.linkSystemLibrary("xcb-damage");

    // Link raylib (static) and its dependencies
    exe.addObjectFile(b.path("lib/raylib-5.5_linux_amd64/lib/libraylib.a"));
    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("pthread");
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("rt");
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("X11-xcb"); // Xlib-XCB bridge functions

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
    exe_unit_tests.linkSystemLibrary("xcb");
    exe_unit_tests.linkSystemLibrary("xcb-composite");
    exe_unit_tests.linkSystemLibrary("xcb-image");
    exe_unit_tests.linkSystemLibrary("xcb-keysyms");
    exe_unit_tests.linkSystemLibrary("xcb-damage");
    exe_unit_tests.addObjectFile(b.path("lib/raylib-5.5_linux_amd64/lib/libraylib.a"));
    exe_unit_tests.linkSystemLibrary("GL");
    exe_unit_tests.linkSystemLibrary("m");
    exe_unit_tests.linkSystemLibrary("pthread");
    exe_unit_tests.linkSystemLibrary("dl");
    exe_unit_tests.linkSystemLibrary("rt");
    exe_unit_tests.linkSystemLibrary("X11");
    exe_unit_tests.linkSystemLibrary("X11-xcb");
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Pure logic unit tests (no X11/raylib dependencies)
    // Each test file needs access to the modules it imports

    // UI test (requires C dependencies for DisplayWindow)
    const ui_test = b.addTest(.{
        .root_source_file = b.path("src/tests/ui_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_module.addIncludePath(b.path("include"));
    ui_module.addIncludePath(b.path("lib/raylib-5.5_linux_amd64/include"));
    ui_test.root_module.addImport("ui", ui_module);
    ui_test.addIncludePath(b.path("include"));
    ui_test.linkSystemLibrary("xcb");
    ui_test.linkSystemLibrary("xcb-composite");
    ui_test.linkSystemLibrary("xcb-image");
    ui_test.linkSystemLibrary("xcb-keysyms");
    ui_test.linkSystemLibrary("xcb-damage");
    ui_test.addObjectFile(b.path("lib/raylib-5.5_linux_amd64/lib/libraylib.a"));
    ui_test.linkSystemLibrary("GL");
    ui_test.linkSystemLibrary("m");
    ui_test.linkSystemLibrary("pthread");
    ui_test.linkSystemLibrary("dl");
    ui_test.linkSystemLibrary("rt");
    ui_test.linkSystemLibrary("X11");
    ui_test.linkSystemLibrary("X11-xcb");
    ui_test.linkLibC();
    test_step.dependOn(&b.addRunArtifact(ui_test).step);

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
