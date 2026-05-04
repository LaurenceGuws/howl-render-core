//! Responsibility: export the unified renderer OpenGL backend surface.
//! Ownership: internal backend boundary for the OpenGL implementation.
//! Reason: keep root exports boring and push implementation behind a sibling owner file.

const api = @import("RenderGl.zig");

/// Canonical OpenGL backend owner surface.
pub const RenderGl = api.RenderGl;
/// Concrete OpenGL backend implementation.
pub const Backend = api.Backend;
/// OpenGL backend error surface.
pub const BackendError = api.BackendError;
pub const CellSize = api.CellSize;
pub const SurfaceColor = api.SurfaceColor;
pub const SurfaceCellFlags = api.SurfaceCellFlags;
pub const SurfaceCellAttrs = api.SurfaceCellAttrs;
pub const SurfaceCell = api.SurfaceCell;
pub const SurfaceGridModel = api.SurfaceGridModel;
pub const SurfaceCursorShape = api.SurfaceCursorShape;
pub const SurfaceCursorInfo = api.SurfaceCursorInfo;
pub const SurfaceViewportInfo = api.SurfaceViewportInfo;
pub const SurfaceFrameData = api.SurfaceFrameData;
/// Render report returned after one backend pass.
pub const RenderReport = api.RenderReport;

/// Derive grid dimensions through the shared render-core policy.
pub fn deriveGridSize(grid_px: @import("../../core_api.zig").PixelSize, cell_px: CellSize) @import("../../core_api.zig").GridSize {
    return api.deriveGridSize(grid_px, cell_px);
}

/// Validate frame geometry and derive grid dimensions.
pub fn deriveGridForFrame(
    render_px: @import("../../core_api.zig").PixelSize,
    grid_px: @import("../../core_api.zig").PixelSize,
    cell_px: CellSize,
) @import("../../core_api.zig").FrameGeometryError!@import("../../core_api.zig").GridSize {
    return api.deriveGridForFrame(render_px, grid_px, cell_px);
}
