const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const howl_term_surface_dep = b.dependency("howl_term_surface", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_term_surface_mod = howl_term_surface_dep.module("howl_term_surface");

    const mod = b.addModule("howl_render_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("howl_term_surface", howl_term_surface_mod);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.linkLibC();
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run module tests");
    test_step.dependOn(&run_mod_tests.step);
}
