const std = @import("std");

const RenderBackend = enum {
    gl,
    gles,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend_opt = b.option([]const u8, "render-backend", "Selected renderer backend") orelse "gl";
    const android_ndk_sysroot = b.option([]const u8, "android-ndk-sysroot", "Android NDK sysroot path for GLES linking") orelse "";
    const selected_backend: RenderBackend = if (std.mem.eql(u8, backend_opt, "gl"))
        .gl
    else if (std.mem.eql(u8, backend_opt, "gles"))
        .gles
    else
        std.debug.panic("unsupported renderer backend: {s}", .{backend_opt});

    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_lib = freetype_dep.artifact("freetype");
    const harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });
    const harfbuzz_lib = harfbuzz_dep.artifact("harfbuzz");
    if (selected_backend == .gles and target.result.abi == .android and android_ndk_sysroot.len > 0) {
        freetype_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{android_ndk_sysroot}) });
        freetype_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/aarch64-linux-android", .{android_ndk_sysroot}) });
    }

    const build_options = b.addOptions();
    build_options.addOption(RenderBackend, "render_backend", selected_backend);

    const mod = b.addModule("howl_render", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("howl_render", mod);
    mod.addImport("howl_render_core", mod);
    mod.addImport("build_options", build_options.createModule());
    mod.linkLibrary(freetype_lib);
    mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    mod.linkLibrary(harfbuzz_lib);
    mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        mod.linkSystemLibrary("GLESv2", .{});
    }

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = mod,
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_unit_step);
}
