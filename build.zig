// This repo ships a C ABI first until further notice.
// Keep build entrypoints aligned around the shipped header and exported symbols, not privileged Zig imports.
// The render backends exist to pressure-test one embedding contract early, not to let current host constraints reshape render ownership.

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

    const module_options = b.addOptions();
    module_options.addOption(RenderBackend, "render_backend", selected_backend);
    module_options.addOption(bool, "c_abi", false);
    const perf_options = b.addOptions();
    perf_options.addOption(RenderBackend, "render_backend", selected_backend);
    perf_options.addOption(bool, "c_abi", false);
    const ffi_options = b.addOptions();
    ffi_options.addOption(RenderBackend, "render_backend", selected_backend);
    ffi_options.addOption(bool, "c_abi", true);

    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/howl_render.zig"),
        .target = target,
        .optimize = optimize,
    });
    internal_mod.addImport("render_options", module_options.createModule());
    internal_mod.linkLibrary(freetype_lib);
    internal_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    internal_mod.linkLibrary(harfbuzz_lib);
    internal_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        internal_mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        internal_mod.linkSystemLibrary("GLESv2", .{});
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
    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = internal_mod,
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
    }

    const render_owner = b.createModule(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    const render_tests = b.addTest(.{
        .name = "test-render",
        .root_module = render_owner,
        .filters = b.args orelse &.{},
    });
    render_tests.use_llvm = true;
    const run_render_tests = b.addRunArtifact(render_tests);
    if (b.args != null) {
        run_render_tests.has_side_effects = true;
    }

    const runtime_proof_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_proof_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_proof_mod.addImport("render_options", module_options.createModule());
    runtime_proof_mod.linkLibrary(freetype_lib);
    runtime_proof_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    runtime_proof_mod.linkLibrary(harfbuzz_lib);
    runtime_proof_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        runtime_proof_mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        runtime_proof_mod.linkSystemLibrary("GLESv2", .{});
    }
    const runtime_proof_tests = b.addTest(.{
        .name = "test-runtime-proof",
        .root_module = runtime_proof_mod,
        .filters = b.args orelse &.{},
    });
    runtime_proof_tests.use_llvm = true;
    const run_runtime_proof_tests = b.addRunArtifact(runtime_proof_tests);
    if (b.args != null) {
        run_runtime_proof_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_render_step = b.step("test:render", "Run pure render tests");
    const test_render_build_step = b.step("test:render:build", "Build pure render tests");
    const test_runtime_proof_step = b.step("test:runtime-proof", "Run runtime proof tests");
    const test_runtime_proof_build_step = b.step("test:runtime-proof:build", "Build runtime proof tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_render_build_step.dependOn(&b.addInstallArtifact(render_tests, .{}).step);
    test_render_step.dependOn(&run_render_tests.step);
    test_runtime_proof_build_step.dependOn(&b.addInstallArtifact(runtime_proof_tests, .{}).step);
    test_runtime_proof_step.dependOn(&run_runtime_proof_tests.step);
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_render_step);
    test_step.dependOn(test_runtime_proof_step);
    test_step.dependOn(test_unit_step);

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/libhowl_render.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_mod.addImport("render_options", ffi_options.createModule());
    ffi_mod.linkLibrary(freetype_lib);
    ffi_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    ffi_mod.linkLibrary(harfbuzz_lib);
    ffi_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    if (selected_backend == .gl) {
        ffi_mod.linkSystemLibrary("GL", .{});
    } else if (target.result.abi != .android) {
        ffi_mod.linkSystemLibrary("GLESv2", .{});
    }
    const ffi_lib = b.addLibrary(.{
        .name = "howl_render",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    const ffi_build_step = b.step("ffi:build", "Build the howl-render C FFI library");
    ffi_build_step.dependOn(&b.addInstallArtifact(ffi_lib, .{}).step);
    b.installArtifact(ffi_lib);
    b.installFile("include/howl_render.h", "include/howl_render.h");

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/render_benchmark_root.zig"),
        .target = target,
        .optimize = perf_optimize,
    });
    benchmark_mod.addImport("render_options", perf_options.createModule());
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
        .name = "render_benchmark",
        .root_module = benchmark_mod,
    });
    benchmark_exe.use_llvm = true;
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_build_step = b.step("render-benchmark:build", "Build render benchmark suite");
    benchmark_build_step.dependOn(&b.addInstallArtifact(benchmark_exe, .{}).step);
    const benchmark_step = b.step("render-benchmark", "Run render benchmark suite");
    benchmark_step.dependOn(&run_benchmark.step);
}
