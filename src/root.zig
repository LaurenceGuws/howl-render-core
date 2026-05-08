//! Responsibility: define the renderer package public surface.
//! Ownership: renderer API boundary and backend selection.
//! Reason: root.zig is already the package namespace.

const build_options = @import("build_options");
const core = @import("render_core.zig").RenderCore;
const backend = switch (build_options.render_backend) {
    .gl => @import("backend/gl/render_gl.zig"),
    .gles => @import("backend/gles/render_gles.zig"),
};

pub const Core = core;
pub const Backend = backend.Backend;
pub const BackendError = backend.BackendError;
pub const RenderReport = backend.RenderReport;

pub const BackendConfig = core.BackendConfig;
pub const BackendCapability = core.BackendCapability;
pub const PixelSize = core.PixelSize;
pub const CellSize = core.CellSize;
pub const GridSize = core.GridSize;
pub const Rgba8 = core.Rgba8;
pub const FillRect = core.FillRect;
pub const GlyphQuad = core.GlyphQuad;
pub const AtlasUpload = core.AtlasUpload;
pub const RenderStats = core.RenderStats;
pub const TextCellInput = core.TextCellInput;
pub const FrameTheme = core.FrameTheme;
pub const OwnedFrameTextInput = core.OwnedFrameTextInput;
pub const OwnedTextSceneInput = core.OwnedTextSceneInput;
pub const SurfaceState = core.SurfaceState;
pub const SurfaceColor = core.SurfaceColor;
pub const UnderlineStyle = core.UnderlineStyle;
pub const SurfaceCellFlags = core.SurfaceCellFlags;
pub const SurfaceCellAttrs = core.SurfaceCellAttrs;
pub const SurfaceCell = core.SurfaceCell;
pub const SurfaceGridModel = core.SurfaceGridModel;
pub const SurfaceViewportInfo = core.SurfaceViewportInfo;
pub const SurfaceCursorShape = core.SurfaceCursorShape;
pub const SurfaceCursorInfo = core.SurfaceCursorInfo;
pub const SurfaceFrameData = core.SurfaceFrameData;
pub const SurfaceHandle = core.SurfaceHandle;
pub const BackendCaps = core.BackendCaps;
pub const FontStyle = core.FontStyle;
pub const TextPresentation = core.TextPresentation;
pub const FontMetrics = core.FontMetrics;
pub const CellMetrics = core.CellMetrics;
pub const GridMetrics = core.GridMetrics;
pub const FontFaceId = core.FontFaceId;
pub const CellTextId = core.CellTextId;
pub const SpriteKey = core.SpriteKey;
pub const CellText = core.CellText;
pub const LineTextCache = core.LineTextCache;
pub const RenderableCell = core.RenderableCell;
pub const CellCluster = core.CellCluster;
pub const RunFont = core.RunFont;
pub const TextRun = core.TextRun;
pub const ResolvedRun = core.ResolvedRun;
pub const GlyphInstance = core.GlyphInstance;
pub const GlyphPlacement = core.GlyphPlacement;
pub const GlyphGroupKind = core.GlyphGroupKind;
pub const GlyphGroup = core.GlyphGroup;
pub const SpriteColorMode = core.SpriteColorMode;
pub const SpritePosition = core.SpritePosition;
pub const TextSpriteDraw = core.TextSpriteDraw;
pub const TextBackgroundDraw = core.TextBackgroundDraw;
pub const TextCursorDraw = core.TextCursorDraw;
pub const DecorationKind = core.DecorationKind;
pub const TextDecorationDraw = core.TextDecorationDraw;
pub const SpriteRasterRequest = core.SpriteRasterRequest;
pub const TextScene = core.TextScene;
pub const SpecialSpriteRoute = core.SpecialSpriteRoute;
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
pub const TextEngineCounters = core.TextEngineCounters;
pub const BuildRunsRequest = core.BuildRunsRequest;
pub const BuildRunsOutput = core.BuildRunsOutput;
pub const GroupGlyphsRequest = core.GroupGlyphsRequest;
pub const GroupGlyphsOutput = core.GroupGlyphsOutput;
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
pub const TextEngine = core.TextEngine;
pub const TextEngineAnalysisOptions = core.TextEngineAnalysisOptions;
pub const TextFontSession = core.TextFontSession;
pub const TextFaceRecord = core.TextFaceRecord;
pub const FrameGeometryError = core.FrameGeometryError;
pub const TextStack = core.TextStack;
pub const defaultTheme = core.defaultTheme;

pub fn init(config: BackendConfig, capability: BackendCapability) Core {
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
