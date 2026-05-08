//! Responsibility: provide a single render-core owner surface.
//! Ownership: render-core orchestration API.
//! Reason: keep hosts/backends on one coherent entrypoint.

const std = @import("std");
const render_types = @import("render_types.zig");
const vt_state = @import("vt_state.zig");
const surface = @import("frame_state.zig");
const text_contract = @import("text_contract.zig");
const text_pipeline = @import("text_pipeline.zig");
const text_stack = @import("text_stack.zig");

pub const RenderCore = struct {
    pub const BackendConfig = render_types.BackendConfig;
    pub const BackendCapability = render_types.BackendCapability;
    pub const PixelSize = render_types.PixelSize;
    pub const CellSize = render_types.CellSize;
    pub const GridSize = render_types.GridSize;
    pub const Rgba8 = render_types.Rgba8;
    pub const FillRect = render_types.FillRect;
    pub const GlyphQuad = render_types.GlyphQuad;
    pub const AtlasUpload = render_types.AtlasUpload;
    pub const RenderStats = render_types.RenderStats;
    pub const TextCellInput = render_types.CellInput;
    pub const CellInput = render_types.CellInput;
    pub const FrameTheme = vt_state.FrameTheme;
    pub const OwnedFrameTextInput = vt_state.OwnedFrameTextInput;
    pub const OwnedTextSceneInput = vt_state.OwnedTextSceneInput;
    pub const SurfaceState = surface.SurfaceState;
    pub const SurfaceColor = surface.Color;
    pub const UnderlineStyle = surface.UnderlineStyle;
    pub const SurfaceCellFlags = surface.CellFlags;
    pub const SurfaceCellAttrs = surface.CellAttrs;
    pub const SurfaceCell = surface.Cell;
    pub const SurfaceGridModel = surface.GridModel;
    pub const SurfaceViewportInfo = surface.ViewportInfo;
    pub const SurfaceCursorShape = surface.CursorShape;
    pub const SurfaceCursorInfo = surface.CursorInfo;
    pub const SurfaceFrameData = surface.FrameData;
    pub const SurfaceHandle = struct {
        texture_id: u32,
        width: u16,
        height: u16,
        epoch: u64,
    };
    pub const BackendCaps = text_contract.BackendCaps;
    pub const FontStyle = text_contract.FontStyle;
    pub const TextPresentation = text_contract.TextPresentation;
    pub const FontMetrics = text_contract.FontMetrics;
    pub const CellMetrics = text_contract.CellMetrics;
    pub const GridMetrics = text_contract.GridMetrics;
    pub const FontFaceId = text_contract.FontFaceId;
    pub const CellTextId = text_contract.CellTextId;
    pub const SpriteKey = text_contract.SpriteKey;
    pub const CellText = text_contract.CellText;
    pub const LineTextCache = text_contract.LineTextCache;
    pub const RenderableCell = text_contract.RenderableCell;
    pub const CellCluster = text_contract.CellCluster;
    pub const RunFont = text_contract.RunFont;
    pub const TextRun = text_contract.TextRun;
    pub const ResolvedRun = text_contract.ResolvedRun;
    pub const GlyphInstance = text_contract.GlyphInstance;
    pub const GlyphPlacement = text_contract.GlyphPlacement;
    pub const GlyphGroupKind = text_contract.GlyphGroupKind;
    pub const GlyphGroup = text_contract.GlyphGroup;
    pub const SpriteColorMode = text_contract.SpriteColorMode;
    pub const SpritePosition = text_contract.SpritePosition;
    pub const TextSpriteDraw = text_contract.TextSpriteDraw;
    pub const TextBackgroundDraw = text_contract.TextBackgroundDraw;
    pub const TextClearDraw = text_contract.TextClearDraw;
    pub const TextCursorDraw = text_contract.TextCursorDraw;
    pub const DecorationKind = text_contract.DecorationKind;
    pub const TextDecorationDraw = text_contract.TextDecorationDraw;
    pub const SpriteRasterRequest = text_contract.SpriteRasterRequest;
    pub const TextScene = text_contract.TextScene;
    pub const SpecialSpriteRoute = text_contract.SpecialSpriteRoute;
    pub const TextCluster = text_contract.TextCluster;
    pub const ShapedGlyph = text_contract.ShapedGlyph;
    pub const ShapedRun = text_contract.ShapedRun;
    pub const MissingGlyphReason = text_contract.MissingGlyphReason;
    pub const MissingGlyph = text_contract.MissingGlyph;
    pub const ResolveStage = text_pipeline.ResolveStage;
    pub const ResolveRequest = text_pipeline.ResolveRequest;
    pub const ResolveHit = text_pipeline.ResolveHit;
    pub const ResolveMiss = text_pipeline.ResolveMiss;
    pub const ResolveResult = text_pipeline.ResolveResult;
    pub const ResolveCounters = text_pipeline.ResolveCounters;
    pub const TextEngineCounters = text_pipeline.TextEngineCounters;
    pub const BuildRunsRequest = text_pipeline.BuildRunsRequest;
    pub const BuildRunsOutput = text_pipeline.BuildRunsOutput;
    pub const GroupGlyphsRequest = text_pipeline.GroupGlyphsRequest;
    pub const GroupGlyphsOutput = text_pipeline.GroupGlyphsOutput;
    pub const ShapeRequest = text_pipeline.ShapeRequest;
    pub const ShapeOutput = text_pipeline.ShapeOutput;
    pub const RasterizeRequest = text_pipeline.RasterizeRequest;
    pub const RasterizeOutput = text_pipeline.RasterizeOutput;
    pub const ShapeClustersFn = text_pipeline.ShapeClustersFn;
    pub const RasterizeGlyphFn = text_pipeline.RasterizeGlyphFn;
    pub const ResolveFallbackFaceFn = text_pipeline.ResolveFallbackFaceFn;
    pub const ShapeClustersOp = text_pipeline.ShapeClustersOp;
    pub const RasterizeGlyphOp = text_pipeline.RasterizeGlyphOp;
    pub const ResolveFallbackFaceOp = text_pipeline.ResolveFallbackFaceOp;
    pub const TextStack = text_stack;
    pub const TextEngine = text_stack.Engine.Engine;
    pub const TextEngineAnalysisOptions = text_stack.Engine.AnalysisOptions;
    pub const TextFontSession = text_stack.FontSession.FontSession;
    pub const TextFaceRecord = text_stack.FontSession.FontFaceRecord;
    pub const FrameGeometryError = error{
        InvalidSurfaceSize,
        InvalidGridSize,
    };
    pub const defaultTheme = vt_state.default_theme;

    config: render_types.BackendConfig,
    capability: render_types.BackendCapability,

    pub fn init(config: BackendConfig, capability: BackendCapability) RenderCore {
        return .{
            .config = config,
            .capability = capability,
        };
    }

    /// Canonical active-path frame-to-text input conversion.
    pub fn vtStateToTextSceneInput(
        _: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedTextSceneInput {
        return vt_state.vtStateToTextSceneInput(allocator, state);
    }

    pub fn vtStateToFrameTextInput(
        _: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedFrameTextInput {
        return vt_state.vtStateToFrameTextInput(allocator, state);
    }

    pub fn buildFrameTextInput(
        self: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedFrameTextInput {
        return self.vtStateToFrameTextInput(allocator, state);
    }

    /// Derive grid dimensions from pixel-space area and cell-size policy.
    pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
        const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
        const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
        return .{
            .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
            .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
        };
    }

    /// Validate frame geometry inputs and derive grid dimensions.
    pub fn deriveGridForFrame(render_px: PixelSize, grid_px: PixelSize, cell_px: CellSize) FrameGeometryError!GridSize {
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        return deriveGridSize(grid_px, cell_px);
    }
};
