const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("howl_render_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("howl_render_core", mod);

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = mod,
        .filters = b.args orelse &.{},
    });
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
