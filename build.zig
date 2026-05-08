const std = @import("std");

const RenderBackend = enum {
    gl,
    gles,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const perf_optimize: std.builtin.OptimizeMode = .ReleaseFast;
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
        .root_source_file = b.path("src/howl_render.zig"),
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

    const perf_freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = perf_optimize,
    });
    const perf_freetype_lib = perf_freetype_dep.artifact("freetype");
    const perf_harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = perf_optimize,
    });
    const perf_harfbuzz_lib = perf_harfbuzz_dep.artifact("harfbuzz");
    if (selected_backend == .gles and target.result.abi == .android and android_ndk_sysroot.len > 0) {
        perf_freetype_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{android_ndk_sysroot}) });
        perf_freetype_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/aarch64-linux-android", .{android_ndk_sysroot}) });
    }
    const perf_mod = b.addModule("howl_render_perf", .{
        .root_source_file = b.path("src/howl_render.zig"),
        .target = target,
        .optimize = perf_optimize,
    });
    perf_mod.addImport("howl_render", perf_mod);
    perf_mod.addImport("howl_render_core", perf_mod);
    perf_mod.addImport("build_options", build_options.createModule());
    perf_mod.linkLibrary(perf_freetype_lib);
    perf_mod.addIncludePath(perf_freetype_lib.getEmittedIncludeTree());
    perf_mod.linkLibrary(perf_harfbuzz_lib);
    perf_mod.addIncludePath(perf_harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        perf_mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        perf_mod.linkSystemLibrary("GLESv2", .{});
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

    const core_mod = b.addModule("howl_render_core_pure", .{
        .root_source_file = b.path("src/render_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{
        .name = "test-core",
        .root_module = core_mod,
        .filters = b.args orelse &.{},
    });
    core_tests.use_llvm = true;
    const run_core_tests = b.addRunArtifact(core_tests);
    if (b.args != null) {
        run_core_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_core_step = b.step("test:core", "Run pure render-core tests");
    const test_core_build_step = b.step("test:core:build", "Build pure render-core tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_core_build_step.dependOn(&b.addInstallArtifact(core_tests, .{}).step);
    test_core_step.dependOn(&run_core_tests.step);
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_core_step);
    test_step.dependOn(test_unit_step);

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/test/render_core_benchmark.zig"),
        .target = target,
        .optimize = perf_optimize,
    });
    benchmark_mod.addImport("howl_render", perf_mod);
    benchmark_mod.addImport("build_options", build_options.createModule());
    benchmark_mod.linkLibrary(perf_freetype_lib);
    benchmark_mod.addIncludePath(perf_freetype_lib.getEmittedIncludeTree());
    benchmark_mod.linkLibrary(perf_harfbuzz_lib);
    benchmark_mod.addIncludePath(perf_harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        benchmark_mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        benchmark_mod.linkSystemLibrary("GLESv2", .{});
    }

    const benchmark_exe = b.addExecutable(.{
        .name = "render_core_benchmark",
        .root_module = benchmark_mod,
    });
    benchmark_exe.use_llvm = true;
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_step = b.step("render-core-benchmark", "Run render-core benchmark suite");
    benchmark_step.dependOn(&run_benchmark.step);
}
