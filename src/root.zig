//! Responsibility: export the unified renderer package surface.
//! Ownership: renderer API boundary and backend selection.
//! Reason: keep one renderer package while selecting backend at compile time.

const build_options = @import("build_options");
const core = @import("core_api.zig");
const backend = switch (build_options.render_backend) {
    .gl => @import("backend/gl/root.zig"),
    .gles => @import("backend/gles/root.zig"),
};

pub const RenderCore = core.RenderCore;
pub const BackendConfig = core.BackendConfig;
pub const BackendCapability = core.BackendCapability;
pub const PixelSize = core.PixelSize;
pub const CellSize = core.CellSize;
pub const GridSize = core.GridSize;
pub const Rgba8 = core.Rgba8;
pub const FillRect = core.FillRect;
pub const GlyphQuad = core.GlyphQuad;
pub const CursorShape = core.CursorShape;
pub const CursorDraw = core.CursorDraw;
pub const AtlasUpload = core.AtlasUpload;
pub const RenderBatchStats = core.RenderBatchStats;
pub const RenderBatch = core.RenderBatch;
pub const CellInput = core.CellInput;
pub const GridInput = core.GridInput;
pub const CursorInput = core.CursorInput;
pub const VtState = core.VtState;
pub const FrameTheme = core.FrameTheme;
pub const OwnedRenderBatch = core.OwnedRenderBatch;
pub const SurfaceState = core.SurfaceState;
pub const SurfaceColor = core.SurfaceColor;
pub const SurfaceCellFlags = core.SurfaceCellFlags;
pub const SurfaceCellAttrs = core.SurfaceCellAttrs;
pub const SurfaceCell = core.SurfaceCell;
pub const SurfaceGridModel = core.SurfaceGridModel;
pub const SurfaceViewportInfo = core.SurfaceViewportInfo;
pub const SurfaceCursorShape = core.SurfaceCursorShape;
pub const SurfaceCursorInfo = core.SurfaceCursorInfo;
pub const SurfaceFrameData = core.SurfaceFrameData;
pub const BackendCaps = core.BackendCaps;
pub const FontStyle = core.FontStyle;
pub const TextPresentation = core.TextPresentation;
pub const FontMetrics = core.FontMetrics;
pub const CellMetrics = core.CellMetrics;
pub const TextCluster = core.TextCluster;
pub const ShapedGlyph = core.ShapedGlyph;
pub const ShapedRun = core.ShapedRun;
pub const MissingGlyphReason = core.MissingGlyphReason;
pub const MissingGlyph = core.MissingGlyph;
pub const ResolveStage = core.ResolveStage;
pub const ResolveRequest = core.ResolveRequest;
pub const ResolveHit = core.ResolveHit;
pub const ResolveMiss = core.ResolveMiss;
pub const ResolveResult = core.ResolveResult;
pub const ResolveCounters = core.ResolveCounters;
pub const ShapeRequest = core.ShapeRequest;
pub const ShapeOutput = core.ShapeOutput;
pub const RasterizeRequest = core.RasterizeRequest;
pub const RasterizeOutput = core.RasterizeOutput;
pub const ShapeClustersFn = core.ShapeClustersFn;
pub const RasterizeGlyphFn = core.RasterizeGlyphFn;
pub const ResolveFallbackFaceFn = core.ResolveFallbackFaceFn;
pub const ShapeClustersOp = core.ShapeClustersOp;
pub const RasterizeGlyphOp = core.RasterizeGlyphOp;
pub const ResolveFallbackFaceOp = core.ResolveFallbackFaceOp;
pub const RenderBatchValidationError = core.RenderBatchValidationError;
pub const RenderBatchBuildError = core.RenderBatchBuildError;
pub const FrameGeometryError = core.FrameGeometryError;
pub const defaultTheme = core.defaultTheme;
pub const TextStack = core.TextStack;

pub const Backend = backend.Backend;
pub const BackendError = backend.BackendError;
pub const RenderReport = backend.RenderReport;

pub fn init(config: BackendConfig, capability: BackendCapability) RenderCore {
    return core.init(config, capability);
}

pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
    return backend.deriveGridSize(grid_px, cell_px);
}

pub fn deriveGridForFrame(render_px: PixelSize, grid_px: PixelSize, cell_px: CellSize) FrameGeometryError!GridSize {
    return backend.deriveGridForFrame(render_px, grid_px, cell_px);
}

test {
    _ = @import("test/root.zig");
}
