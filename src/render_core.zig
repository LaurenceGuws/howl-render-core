//! Responsibility: provide a single render-core owner surface.
//! Ownership: render-core orchestration API.
//! Reason: keep hosts/backends on one coherent entrypoint.

const std = @import("std");
const types = @import("types.zig");
const frame_input = @import("frame_input.zig");
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
        published: bool,
        queued: bool,
        damage_kind: frame_pipeline.DamageKind,
        source_seq: u64,
        geometry_epoch: u64,
    };
    pub const GeometryReceipt = struct {
        changed: bool,
        render_px: types.PixelSize,
        grid_px: types.PixelSize,
        cell_px: types.CellSize,
        geometry_epoch: u64,
    };
    // Render-core retains only render-relevant publication state; title and output proof stay out of damage policy.
    pub const Publication = struct {
        snapshot: FrameSnapshot = .{},
        cols: u16 = 0,
        rows: u16 = 0,
        scrollback_count: u64 = 0,
        scrollback_offset: u64 = 0,
        selection_anchor_depth: ?u64 = null,
        selection_anchor_col: ?u16 = null,
        selection_current_depth: ?u64 = null,
        selection_current_col: ?u16 = null,
        focused: bool = true,
        hover_link_id: u32 = 0,
        hover_underline_style: surface.UnderlineStyle = .straight,
        snapshot_seq: u64 = 0,
        vt_epoch: u64 = 0,
        last_alt_screen: bool = false,
        damage_kind: frame_pipeline.DamageKind = .none,

        pub fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
            self.snapshot.deinit(allocator);
            self.* = .{};
        }

        pub fn copyFrom(self: *Publication, allocator: std.mem.Allocator, source: SourceView, damage_kind: frame_pipeline.DamageKind) !void {
            try self.snapshot.copyFrom(allocator, source.snapshot);
            self.cols = source.cols;
            self.rows = source.rows;
            self.scrollback_count = source.scrollback_count;
            self.scrollback_offset = source.scrollback_offset;
            self.selection_anchor_depth = source.selection_anchor_depth;
            self.selection_anchor_col = source.selection_anchor_col;
            self.selection_current_depth = source.selection_current_depth;
            self.selection_current_col = source.selection_current_col;
            self.focused = source.focused;
            self.hover_link_id = source.hover_link_id;
            self.hover_underline_style = source.hover_underline_style;
            self.snapshot_seq = source.snapshot_seq;
            self.vt_epoch = source.vt_epoch;
            self.last_alt_screen = source.last_alt_screen;
            self.damage_kind = damage_kind;
        }

        pub fn selectionActive(self: Publication) bool {
            return self.selection_anchor_depth != null and
                self.selection_anchor_col != null and
                self.selection_current_depth != null and
                self.selection_current_col != null;
        }
    };
    pub const RenderRuntime = struct {
        allocator: std.mem.Allocator,
        surface_owner: FrameQueue.TerminalSurface = .{},
        render_px: types.PixelSize = .{ .width = 0, .height = 0 },
        grid_px: types.PixelSize = .{ .width = 0, .height = 0 },
        cell_px: types.CellSize = .{ .width = 0, .height = 0 },
        font_size_px: u16 = 1,
        geometry_epoch: u64 = 0,
        publication: ?Publication = null,
        pending_publication: bool = false,

        pub fn init(allocator: std.mem.Allocator) RenderRuntime {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *RenderRuntime) void {
            if (self.publication) |*publication| publication.deinit(self.allocator);
            self.publication = null;
            self.pending_publication = false;
        }

        pub fn setFontSizePx(self: *RenderRuntime, font_size_px: u16) void {
            self.font_size_px = @max(font_size_px, 1);
        }

        pub fn acceptSource(self: *RenderRuntime, source: SourceView) SourceReceipt {
            std.debug.assert(source.cols > 0);
            std.debug.assert(source.rows > 0);
            std.debug.assert(source.snapshot.cols == source.cols);
            std.debug.assert(source.snapshot.rows == source.rows);
            std.debug.assert(source.scrollback_offset <= source.scrollback_count);

            const damage_kind = self.classifySource(source);
            const published = damage_kind != .none;
            if (published) {
                if (self.publication == null) {
                    self.publication = Publication{};
                    if (self.publication) |*publication| {
                        errdefer publication.deinit(self.allocator);
                        publication.snapshot = FrameSnapshot.init(self.allocator, source.rows, source.cols) catch @panic("render publication allocation failed");
                    }
                } else if (self.publication) |*publication| {
                    if (publication.snapshot.rows != source.rows or publication.snapshot.cols != source.cols) {
                        publication.snapshot.deinit(self.allocator);
                        publication.snapshot = FrameSnapshot.init(self.allocator, source.rows, source.cols) catch @panic("render publication allocation failed");
                    }
                }
                if (self.publication) |*publication| {
                    publication.copyFrom(self.allocator, source, damage_kind) catch @panic("render publication allocation failed");
                }
                self.pending_publication = true;
            }
            return .{
                .published = published,
                .queued = self.pending_publication,
                .damage_kind = damage_kind,
                .source_seq = source.snapshot_seq,
                .geometry_epoch = self.geometry_epoch,
            };
        }

        pub fn syncGeometry(self: *RenderRuntime, layout: Geometry) GeometryReceipt {
            std.debug.assert(layout.render_px.width > 0);
            std.debug.assert(layout.render_px.height > 0);
            std.debug.assert(layout.grid_px.width > 0);
            std.debug.assert(layout.grid_px.height > 0);
            std.debug.assert(layout.cell_px.width > 0);
            std.debug.assert(layout.cell_px.height > 0);

            const changed = self.geometry_epoch == 0 or
                self.render_px.width != layout.render_px.width or
                self.render_px.height != layout.render_px.height or
                self.grid_px.width != layout.grid_px.width or
                self.grid_px.height != layout.grid_px.height or
                self.cell_px.width != layout.cell_px.width or
                self.cell_px.height != layout.cell_px.height;
            if (changed) {
                self.geometry_epoch +%= 1;
                self.render_px = layout.render_px;
                self.grid_px = layout.grid_px;
                self.cell_px = layout.cell_px;
                self.surface_owner.bindTargetEpoch(self.geometry_epoch);
            }
            return .{
                .changed = changed,
                .render_px = self.render_px,
                .grid_px = self.grid_px,
                .cell_px = self.cell_px,
                .geometry_epoch = self.geometry_epoch,
            };
        }

        pub fn prepare(self: *RenderRuntime) ?frame_pipeline.RenderRequest {
            if (self.pending_publication) {
                const publication = self.publication orelse return null;
                const token = self.makeTokenFromPublication(publication);
                _ = self.surface_owner.publishSnapshot(token, .opportunistic);
                self.pending_publication = false;
            }
            return self.surface_owner.beginSynchronousRender();
        }

        pub fn publishPrepared(self: *RenderRuntime, prepared: frame_pipeline.PreparedFrame) u64 {
            return self.surface_owner.publishPrepared(prepared);
        }

        pub fn submit(self: *RenderRuntime) FrameQueue.TerminalSurface.SubmitDecision {
            return self.surface_owner.takeValidatedSubmit();
        }

        pub fn acceptSubmitted(self: *RenderRuntime, frame: frame_pipeline.SubmittedFrame) void {
            self.surface_owner.acceptSubmitted(frame);
        }

        pub fn markPresented(self: *RenderRuntime) void {
            self.surface_owner.markPresented();
        }

        pub fn surfaceQuery(self: *const RenderRuntime) SurfaceQuery {
            return .{
                .render_px = self.render_px,
                .grid_px = self.grid_px,
                .cell_px = self.cell_px,
                .font_size_px = self.font_size_px,
                .epoch = self.geometry_epoch,
            };
        }

        fn classifySource(self: *const RenderRuntime, source: SourceView) frame_pipeline.DamageKind {
            const prior = self.publication orelse return .full;
            if (source.snapshot_seq == prior.snapshot_seq) return .none;
            if (source.cols != prior.cols or source.rows != prior.rows) return .full;
            if (source.vt_epoch != prior.vt_epoch) return .full;
            if (source.last_alt_screen != prior.last_alt_screen) return .full;
            if (source.scrollback_count != prior.scrollback_count or source.scrollback_offset != prior.scrollback_offset) return .scroll;
            if (source.selectionActive() != prior.selectionActive() or
                source.focused != prior.focused or
                source.hover_link_id != prior.hover_link_id or
                source.hover_underline_style != prior.hover_underline_style)
            {
                return .partial;
            }
            return .none;
        }

        fn makeTokenFromPublication(self: *const RenderRuntime, publication: Publication) frame_pipeline.SnapshotToken {
            return .{
                .snapshot_seq = publication.snapshot_seq,
                .dirty_epoch = publication.snapshot_seq,
                .geometry_epoch = self.geometry_epoch,
                .damage_base_seq = if (self.surface_owner.submittedToken()) |token| token.snapshot_seq else 0,
                .damage_kind = publication.damage_kind,
            };
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
        last_alt_screen: bool = false,

        pub fn selectionActive(self: SourceView) bool {
            return self.selection_anchor_depth != null and
                self.selection_anchor_col != null and
                self.selection_current_depth != null and
                self.selection_current_col != null;
        }
    };
    pub const Geometry = struct {
        render_px: types.PixelSize,
        grid_px: types.PixelSize,
        cell_px: types.CellSize,
    };
    pub const SurfaceQuery = struct {
        render_px: types.PixelSize,
        grid_px: types.PixelSize,
        cell_px: types.CellSize,
        font_size_px: u16,
        epoch: u64,
    };
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

test "render runtime owns source publication and retained-frame queue" {
    var runtime = RenderCore.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var snapshot = try RenderCore.FrameSnapshot.init(std.testing.allocator, 2, 3);
    defer snapshot.deinit(std.testing.allocator);
    for (snapshot.cells.items, 0..) |*cell, idx| cell.codepoint = @intCast('a' + idx);

    const first_geometry = runtime.syncGeometry(.{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(first_geometry.changed);
    try std.testing.expectEqual(@as(u64, 1), first_geometry.geometry_epoch);
    const query = runtime.surfaceQuery();
    try std.testing.expectEqual(@as(u16, 24), query.render_px.width);
    try std.testing.expectEqual(@as(u16, 32), query.render_px.height);
    try std.testing.expectEqual(@as(u16, 8), query.cell_px.width);
    try std.testing.expectEqual(@as(u16, 16), query.cell_px.height);
    try std.testing.expectEqual(@as(u64, 1), query.epoch);

    const clean_source = RenderCore.SourceView{
        .snapshot = &snapshot,
        .cols = 3,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .hover_link_id = 0,
        .hover_underline_style = .straight,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .last_alt_screen = false,
    };
    const clean_receipt = runtime.acceptSource(clean_source);
    try std.testing.expect(clean_receipt.published);
    try std.testing.expect(clean_receipt.queued);
    try std.testing.expectEqual(frame_pipeline.DamageKind.full, clean_receipt.damage_kind);
    try std.testing.expect(runtime.publication != null);
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication.?.snapshot.cells.items[5].codepoint);
    const request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), request.known_target_epoch);
    try std.testing.expectEqual(frame_pipeline.DamageKind.full, request.token.damage_kind);
    runtime.acceptSubmitted(.{
        .token = request.token,
        .target_epoch = request.known_target_epoch,
        .content_valid = true,
    });
    try std.testing.expect(runtime.prepare() == null);

    const duplicate_source = RenderCore.SourceView{
        .snapshot = &snapshot,
        .cols = 3,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .hover_link_id = 0,
        .hover_underline_style = .straight,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .last_alt_screen = false,
    };
    const duplicate_receipt = runtime.acceptSource(duplicate_source);
    try std.testing.expect(!duplicate_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.none, duplicate_receipt.damage_kind);
    try std.testing.expect(runtime.prepare() == null);

    var title_source = clean_source;
    title_source.snapshot_seq = 2;
    title_source.title = "terminal title changed";
    const title_receipt = runtime.acceptSource(title_source);
    try std.testing.expect(!title_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.none, title_receipt.damage_kind);
    try std.testing.expect(runtime.prepare() == null);

    var output_source = clean_source;
    output_source.snapshot_seq = 3;
    output_source.output_seen = true;
    const output_receipt = runtime.acceptSource(output_source);
    try std.testing.expect(!output_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.none, output_receipt.damage_kind);
    try std.testing.expect(runtime.prepare() == null);

    var republished_source = clean_source;
    republished_source.snapshot_seq = 4;
    republished_source.vt_epoch = 2;
    const republished_receipt = runtime.acceptSource(republished_source);
    try std.testing.expect(republished_receipt.published);
    try std.testing.expect(republished_receipt.queued);
    try std.testing.expectEqual(frame_pipeline.DamageKind.full, republished_receipt.damage_kind);
    const republished_request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 4), republished_request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication.?.snapshot.cells.items[5].codepoint);

    var scroll_source = clean_source;
    scroll_source.snapshot_seq = 5;
    scroll_source.vt_epoch = 2;
    scroll_source.scrollback_count = 2;
    scroll_source.scrollback_offset = 1;
    snapshot.clearDirty();
    snapshot.dirty = .partial;
    snapshot.scroll_up_rows = 1;
    snapshot.dirty_rows.items[1] = true;
    snapshot.dirty_cols_start.items[1] = 0;
    snapshot.dirty_cols_end.items[1] = 2;
    snapshot.cells.items[0].codepoint = 'c';
    snapshot.cells.items[1].codepoint = 'd';
    snapshot.cells.items[2].codepoint = 'e';
    snapshot.cells.items[3].codepoint = 'f';
    snapshot.cells.items[4].codepoint = 'X';
    snapshot.cells.items[5].codepoint = 'Y';
    const scroll_receipt = runtime.acceptSource(scroll_source);
    try std.testing.expect(scroll_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.scroll, scroll_receipt.damage_kind);
    const scroll_request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 5), scroll_request.token.snapshot_seq);
    try std.testing.expectEqual(frame_pipeline.DamageKind.scroll, scroll_request.token.damage_kind);
    try std.testing.expectEqual(@as(u21, 'd'), runtime.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), runtime.publication.?.snapshot.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication.?.snapshot.cells.items[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), runtime.publication.?.snapshot.cells.items[4].codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), runtime.publication.?.snapshot.cells.items[5].codepoint);

    var selection_source = scroll_source;
    selection_source.snapshot_seq = 6;
    selection_source.selection_anchor_depth = 2;
    selection_source.selection_anchor_col = 1;
    selection_source.selection_current_depth = 2;
    selection_source.selection_current_col = 2;
    snapshot.clearDirty();
    snapshot.dirty = .partial;
    snapshot.dirty_rows.items[0] = true;
    snapshot.dirty_cols_start.items[0] = 2;
    snapshot.dirty_cols_end.items[0] = 2;
    snapshot.cells.items[2].codepoint = 'Q';
    const selection_receipt = runtime.acceptSource(selection_source);
    try std.testing.expect(selection_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.partial, selection_receipt.damage_kind);
    try std.testing.expectEqual(@as(u21, 'Q'), runtime.publication.?.snapshot.cells.items[2].codepoint);

    var focus_source = selection_source;
    focus_source.snapshot_seq = 7;
    focus_source.focused = false;
    const focus_receipt = runtime.acceptSource(focus_source);
    try std.testing.expect(focus_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.partial, focus_receipt.damage_kind);

    var hover_source = focus_source;
    hover_source.snapshot_seq = 8;
    hover_source.hover_link_id = 7;
    const hover_receipt = runtime.acceptSource(hover_source);
    try std.testing.expect(hover_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.partial, hover_receipt.damage_kind);

    var dirty_source = hover_source;
    dirty_source.snapshot_seq = 9;
    dirty_source.vt_epoch = 4;
    const dirty_receipt = runtime.acceptSource(dirty_source);
    try std.testing.expect(dirty_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.full, dirty_receipt.damage_kind);

    const submitted = frame_pipeline.SubmittedFrame{
        .token = .{ .snapshot_seq = 6, .dirty_epoch = 6, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 1,
        .content_valid = true,
    };
    runtime.acceptSubmitted(submitted);
    _ = runtime.publishPrepared(.{
        .token = .{ .snapshot_seq = 7, .dirty_epoch = 7, .geometry_epoch = 1, .damage_base_seq = 6, .damage_kind = .scroll },
        .required_base_seq = 6,
        .required_target_epoch = 1,
    });
    switch (runtime.submit()) {
        .submit => |prepared| try std.testing.expectEqual(@as(u64, 7), prepared.token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }

    const same_geometry = runtime.syncGeometry(.{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(!same_geometry.changed);
}
