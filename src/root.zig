//! Responsibility: export the render-core package surface.
//! Ownership: package API boundary.
//! Reason: keep exports explicit and stable.

pub const RenderCore = @import("render_core.zig").RenderCore;
pub const BackendConfig = RenderCore.BackendConfig;
pub const BackendCapability = RenderCore.BackendCapability;
pub const PixelSize = RenderCore.PixelSize;
pub const CellSize = RenderCore.CellSize;
pub const GridSize = RenderCore.GridSize;
pub const Rgba8 = RenderCore.Rgba8;
pub const FillRect = RenderCore.FillRect;
pub const GlyphQuad = RenderCore.GlyphQuad;
pub const CursorShape = RenderCore.CursorShape;
pub const CursorDraw = RenderCore.CursorDraw;
pub const AtlasUpload = RenderCore.AtlasUpload;
pub const RenderBatchStats = RenderCore.RenderBatchStats;
pub const RenderBatch = RenderCore.RenderBatch;
pub const CellInput = RenderCore.CellInput;
pub const GridInput = RenderCore.GridInput;
pub const CursorInput = RenderCore.CursorInput;
pub const VtState = RenderCore.VtState;
pub const FrameTheme = RenderCore.FrameTheme;
pub const OwnedRenderBatch = RenderCore.OwnedRenderBatch;
pub const SurfaceState = RenderCore.SurfaceState;
pub const SurfaceColor = RenderCore.SurfaceColor;
pub const SurfaceCellFlags = RenderCore.SurfaceCellFlags;
pub const SurfaceCellAttrs = RenderCore.SurfaceCellAttrs;
pub const SurfaceCell = RenderCore.SurfaceCell;
pub const SurfaceGridModel = RenderCore.SurfaceGridModel;
pub const SurfaceViewportInfo = RenderCore.SurfaceViewportInfo;
pub const SurfaceCursorShape = RenderCore.SurfaceCursorShape;
pub const SurfaceCursorInfo = RenderCore.SurfaceCursorInfo;
pub const SurfaceFrameData = RenderCore.SurfaceFrameData;
pub const BackendCaps = RenderCore.BackendCaps;
pub const FontStyle = RenderCore.FontStyle;
pub const TextPresentation = RenderCore.TextPresentation;
pub const FontMetrics = RenderCore.FontMetrics;
pub const CellMetrics = RenderCore.CellMetrics;
pub const TextCluster = RenderCore.TextCluster;
pub const ShapedGlyph = RenderCore.ShapedGlyph;
pub const ShapedRun = RenderCore.ShapedRun;
pub const MissingGlyphReason = RenderCore.MissingGlyphReason;
pub const MissingGlyph = RenderCore.MissingGlyph;
pub const ResolveStage = RenderCore.ResolveStage;
pub const ResolveRequest = RenderCore.ResolveRequest;
pub const ResolveHit = RenderCore.ResolveHit;
pub const ResolveMiss = RenderCore.ResolveMiss;
pub const ResolveResult = RenderCore.ResolveResult;
pub const ResolveCounters = RenderCore.ResolveCounters;
pub const ShapeRequest = RenderCore.ShapeRequest;
pub const ShapeOutput = RenderCore.ShapeOutput;
pub const RasterizeRequest = RenderCore.RasterizeRequest;
pub const RasterizeOutput = RenderCore.RasterizeOutput;
pub const ShapeClustersFn = RenderCore.ShapeClustersFn;
pub const RasterizeGlyphFn = RenderCore.RasterizeGlyphFn;
pub const ResolveFallbackFaceFn = RenderCore.ResolveFallbackFaceFn;
pub const ShapeClustersOp = RenderCore.ShapeClustersOp;
pub const RasterizeGlyphOp = RenderCore.RasterizeGlyphOp;
pub const ResolveFallbackFaceOp = RenderCore.ResolveFallbackFaceOp;
pub const RenderBatchValidationError = RenderCore.RenderBatchValidationError;
pub const RenderBatchBuildError = RenderCore.RenderBatchBuildError;
pub const FrameGeometryError = RenderCore.FrameGeometryError;
pub const defaultTheme = RenderCore.defaultTheme;
pub const TextStack = @import("TextStack.zig").TextStack;

pub fn init(config: BackendConfig, capability: BackendCapability) RenderCore {
    return RenderCore.init(config, capability);
}

pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
    return RenderCore.deriveGridSize(grid_px, cell_px);
}

pub fn deriveGridForFrame(render_px: PixelSize, grid_px: PixelSize, cell_px: CellSize) FrameGeometryError!GridSize {
    return RenderCore.deriveGridForFrame(render_px, grid_px, cell_px);
}

test {
    _ = @import("test/root.zig");
}
