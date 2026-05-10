//! Render namespace wrapper for the howl-render-core module.

const std = @import("std");
const options = @import("render_options");

pub const c_api = if (options.c_abi) @import("ffi.zig") else void;

const core = @import("render_core.zig").RenderCore;
const renderer = @import("renderer.zig");

pub const Core = core;
pub const Renderer = renderer.Renderer;

pub const geometry = struct {
    pub fn deriveGridSize(grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.GridSize {
        return Core.deriveGridSize(grid_px, cell_px);
    }

    pub fn deriveGridForFrame(render_px: Core.PixelSize, grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.FrameGeometryError!Core.GridSize {
        return Core.deriveGridForFrame(render_px, grid_px, cell_px);
    }
};

test {
    std.testing.refAllDecls(@This());
}
