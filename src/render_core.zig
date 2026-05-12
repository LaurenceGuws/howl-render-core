//! Responsibility: provide a single render-core owner surface.
//! Ownership: render-core orchestration API.
//! Reason: keep hosts/backends on one coherent entrypoint.

const std = @import("std");
const types = @import("types.zig");
const frame_input = @import("frame_input.zig");
const frame_metrics = @import("frame_metrics.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const frame_queue = @import("frame_queue.zig");
const frame_snapshot = @import("frame_snapshot.zig");
const surface = @import("surface.zig");
const text_contract = @import("text_contract.zig");
const text_pipeline = @import("text_pipeline.zig");
const text = @import("text.zig");

pub const RenderCore = struct {
    pub const BackendConfig = types.BackendConfig;
    pub const BackendCapability = types.BackendCapability;
    pub const PixelSize = types.PixelSize;
    pub const CellSize = types.CellSize;
    pub const GridSize = types.GridSize;
    pub const FramePixels = types.FramePixels;
    pub const Rgba8 = types.Rgba8;
    pub const FillRect = types.FillRect;
    pub const GlyphQuad = types.GlyphQuad;
    pub const AtlasUpload = types.AtlasUpload;
    pub const RenderStats = types.RenderStats;
    pub const TextCellInput = types.CellInput;
    pub const CellInput = types.CellInput;
    pub const CellTextInput = text.Cluster.CellTextInput;
    pub const TextLane = text.Lane.TextLane;
    pub const TextComplexLaneReason = text.Lane.ComplexLaneReason;
    pub const TextLaneReport = text.Lane.LaneReport;
    pub const FrameTheme = frame_input.FrameTheme;
    pub const OwnedFrameTextInput = frame_input.OwnedFrameTextInput;
    pub const OwnedTextSceneInput = frame_input.OwnedTextSceneInput;
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
    pub const FrameSnapshot = frame_snapshot.Snapshot;
    pub const FrameSnapshotDirty = frame_snapshot.Dirty;
    pub const FrameSnapshotDamage = frame_snapshot.Damage;
    pub const FrameSnapshotDirtyView = frame_snapshot.DirtyView;
    pub const SourceReceipt = struct {
        dirty: bool,
        stale_epoch: bool,
        dirty_epoch: u64,
        synced_epoch: u64,
        selection_active: bool,
        focus_active: bool,
        viewport_dirty: bool,
    };
    pub const GeometryReceipt = struct {
        changed: bool,
        render_px: types.PixelSize,
        grid_px: types.PixelSize,
        cell_px: types.CellSize,
    };
    pub const RenderRuntime = struct {
        geometry_epoch: u64 = 0,
        surface: SurfaceQuery = .{
            .width = 0,
            .height = 0,
            .epoch = 0,
        },

        pub fn init() RenderRuntime {
            return .{};
        }

        pub fn acceptSource(_: *RenderRuntime, source: SourceView) SourceReceipt {
            std.debug.assert(source.cols > 0);
            std.debug.assert(source.rows > 0);
            std.debug.assert(source.snapshot.cols == source.cols);
            std.debug.assert(source.snapshot.rows == source.rows);
            std.debug.assert(source.scrollback_offset <= source.scrollback_count);

            return .{
                .dirty = source.isDirty(),
                .stale_epoch = source.dirty_epoch != source.synced_epoch,
                .dirty_epoch = source.dirty_epoch,
                .synced_epoch = source.synced_epoch,
                .selection_active = source.selectionActive(),
                .focus_active = source.focused,
                .viewport_dirty = source.scrollback_view_invalidated,
            };
        }

        pub fn syncGeometry(self: *RenderRuntime, layout: Geometry) GeometryReceipt {
            std.debug.assert(layout.render_px.width > 0);
            std.debug.assert(layout.render_px.height > 0);
            std.debug.assert(layout.grid_px.width > 0);
            std.debug.assert(layout.grid_px.height > 0);
            std.debug.assert(layout.cell_px.width > 0);
            std.debug.assert(layout.cell_px.height > 0);

            const changed = self.surface.width != layout.render_px.width or
                self.surface.height != layout.render_px.height or
                self.surface.epoch == 0;
            self.geometry_epoch +%= 1;
            self.surface.width = layout.render_px.width;
            self.surface.height = layout.render_px.height;
            self.surface.epoch = self.geometry_epoch;
            return .{
                .changed = changed,
                .render_px = layout.render_px,
                .grid_px = layout.grid_px,
                .cell_px = layout.cell_px,
            };
        }

        pub fn prepareState(input: PrepareInput) PrepareState {
            return switch (input) {
                .idle => .idle,
                .ready => |ready| if (ready.source.isDirty()) .ready else .idle,
            };
        }

        pub fn prepare(_: *RenderRuntime, input: PrepareInput) PrepareState {
            return prepareState(input);
        }

        pub fn submitState(input: SubmitInput) SubmitState {
            return switch (input) {
                .idle => .idle,
                .ready => |ready| switch (frame_pipeline.validatePreparedFrame(ready.prepared, ready.submitted)) {
                    .valid => .present,
                    .stale_geometry => .geometry_changed,
                    .missing_retained_base => .stale_base,
                    .stale_retained_base => .stale_base,
                    .stale_target => .stale_target,
                },
            };
        }

        pub fn submit(_: *RenderRuntime, input: SubmitInput) SubmitState {
            return submitState(input);
        }

        pub fn surfaceQuery(self: *const RenderRuntime) SurfaceQuery {
            return self.surface;
        }
    };
    pub const SourceView = struct {
        snapshot: *const FrameSnapshot,
        cols: u16,
        rows: u16,
        scrollback_count: u64,
        scrollback_offset: u64,
        selection_anchor_depth: ?u64 = null,
        selection_anchor_col: ?u16 = null,
        selection_current_depth: ?u64 = null,
        selection_current_col: ?u16 = null,
        focused: bool = true,
        hover_link_id: u32 = 0,
        hover_underline_style: surface.UnderlineStyle = .straight,
        title: []const u8 = &.{},
        output_seen: bool = false,
        snapshot_seq: u64 = 0,
        vt_epoch: u64 = 0,
        synced_epoch: u64 = 0,
        dirty_epoch: u64 = 0,
        geometry_epoch: u64 = 0,
        scrollback_view_invalidated: bool = false,
        last_alt_screen: bool = false,

        pub fn selectionActive(self: SourceView) bool {
            return self.selection_anchor_depth != null and
                self.selection_anchor_col != null and
                self.selection_current_depth != null and
                self.selection_current_col != null;
        }

        /// Render-visible dirtiness follows the terminal publication epoch and explicit visible flags.
        /// Title and output proof stay in the publication/readout seam instead.
        pub fn isDirty(self: SourceView) bool {
            return self.dirty_epoch != self.synced_epoch or
                self.scrollback_view_invalidated or
                self.selectionActive() or
                !self.focused or
                self.hover_link_id != 0 or
                self.last_alt_screen;
        }
    };
    pub const Geometry = struct {
        render_px: types.PixelSize,
        grid_px: types.PixelSize,
        cell_px: types.CellSize,
    };
    pub const PrepareInput = union(enum) {
        idle,
        ready: struct {
            source: SourceView,
            geometry: Geometry,
        },
    };
    pub const PrepareState = enum {
        idle,
        ready,
    };
    pub const SubmitInput = union(enum) {
        idle,
        ready: struct {
            prepared: FramePipeline.PreparedFrame,
            submitted: FramePipeline.SubmittedFrame,
        },
    };
    pub const SubmitState = enum {
        idle,
        present,
        stale_base,
        stale_target,
        geometry_changed,
    };
    pub const SurfaceQuery = struct {
        width: u16,
        height: u16,
        epoch: u64,
    };
    pub const PrepareMetrics = frame_metrics.PrepareMetrics;
    pub const RenderMetrics = frame_metrics.RenderMetrics;
    pub const FramePipeline = frame_pipeline;
    pub const FrameQueue = frame_queue;
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
    pub const SpriteRasterKind = text_contract.SpriteRasterKind;
    pub const DecorationSpriteRaster = text_contract.DecorationSpriteRaster;
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
    pub const Text = text;
    pub const TextEngine = text.Engine.Engine;
    pub const TextEngineAnalysisOptions = text.Engine.AnalysisOptions;
    pub const TextFontSession = text.FontSession.FontSession;
    pub const TextFaceRecord = text.FontSession.FontFaceRecord;
    pub const FrameGeometryError = error{
        InvalidSurfaceSize,
        InvalidGridSize,
    };
    pub const defaultTheme = frame_input.default_theme;

    config: types.BackendConfig,
    capability: types.BackendCapability,

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
        return frame_input.vtStateToTextSceneInput(allocator, state);
    }

    pub fn vtStateToFrameTextInput(
        _: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedFrameTextInput {
        return frame_input.vtStateToFrameTextInput(allocator, state);
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

pub const geometry = struct {
    pub const deriveGridSize = RenderCore.deriveGridSize;
    pub const deriveGridForFrame = RenderCore.deriveGridForFrame;
};

test "render runtime contract classifies source and submit state" {
    var runtime = RenderCore.RenderRuntime.init();
    var snapshot = try RenderCore.FrameSnapshot.init(std.testing.allocator, 2, 3);
    defer snapshot.deinit(std.testing.allocator);

    const clean_source = RenderCore.SourceView{
        .snapshot = &snapshot,
        .cols = 3,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .title = "x",
        .output_seen = false,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .synced_epoch = 1,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .scrollback_view_invalidated = false,
        .last_alt_screen = false,
    };
    const clean_receipt = runtime.acceptSource(clean_source);
    try std.testing.expect(!clean_receipt.dirty);
    try std.testing.expect(!clean_receipt.stale_epoch);
    try std.testing.expect(clean_receipt.focus_active);
    try std.testing.expect(!clean_receipt.selection_active);
    try std.testing.expect(!clean_receipt.viewport_dirty);

    const synced_geometry = runtime.syncGeometry(.{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(synced_geometry.changed);
    const query = runtime.surfaceQuery();
    try std.testing.expectEqual(@as(u16, 24), query.width);
    try std.testing.expectEqual(@as(u16, 32), query.height);

    const changed_geometry = runtime.syncGeometry(.{
        .render_px = .{ .width = 40, .height = 48 },
        .grid_px = .{ .width = 40, .height = 48 },
        .cell_px = .{ .width = 10, .height = 16 },
    });
    try std.testing.expect(changed_geometry.changed);
    const changed_query = runtime.surfaceQuery();
    try std.testing.expectEqual(@as(u16, 40), changed_query.width);
    try std.testing.expectEqual(@as(u16, 48), changed_query.height);

    try std.testing.expectEqual(RenderCore.PrepareState.idle, runtime.prepare(.{ .idle = {} }));
    try std.testing.expectEqual(RenderCore.PrepareState.idle, runtime.prepare(.{ .ready = .{ .source = clean_source, .geometry = .{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    } } }));

    var selection_source = clean_source;
    selection_source.selection_anchor_depth = 2;
    selection_source.selection_anchor_col = 1;
    selection_source.selection_current_depth = 2;
    selection_source.selection_current_col = 2;
    selection_source.dirty_epoch = 2;
    const selection_receipt = runtime.acceptSource(selection_source);
    try std.testing.expect(selection_receipt.dirty);
    try std.testing.expect(selection_receipt.selection_active);
    try std.testing.expect(selection_receipt.stale_epoch);
    try std.testing.expectEqual(RenderCore.PrepareState.ready, runtime.prepare(.{ .ready = .{ .source = selection_source, .geometry = .{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    } } }));

    var dirty_source = clean_source;
    dirty_source.vt_epoch = 2;
    dirty_source.dirty_epoch = 2;
    const dirty_receipt = runtime.acceptSource(dirty_source);
    try std.testing.expect(dirty_receipt.dirty);
    try std.testing.expect(dirty_receipt.stale_epoch);
    try std.testing.expectEqual(RenderCore.PrepareState.ready, runtime.prepare(.{ .ready = .{ .source = dirty_source, .geometry = .{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    } } }));

    var scroll_source = clean_source;
    scroll_source.scrollback_view_invalidated = true;
    scroll_source.dirty_epoch = 2;
    const scroll_receipt = runtime.acceptSource(scroll_source);
    try std.testing.expect(scroll_receipt.dirty);
    try std.testing.expect(scroll_receipt.viewport_dirty);
    try std.testing.expectEqual(RenderCore.PrepareState.ready, runtime.prepare(.{ .ready = .{ .source = scroll_source, .geometry = .{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    } } }));

    var focus_source = clean_source;
    focus_source.focused = false;
    focus_source.dirty_epoch = 2;
    const focus_receipt = runtime.acceptSource(focus_source);
    try std.testing.expect(focus_receipt.dirty);
    try std.testing.expect(!focus_receipt.focus_active);

    const submitted = frame_pipeline.SubmittedFrame{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 7,
        .content_valid = true,
    };
    try std.testing.expectEqual(RenderCore.SubmitState.idle, runtime.submit(.{ .idle = {} }));
    try std.testing.expectEqual(RenderCore.SubmitState.present, runtime.submit(.{ .ready = .{
        .prepared = .{
            .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 3, .damage_base_seq = 10, .damage_kind = .scroll },
            .required_base_seq = 10,
            .required_target_epoch = 7,
        },
        .submitted = submitted,
    } }));
    try std.testing.expectEqual(RenderCore.SubmitState.stale_base, runtime.submit(.{ .ready = .{
        .prepared = .{
            .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 3, .damage_base_seq = 11, .damage_kind = .partial },
            .required_base_seq = 11,
            .required_target_epoch = 7,
        },
        .submitted = submitted,
    } }));
    try std.testing.expectEqual(RenderCore.SubmitState.stale_target, runtime.submit(.{ .ready = .{
        .prepared = .{
            .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 3, .damage_base_seq = 10, .damage_kind = .partial },
            .required_base_seq = 10,
            .required_target_epoch = 8,
        },
        .submitted = submitted,
    } }));
    try std.testing.expectEqual(RenderCore.SubmitState.geometry_changed, runtime.submit(.{ .ready = .{
        .prepared = .{
            .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 4, .damage_base_seq = 10, .damage_kind = .partial },
            .required_base_seq = 10,
            .required_target_epoch = 7,
        },
        .submitted = submitted,
    } }));
}
