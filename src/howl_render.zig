//! Responsibility: define the renderer package public surface.
//! Ownership: renderer API boundary and backend selection.
//! Reason: keep the package root named after the public domain instead of a generic root facade.

const lib = @This();
const std = @import("std");
const build_options = @import("build_options");
const core = @import("render_core.zig").RenderCore;
const renderer = @import("renderer.zig");
const backend = switch (build_options.render_backend) {
    .gl => @import("backend/gl/backend.zig"),
    .gles => @import("backend/gles/backend.zig"),
};

pub const Core = core;
pub const Renderer = renderer.Renderer;

pub const geometry = struct {
    pub fn deriveGridSize(grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.GridSize {
        return backend.deriveGridSize(grid_px, cell_px);
    }

    pub fn deriveGridForFrame(render_px: Core.PixelSize, grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.FrameGeometryError!Core.GridSize {
        return backend.deriveGridForFrame(render_px, grid_px, cell_px);
    }
};

test {
    _ = @import("test/root.zig");
    std.testing.refAllDecls(lib);
}
