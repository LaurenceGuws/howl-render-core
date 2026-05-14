//! Responsibility: collect repo-local render proof imports.
//! Ownership: repo-local tests only.
//! Reason: keep the shipped boundary off the Zig root.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("render.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
}
