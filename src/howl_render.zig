//! Responsibility: define the renderer package public surface.
//! Ownership: renderer API boundary and backend selection.
//! Reason: keep the package root named after the public domain instead of a generic root facade.

const lib = @This();
const std = @import("std");
const render = @import("render/main.zig");
const ffi = render.c_api;

pub const Core = render.Core;
pub const Ffi = ffi;
pub const Renderer = render.Renderer;
pub const geometry = render.geometry;

comptime {
    if (@import("root") == lib) {
        @export(&ffi.deriveGridSize, .{ .name = "howl_render_derive_grid_size" });
        @export(&ffi.deriveFrameGridSize, .{ .name = "howl_render_derive_frame_grid_size" });
    }
}

test {
    _ = @import("test/root.zig");
    std.testing.refAllDecls(lib);
}
