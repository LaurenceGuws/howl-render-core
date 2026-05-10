//! Responsibility: define the renderer package public surface.
//! Ownership: renderer API boundary and backend selection.
//! Reason: keep the package root named after the public domain instead of a generic root facade.

const build_options = @import("build_options");
const core = @import("render_core.zig").RenderCore;
const backend = switch (build_options.render_backend) {
    .gl => @import("backend/gl/backend.zig"),
    .gles => @import("backend/gles/backend.zig"),
};

pub const Core = core;
pub const Backend = backend.Backend;
pub const BackendError = backend.BackendError;
pub const RenderReport = backend.RenderReport;
pub const PreparedTextScene = backend.PreparedTextScene;
pub const TextSceneRenderReport = backend.TextSceneRenderReport;
pub const Renderer = @import("renderer.zig").Renderer;

pub fn init(config: Core.BackendConfig, capability: Core.BackendCapability) Core {
    return core.init(config, capability);
}

pub fn deriveGridSize(grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.GridSize {
    return backend.deriveGridSize(grid_px, cell_px);
}

pub fn deriveGridForFrame(render_px: Core.PixelSize, grid_px: Core.PixelSize, cell_px: Core.CellSize) Core.FrameGeometryError!Core.GridSize {
    return backend.deriveGridForFrame(render_px, grid_px, cell_px);
}

test {
    _ = @import("test/root.zig");
}
