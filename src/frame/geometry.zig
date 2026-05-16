const surface = @import("surface.zig");

pub const FrameGeometryError = error{
    InvalidSurfaceSize,
    InvalidGridSize,
};

pub fn deriveGridSize(grid_px: surface.PixelSize, cell_px: surface.CellSize) surface.GridSize {
    const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
    const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
    return .{
        .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
        .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
    };
}

pub fn deriveGridForFrame(
    render_px: surface.PixelSize,
    grid_px: surface.PixelSize,
    cell_px: surface.CellSize,
) FrameGeometryError!surface.GridSize {
    if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
    if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
    return deriveGridSize(grid_px, cell_px);
}
