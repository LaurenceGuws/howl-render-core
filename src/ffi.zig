//! Responsibility: implement the howl-render-core native ABI geometry surface.
//! Ownership: render-core pixel, cell, grid, and frame geometry contracts.
//! Reason: keep C consumers on the same backend-agnostic sizing policy as Zig consumers.

const Core = @import("render_core.zig").RenderCore;

pub const FfiPixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiCellSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiGridSize = extern struct {
    cols: u16,
    rows: u16,
};

pub const FfiFrameGridResult = extern struct {
    status: c_int,
    grid: FfiGridSize,
};

fn pixelIn(value: FfiPixelSize) Core.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn cellIn(value: FfiCellSize) Core.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn gridOut(value: Core.GridSize) FfiGridSize {
    return .{ .cols = value.cols, .rows = value.rows };
}

pub fn deriveGridSize(grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiGridSize {
    return gridOut(Core.deriveGridSize(pixelIn(grid_px), cellIn(cell_px)));
}

pub fn deriveFrameGridSize(render_px: FfiPixelSize, grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiFrameGridResult {
    const grid = Core.deriveGridForFrame(pixelIn(render_px), pixelIn(grid_px), cellIn(cell_px)) catch |err| {
        return .{
            .status = switch (err) {
                error.InvalidSurfaceSize => -1,
                error.InvalidGridSize => -2,
            },
            .grid = .{ .cols = 0, .rows = 0 },
        };
    };
    return .{ .status = 0, .grid = gridOut(grid) };
}
