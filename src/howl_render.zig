
const std = @import("std");
const input = @import("frame/input.zig");
const pipeline = @import("frame/pipeline.zig");
const queue = @import("frame/queue.zig");
const snapshot = @import("frame/snapshot.zig");
const surface = @import("frame/surface.zig");
const contract = @import("text/contract.zig");
const text_pipeline = @import("text/pipeline.zig");
const text = @import("text/text.zig");
const text_support = @import("text/ft_hb_support.zig");
const text_glyph_raster = @import("text/ft_hb_glyph_raster.zig");
const Render = @This();

    const PixelSize = surface.PixelSize;
    const CellSize = surface.CellSize;
    const GridSize = surface.GridSize;
    const FramePixels = surface.FramePixels;
    pub const SurfaceSessionConfig = struct {
        surface_px: PixelSize,
        cell_px: CellSize,
        font_size_px: u16 = 16,
        font_path: ?[:0]const u8 = null,
    };
    pub const Rgba8 = contract.Rgba8;
    pub const FillRect = struct {
        x: i32,
        y: i32,
        width: u16,
        height: u16,
        color: Rgba8,
    };
    pub const GlyphQuad = struct {
        x: i32,
        y: i32,
        width: u16,
        height: u16,
        codepoint: u21,
        fg: Rgba8,
        bg: ?Rgba8 = null,
    };
    pub const AtlasUpload = struct {
        codepoint: u21,
        width: u16,
        height: u16,
    };
    pub const RenderStats = struct {
        fills: usize,
        glyphs: usize,
        atlas_uploads: usize,
        has_cursor: bool,
        full_redraw: bool,
    };
    pub const CellInput = contract.CellInput;
    pub const FrameTheme = input.FrameTheme;
    pub const OwnedFrameTextInput = input.OwnedFrameTextInput;
    pub const OwnedTextSceneInput = input.OwnedTextSceneInput;
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
    pub const FrameSnapshot = snapshot.Snapshot;
    pub const FrameSnapshotDirty = snapshot.Dirty;
    pub const FrameSnapshotDamage = snapshot.Damage;
    pub const FrameSnapshotDirtyView = snapshot.DirtyView;
    const SourceView = snapshot.SourceView;
    const SourceResponse = snapshot.SourceResponse;
    pub const PrepareMetrics = struct {
        sync_us: u64 = 0,
        copy_us: u64 = 0,
        us: u64 = 0,
        surface_us: u64 = 0,
        input_us: u64 = 0,
        sparse_us: u64 = 0,
        clusters_us: u64 = 0,
        resolve_us: u64 = 0,
        shape_us: u64 = 0,
        group_us: u64 = 0,
        scene_us: u64 = 0,
        raster_us: u64 = 0,
        atlas_us: u64 = 0,
    };
    pub const RenderMetrics = struct {
        sync_us: u64 = 0,
        copy_us: u64 = 0,
        render_us: u64 = 0,
        glyphs: u64 = 0,
        fills: u64 = 0,
        clear_fills: u64 = 0,
        background_fills: u64 = 0,
        decoration_fills: u64 = 0,
        cursor_fills: u64 = 0,
        uploads: u64 = 0,
        face_checks: u64 = 0,
        face_cache_hits: u64 = 0,
        shape_requests: u64 = 0,
        shape_cache_hits: u64 = 0,
        fallback_hits: u64 = 0,
        fallback_misses: u64 = 0,
        missing_glyphs: u64 = 0,
    };
    pub const Metrics = queue.TerminalSurface.Metrics;
    const GeometryResponse = surface.GeometryResponse;
    // render retains only render-relevant publication state; title and output proof stay out of damage policy.
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
        damage_kind: pipeline.DamageKind = .none,

        pub fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
            self.snapshot.deinit(allocator);
            self.* = .{};
        }

        pub fn copyFrom(self: *Publication, allocator: std.mem.Allocator, source: SourceView, damage_kind: pipeline.DamageKind) !void {
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
    pub const PublicationState = struct {
        publication: ?Publication = null,
        pending: bool = false,

        pub fn deinit(self: *PublicationState, allocator: std.mem.Allocator) void {
            if (self.publication) |*publication| publication.deinit(allocator);
            self.* = .{};
        }

        pub fn acceptSource(
            self: *PublicationState,
            allocator: std.mem.Allocator,
            source: SourceView,
            geometry_epoch: u64,
        ) SourceResponse {
            const damage_kind = self.classify(source);
            const published = damage_kind != .none;
            if (published) {
                self.updatePublication(allocator, source, damage_kind);
                self.pending = true;
            }
            return .{
                .published = published,
                .queued = self.pending,
                .damage_kind = damage_kind,
                .source_seq = source.snapshot_seq,
                .geometry_epoch = geometry_epoch,
            };
        }

        pub fn takePendingToken(
            self: *PublicationState,
            geometry_epoch: u64,
            submitted_token: ?pipeline.SnapshotToken,
        ) ?pipeline.SnapshotToken {
            if (!self.pending) return null;
            const publication = self.publication orelse return null;
            std.debug.assert(publication.snapshot.cols == publication.cols);
            std.debug.assert(publication.snapshot.rows == publication.rows);
            std.debug.assert(publication.damage_kind != .none);
            self.pending = false;
            return .{
                .snapshot_seq = publication.snapshot_seq,
                .dirty_epoch = publication.snapshot_seq,
                .geometry_epoch = geometry_epoch,
                .damage_base_seq = if (submitted_token) |token| token.snapshot_seq else 0,
                .damage_kind = publication.damage_kind,
            };
        }

        pub fn hasPending(self: *const PublicationState) bool {
            return self.pending;
        }

        fn updatePublication(
            self: *PublicationState,
            allocator: std.mem.Allocator,
            source: SourceView,
            damage_kind: pipeline.DamageKind,
        ) void {
            self.ensureSnapshot(allocator, source.rows, source.cols);
            const publication = &(self.publication orelse unreachable);
            publication.copyFrom(allocator, source, damage_kind) catch @panic("render publication allocation failed");
            std.debug.assert(publication.snapshot.cols == source.cols);
            std.debug.assert(publication.snapshot.rows == source.rows);
            std.debug.assert(publication.damage_kind == damage_kind);
        }

        fn ensureSnapshot(self: *PublicationState, allocator: std.mem.Allocator, rows: u16, cols: u16) void {
            if (self.publication == null) {
                self.publication = Publication{};
                const publication = &(self.publication orelse unreachable);
                publication.snapshot = FrameSnapshot.init(allocator, rows, cols) catch @panic("render publication allocation failed");
                return;
            }
            const publication = &(self.publication orelse unreachable);
            if (publication.snapshot.rows == rows and publication.snapshot.cols == cols) return;
            publication.snapshot.deinit(allocator);
            publication.snapshot = FrameSnapshot.init(allocator, rows, cols) catch @panic("render publication allocation failed");
        }

        fn classify(self: *const PublicationState, source: SourceView) pipeline.DamageKind {
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
    };
    pub const RenderRuntime = struct {
        pub const Metrics = Render.Metrics;
        allocator: std.mem.Allocator,
        surface_owner: FrameQueue.TerminalSurface = .{},
        render_px: PixelSize = .{ .width = 0, .height = 0 },
        grid_px: PixelSize = .{ .width = 0, .height = 0 },
        cell_px: CellSize = .{ .width = 0, .height = 0 },
        font_size_px: u16 = 1,
        geometry_epoch: u64 = 0,
        publication_state: PublicationState = .{},

        pub fn init(allocator: std.mem.Allocator) RenderRuntime {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *RenderRuntime) void {
            self.publication_state.deinit(self.allocator);
        }

        pub fn setFontSizePx(self: *RenderRuntime, font_size_px: u16) void {
            self.font_size_px = @max(font_size_px, 1);
        }

        pub fn acceptSource(self: *RenderRuntime, source: SourceView) SourceResponse {
            std.debug.assert(source.cols > 0);
            std.debug.assert(source.rows > 0);
            std.debug.assert(source.snapshot.cols == source.cols);
            std.debug.assert(source.snapshot.rows == source.rows);
            std.debug.assert(source.scrollback_offset <= source.scrollback_count);
            return self.publication_state.acceptSource(self.allocator, source, self.geometry_epoch);
        }

        pub fn syncGeometry(self: *RenderRuntime, layout: Geometry) GeometryResponse {
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

        pub fn prepare(self: *RenderRuntime) ?pipeline.RenderRequest {
            if (self.publication_state.takePendingToken(self.geometry_epoch, self.surface_owner.submittedToken())) |token| {
                _ = self.surface_owner.publishSnapshot(token, .opportunistic);
            }
            return self.surface_owner.takePrepare();
        }

        pub fn publishPrepared(self: *RenderRuntime, prepared: pipeline.PreparedFrame) u64 {
            std.debug.assert(prepared.token.geometry_epoch == self.geometry_epoch);
            return self.surface_owner.publishPrepared(prepared);
        }

        pub fn submit(self: *RenderRuntime) FrameQueue.TerminalSurface.SubmitDecision {
            return switch (self.surface_owner.takeSubmitTransition()) {
                .idle => .idle,
                .stale => |token| .{ .stale = token },
                .submit => |prepared| .{ .submit = prepared },
                .rejected => |rejected| blk: {
                    self.surface_owner.requestFullPrepare(rejected.prepared.token);
                    break :blk .{ .needs_full_prepare = rejected.reason };
                },
            };
        }

        pub fn requestFullPrepare(self: *RenderRuntime, token: pipeline.SnapshotToken) void {
            self.surface_owner.requestFullPrepare(token);
        }

        pub fn acceptSubmitted(self: *RenderRuntime, frame: pipeline.SubmittedFrame) void {
            if (frame.token.geometry_epoch != self.geometry_epoch) {
                self.surface_owner.requestFullPrepare(frame.token);
                return;
            }
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

        pub fn takeMetrics(self: *RenderRuntime) Render.Metrics {
            return self.surface_owner.takeMetrics();
        }

    pub fn resetMetrics(self: *RenderRuntime) void {
        self.surface_owner.resetMetrics();
    }

    };
    pub const Geometry = struct {
        render_px: PixelSize,
        grid_px: PixelSize,
        cell_px: CellSize,
    };
    pub const SurfaceQuery = struct {
        render_px: PixelSize,
        grid_px: PixelSize,
        cell_px: CellSize,
        font_size_px: u16,
        epoch: u64,
    };
    pub const FramePipeline = pipeline;
    pub const FrameQueue = queue;
pub const SurfaceHandle = struct {
    texture_id: u32,
    width: u16,
    height: u16,
    epoch: u64,
};
pub const SurfaceLayout = struct {
    cell_px: CellSize,
    grid: GridSize,
};
pub const SurfaceExecutionReport = struct {
    texture_id: u32,
    raster_uploads_committed: usize,
    full_redraw: bool,
    scroll_up_px: u16,
    clear_draws: usize,
    background_draws: usize,
    sprite_draws: usize,
    decoration_draws: usize,
    cursor_draws: usize,
};
pub const DamageRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};
pub const SpriteBatchPassKind = enum(u8) {
    alpha,
    color,
};
pub const SpriteBatch = struct {
    atlas_page: u16,
    pass_kind: SpriteBatchPassKind,
    first_instance: u32,
    instance_count: u32,
};
pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: FramePipeline.RenderRequest,
    required_surface_epoch: u64,
    geometry_epoch: u64,
    atlas_page_slots: u32,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    surface_damage_rects: []DamageRect = &.{},
    buffer_damage_rects: []DamageRect = &.{},
    sprite_batches: []SpriteBatch = &.{},
    text_frame: Text.OwnedPreparedTextFrame,
    resolve: ResolveObservability = .{},
    prepare_metrics: PrepareMetrics = .{},

    pub fn deinit(self: *PreparedSurface) void {
        if (self.surface_damage_rects.len > 0) self.allocator.free(self.surface_damage_rects);
        if (self.buffer_damage_rects.len > 0) self.allocator.free(self.buffer_damage_rects);
        if (self.sprite_batches.len > 0) self.allocator.free(self.sprite_batches);
        self.text_frame.deinit();
        self.* = undefined;
    }

    pub fn damageKind(self: *const PreparedSurface) FramePipeline.DamageKind {
        if (self.text_frame.scene.scene.full_redraw) return .full;
        if (self.text_frame.scene.scene.scroll_up_px > 0) return .scroll;
        return .partial;
    }

    pub fn pipelineFrame(self: *const PreparedSurface) FramePipeline.PreparedFrame {
        const damage_kind = self.damageKind();
        const damage_base_seq = if (damage_kind == .partial or damage_kind == .scroll)
            self.request.token.damage_base_seq
        else
            0;
        return .{
            .token = .{
                .snapshot_seq = self.request.token.snapshot_seq,
                .dirty_epoch = self.request.token.dirty_epoch,
                .geometry_epoch = self.geometry_epoch,
                .damage_base_seq = damage_base_seq,
                .damage_kind = damage_kind,
            },
            .required_base_seq = damage_base_seq,
            .required_target_epoch = self.required_surface_epoch,
        };
    }
};
pub const SurfaceFeedback = struct {
    report: SurfaceExecutionReport,
    resolve: ResolveObservability,
    surface: SurfaceHandle,
    metrics: RenderMetrics,
    render_us: u64,
    content_valid: bool = true,

    pub fn damageKind(self: SurfaceFeedback) FramePipeline.DamageKind {
        if (self.report.full_redraw) return .full;
        if (self.report.scroll_up_px > 0) return .scroll;
        return .partial;
    }
};
    pub const BackendCaps = contract.BackendCaps;
    pub const FontStyle = contract.FontStyle;
    pub const TextPresentation = contract.TextPresentation;
    pub const FontMetrics = contract.FontMetrics;
    pub const CellMetrics = contract.CellMetrics;
    pub const GridMetrics = contract.GridMetrics;
    pub const FontFaceId = contract.FontFaceId;
    pub const CellTextId = contract.CellTextId;
    pub const SpriteKey = contract.SpriteKey;
    pub const CellText = contract.CellText;
    pub const LineTextCache = contract.LineTextCache;
    pub const RenderableCell = contract.RenderableCell;
    pub const CellCluster = contract.CellCluster;
    pub const RunFont = contract.RunFont;
    pub const TextRun = contract.TextRun;
    pub const ResolvedRun = contract.ResolvedRun;
    pub const GlyphInstance = contract.GlyphInstance;
    pub const GlyphPlacement = contract.GlyphPlacement;
    pub const GlyphGroupKind = contract.GlyphGroupKind;
    pub const GlyphGroup = contract.GlyphGroup;
    pub const SpriteColorMode = contract.SpriteColorMode;
    pub const SpritePosition = contract.SpritePosition;
    pub const TextSpriteDraw = contract.TextSpriteDraw;
    pub const TextBackgroundDraw = contract.TextBackgroundDraw;
    pub const TextClearDraw = contract.TextClearDraw;
    pub const TextCursorDraw = contract.TextCursorDraw;
    pub const DecorationKind = contract.DecorationKind;
    pub const TextDecorationDraw = contract.TextDecorationDraw;
    pub const SpriteRasterKind = contract.SpriteRasterKind;
    pub const DecorationSpriteRaster = contract.DecorationSpriteRaster;
    pub const SpriteRasterRequest = contract.SpriteRasterRequest;
    pub const TextScene = contract.TextScene;
    pub const SpecialSpriteRoute = contract.SpecialSpriteRoute;
    pub const TextCluster = contract.TextCluster;
    pub const ShapedGlyph = contract.ShapedGlyph;
    pub const ShapedRun = contract.ShapedRun;
    pub const MissingGlyphReason = contract.MissingGlyphReason;
    pub const MissingGlyph = contract.MissingGlyph;
    pub const ResolveStage = text_pipeline.ResolveStage;
    pub const ResolveRequest = text_pipeline.ResolveRequest;
    pub const ResolveHit = text_pipeline.ResolveHit;
    pub const ResolveMiss = text_pipeline.ResolveMiss;
    pub const ResolveResult = text_pipeline.ResolveResult;
    pub const ResolveCounters = text_pipeline.ResolveCounters;
    pub const ResolveObservability = struct {
        counters: ResolveCounters = .{},
        stage: ResolveStage = .style_policy,
    };
    pub const TextPrepareCounters = text_pipeline.TextPrepareCounters;
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
    pub const FrameGeometryError = error{
        InvalidSurfaceSize,
        InvalidGridSize,
    };
pub fn vtStateToTextSceneInput(
    allocator: std.mem.Allocator,
    state: anytype,
) !OwnedTextSceneInput {
        return input.vtStateToTextSceneInput(allocator, state);
}

pub fn vtStateToFrameTextInput(
    allocator: std.mem.Allocator,
    state: anytype,
) !OwnedFrameTextInput {
        return input.vtStateToFrameTextInput(allocator, state);
}

pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
        const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
        const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
        return .{
            .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
            .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
        };
}

pub fn deriveGridForFrame(render_px: PixelSize, grid_px: PixelSize, cell_px: CellSize) FrameGeometryError!GridSize {
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        return deriveGridSize(grid_px, cell_px);
}

test "render runtime owns source publication and retained-frame queue" {
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var frame_snapshot_value = try Render.FrameSnapshot.init(std.testing.allocator, 2, 3);
    defer frame_snapshot_value.deinit(std.testing.allocator);
    for (frame_snapshot_value.cells.items, 0..) |*cell, idx| cell.codepoint = @intCast('a' + idx);

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

    const clean_source = Render.SourceView{
        .snapshot = &frame_snapshot_value,
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
    const clean_publish = runtime.acceptSource(clean_source);
    try std.testing.expect(clean_publish.published);
    try std.testing.expect(clean_publish.queued);
    try std.testing.expectEqual(pipeline.DamageKind.full, clean_publish.damage_kind);
    try std.testing.expect(runtime.publication_state.publication != null);
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication_state.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication_state.publication.?.snapshot.cells.items[5].codepoint);
    const request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), request.known_target_epoch);
    try std.testing.expectEqual(pipeline.DamageKind.full, request.token.damage_kind);
    runtime.acceptSubmitted(.{
        .token = request.token,
        .target_epoch = request.known_target_epoch,
        .content_valid = true,
    });
    try std.testing.expect(runtime.prepare() == null);

    const duplicate_source = Render.SourceView{
        .snapshot = &frame_snapshot_value,
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
    const duplicate_publish = runtime.acceptSource(duplicate_source);
    try std.testing.expect(!duplicate_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.none, duplicate_publish.damage_kind);
    try std.testing.expect(runtime.prepare() == null);

    var republished_source = clean_source;
    republished_source.snapshot_seq = 2;
    republished_source.vt_epoch = 2;
    const republished_publish = runtime.acceptSource(republished_source);
    try std.testing.expect(republished_publish.published);
    try std.testing.expect(republished_publish.queued);
    try std.testing.expectEqual(pipeline.DamageKind.full, republished_publish.damage_kind);
    const republished_request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), republished_request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication_state.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication_state.publication.?.snapshot.cells.items[5].codepoint);

    var scroll_source = clean_source;
    scroll_source.snapshot_seq = 3;
    scroll_source.vt_epoch = 2;
    scroll_source.scrollback_count = 2;
    scroll_source.scrollback_offset = 1;
    frame_snapshot_value.clearDirty();
    frame_snapshot_value.dirty = .partial;
    frame_snapshot_value.scroll_up_rows = 1;
    frame_snapshot_value.dirty_rows.items[1] = true;
    frame_snapshot_value.dirty_cols_start.items[1] = 0;
    frame_snapshot_value.dirty_cols_end.items[1] = 2;
    frame_snapshot_value.cells.items[0].codepoint = 'c';
    frame_snapshot_value.cells.items[1].codepoint = 'd';
    frame_snapshot_value.cells.items[2].codepoint = 'e';
    frame_snapshot_value.cells.items[3].codepoint = 'f';
    frame_snapshot_value.cells.items[4].codepoint = 'X';
    frame_snapshot_value.cells.items[5].codepoint = 'Y';
    const scroll_publish = runtime.acceptSource(scroll_source);
    try std.testing.expect(scroll_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.scroll, scroll_publish.damage_kind);
    const scroll_request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 3), scroll_request.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.scroll, scroll_request.token.damage_kind);
    try std.testing.expectEqual(@as(u21, 'd'), runtime.publication_state.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), runtime.publication_state.publication.?.snapshot.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication_state.publication.?.snapshot.cells.items[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), runtime.publication_state.publication.?.snapshot.cells.items[4].codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), runtime.publication_state.publication.?.snapshot.cells.items[5].codepoint);

    var selection_source = scroll_source;
    selection_source.snapshot_seq = 6;
    selection_source.selection_anchor_depth = 2;
    selection_source.selection_anchor_col = 1;
    selection_source.selection_current_depth = 2;
    selection_source.selection_current_col = 2;
    frame_snapshot_value.clearDirty();
    frame_snapshot_value.dirty = .partial;
    frame_snapshot_value.dirty_rows.items[0] = true;
    frame_snapshot_value.dirty_cols_start.items[0] = 2;
    frame_snapshot_value.dirty_cols_end.items[0] = 2;
    frame_snapshot_value.cells.items[2].codepoint = 'Q';
    const selection_publish = runtime.acceptSource(selection_source);
    try std.testing.expect(selection_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.partial, selection_publish.damage_kind);
    try std.testing.expectEqual(@as(u21, 'Q'), runtime.publication_state.publication.?.snapshot.cells.items[2].codepoint);

    var focus_source = selection_source;
    focus_source.snapshot_seq = 7;
    focus_source.focused = false;
    const focus_publish = runtime.acceptSource(focus_source);
    try std.testing.expect(focus_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.partial, focus_publish.damage_kind);

    var hover_source = focus_source;
    hover_source.snapshot_seq = 8;
    hover_source.hover_link_id = 7;
    const hover_publish = runtime.acceptSource(hover_source);
    try std.testing.expect(hover_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.partial, hover_publish.damage_kind);

    var dirty_source = hover_source;
    dirty_source.snapshot_seq = 9;
    dirty_source.vt_epoch = 4;
    const dirty_publish = runtime.acceptSource(dirty_source);
    try std.testing.expect(dirty_publish.published);
    try std.testing.expectEqual(pipeline.DamageKind.full, dirty_publish.damage_kind);

    const submitted = pipeline.SubmittedFrame{
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

test "render runtime metrics stay owned by render" {
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var frame_snapshot_value = try Render.FrameSnapshot.init(std.testing.allocator, 2, 2);
    defer frame_snapshot_value.deinit(std.testing.allocator);
    frame_snapshot_value.clearDirty();

    const empty_metrics = runtime.takeMetrics();
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.prepare_requests);
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.submit_valid);

    const geometry_sync = runtime.syncGeometry(.{
        .render_px = .{ .width = 16, .height = 32 },
        .grid_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(geometry_sync.changed);
    try std.testing.expectEqual(@as(u64, 1), geometry_sync.geometry_epoch);

    const source = Render.SourceView{
        .snapshot = &frame_snapshot_value,
        .cols = 2,
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
    const publish = runtime.acceptSource(source);
    try std.testing.expect(publish.published);
    try std.testing.expect(publish.queued);
    const request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    _ = runtime.publishPrepared(.{
        .token = request.token,
        .required_base_seq = request.token.damage_base_seq,
        .required_target_epoch = request.known_target_epoch,
    });
    switch (runtime.submit()) {
        .submit => |prepared| runtime.acceptSubmitted(.{
            .token = prepared.token,
            .target_epoch = prepared.required_target_epoch,
            .content_valid = true,
        }),
        else => return error.TestUnexpectedResult,
    }

    const positive = runtime.takeMetrics();
    try std.testing.expect(positive.snapshot_publishes > 0);
    try std.testing.expect(positive.prepare_requests > 0);
    try std.testing.expect(positive.prepare_takes > 0);
    try std.testing.expect(positive.submit_takes > 0);

    runtime.resetMetrics();
    const reset = runtime.takeMetrics();
    try std.testing.expectEqual(@as(u64, 0), reset.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 0), reset.prepare_requests);

    var stale = source;
    stale.snapshot_seq = 2;
    stale.scrollback_count = 1;
    stale.scrollback_offset = 1;
    const stale_publish = runtime.acceptSource(stale);
    try std.testing.expect(stale_publish.published);
    try std.testing.expect(stale_publish.queued);
    const stale_request = runtime.prepare() orelse return error.TestUnexpectedResult;
    _ = runtime.publishPrepared(.{
        .token = .{
            .snapshot_seq = stale_request.token.snapshot_seq,
            .dirty_epoch = stale_request.token.dirty_epoch,
            .geometry_epoch = stale_request.token.geometry_epoch,
            .damage_base_seq = stale_request.token.damage_base_seq,
            .damage_kind = stale_request.token.damage_kind,
        },
        .required_base_seq = stale_request.token.damage_base_seq,
        .required_target_epoch = stale_request.known_target_epoch + 1,
    });
    switch (runtime.submit()) {
        .needs_full_prepare => {},
        else => return error.TestUnexpectedResult,
    }

    const rejected = runtime.takeMetrics();
    try std.testing.expect(rejected.submit_rejected > 0);
    try std.testing.expect(rejected.full_prepare_requests > 0);
}

const render = @This();

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const SurfaceSession = struct {
    config: render.SurfaceSessionConfig,
    text_state: text_support.State,
    mutex: ThreadMutex = .{},
    text_preparer: ?render.Text.TextFramePreparer = null,
    prepared: ?FrameRecord = null,
    resolve: render.ResolveObservability = .{},
    target_valid: bool = false,
    target_epoch: u64 = 0,

    pub const FrameLayout = SurfaceLayout;

    pub const PreparedTimings = struct {
        input_us: u64 = 0,
        sparse_us: u64 = 0,
        clusters_us: u64 = 0,
        resolve_us: u64 = 0,
        shape_us: u64 = 0,
        group_us: u64 = 0,
        scene_us: u64 = 0,
        raster_us: u64 = 0,
        atlas_us: u64 = 0,
    };

    pub const DamageKind = enum {
        partial,
        scroll,
        full,
    };

    pub const SubmittedReport = SurfaceExecutionReport;
    pub const SurfaceExecutionInput = struct {
        surface: render.SurfaceHandle,
        uploads_committed: usize,
        render_us: u64,
        content_valid: bool = true,
    };

    pub const FrameRecord = struct {
        render_seq: u64,
        render_dirty_epoch: u64,
        geometry_epoch: u64,
        prepare_metrics: render.PrepareMetrics,
        resolve: render.ResolveObservability,
        prepared: PreparedSurface,

        pub fn deinit(self: *FrameRecord) void {
            self.prepared.deinit();
            self.* = undefined;
        }

        pub fn pipelineFrame(self: *const FrameRecord) render.FramePipeline.PreparedFrame {
            return self.prepared.pipelineFrame();
        }

        pub fn renderMetrics(self: *const FrameRecord, feedback: SurfaceFeedback, render_us: u64) render.RenderMetrics {
            const report = feedback.report;
            const counters = feedback.resolve.counters;
            return .{
                .sync_us = self.prepare_metrics.sync_us,
                .copy_us = self.prepare_metrics.copy_us,
                .render_us = render_us,
                .glyphs = report.sprite_draws,
                .fills = report.clear_draws + report.background_draws + report.decoration_draws + report.cursor_draws,
                .clear_fills = report.clear_draws,
                .background_fills = report.background_draws,
                .decoration_fills = report.decoration_draws,
                .cursor_fills = report.cursor_draws,
                .uploads = report.raster_uploads_committed,
                .face_checks = counters.face_checks,
                .face_cache_hits = counters.face_cache_hits,
                .shape_requests = counters.shape_requests,
                .shape_cache_hits = counters.shape_cache_hits,
                .fallback_hits = counters.fallback_hits,
                .fallback_misses = counters.fallback_misses,
                .missing_glyphs = counters.missing_glyphs,
            };
        }

        pub fn submittedFrame(self: *const FrameRecord, feedback: SurfaceFeedback) render.FramePipeline.SubmittedFrame {
            return .{
                .token = .{
                    .snapshot_seq = self.render_seq,
                    .dirty_epoch = self.render_dirty_epoch,
                    .geometry_epoch = self.geometry_epoch,
                    .damage_base_seq = 0,
                    .damage_kind = feedback.damageKind(),
                },
                .target_epoch = feedback.surface.epoch,
                .surface_epoch = feedback.surface.epoch,
                .content_valid = feedback.content_valid,
            };
        }
    };

    pub const PrepareResult = enum {
        idle,
        prepared,
    };

    pub const SubmitResult = union(enum) {
        idle,
        stale,
        needs_full_prepare,
        rendered: render.SurfaceFeedback,
    };

    pub fn init(config: render.SurfaceSessionConfig) SurfaceSession {
        return .{
            .config = config,
            .text_state = text_support.State.init(std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *SurfaceSession) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.text_preparer) |*preparer| {
            preparer.deinit();
            self.text_preparer = null;
        }
        self.text_state.deinit();
    }

    pub fn setFontPath(self: *SurfaceSession, font_path: ?[:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.config.font_path = font_path;
        self.invalidatePreparedState();
    }

    pub fn setFallbackFontPaths(self: *SurfaceSession, paths: []const [:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const n: u8 = @intCast(@min(paths.len, text_support.max_fallback_fonts));
        self.text_state.fallback_font_paths_len = n;
        for (0..n) |i| self.text_state.fallback_font_paths[i] = paths[i];
        for (@as(usize, n)..text_support.max_fallback_fonts) |i| self.text_state.fallback_font_paths[i] = null;
        self.invalidatePreparedState();
    }

    pub fn setFontSizePx(self: *SurfaceSession, font_size_px: u16) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.config.font_size_px = @max(font_size_px, 1);
        self.invalidatePreparedState();
    }

    pub fn deriveFrameLayout(
        self: *SurfaceSession,
        render_px: render.PixelSize,
        grid_px: render.PixelSize,
    ) render.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        const cell_px = text_support.deriveCellSize(self);
        const layout = SurfaceLayout{ .cell_px = cell_px, .grid = render.deriveGridSize(grid_px, cell_px) };
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn prepareSurface(
        self: *SurfaceSession,
        allocator: std.mem.Allocator,
        runtime: *render.RenderRuntime,
        state: render.SurfaceFrameData,
    ) !PrepareResult {
        const request = runtime.prepare() orelse return .idle;
        var faces: [32]render.Text.FontSession.FontFaceRecord = undefined;
        const query = runtime.surfaceQuery();
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.target_epoch != query.epoch) {
            self.target_epoch = query.epoch;
            self.target_valid = false;
        }
        var text_input = try input.vtStateToTextSceneInput(allocator, state);
        defer text_input.deinit();
        if (!self.target_valid) {
            if (self.text_preparer) |*preparer| preparer.clearAtlas();
            text_input.options.scene.damage.full = true;
            text_input.options.scene.damage.scroll_up_rows = 0;
        }
        self.resolve = .{};
        const preparer = try self.ensureTextPreparer(allocator);
        var prepared = try preparer.prepareCellsWithSessionOptions(
            text_input.cells,
            text_input.grid,
            self.fontSession(&faces, &self.resolve),
            text_input.options,
        );
        errdefer prepared.deinit();
        const prepare_metrics = prepareMetrics(prepared.timings);
        const surface_damage_rects = try buildSurfaceDamageRects(
            allocator,
            query.render_px,
            query.cell_px,
            text_input.grid,
            text_input.options.scene.damage,
            prepared.scene.scene.scroll_up_px,
            prepared.scene.scene.full_redraw,
        );
        errdefer if (surface_damage_rects.len > 0) allocator.free(surface_damage_rects);
        const buffer_damage_rects = try buildBufferDamageRects(
            allocator,
            query.render_px,
            query.cell_px,
            text_input.grid,
            text_input.options.scene.damage,
            prepared.scene.scene.scroll_up_px,
            prepared.scene.scene.full_redraw,
        );
        errdefer if (buffer_damage_rects.len > 0) allocator.free(buffer_damage_rects);
        const sprite_batches = try buildSpriteBatches(
            allocator,
            2048,
            prepared.scene.scene.sprite_draws,
            prepared.raster_plan.outputs,
        );
        errdefer if (sprite_batches.len > 0) allocator.free(sprite_batches);
        self.prepared = .{
            .render_seq = request.token.snapshot_seq,
            .render_dirty_epoch = request.token.dirty_epoch,
            .geometry_epoch = request.token.geometry_epoch,
            .prepare_metrics = prepare_metrics,
            .resolve = self.resolve,
            .prepared = .{
                .allocator = allocator,
                .request = request,
                .required_surface_epoch = request.known_target_epoch,
                .geometry_epoch = request.token.geometry_epoch,
                .atlas_page_slots = 2048,
                .render_px = query.render_px,
                .cell_px = query.cell_px,
                .grid = .{ .cols = text_input.grid.cols, .rows = text_input.grid.rows },
                .surface_damage_rects = surface_damage_rects,
                .buffer_damage_rects = buffer_damage_rects,
                .sprite_batches = sprite_batches,
                .text_frame = prepared,
                .resolve = self.resolve,
                .prepare_metrics = prepare_metrics,
            },
        };
        _ = runtime.publishPrepared(self.prepared.?.pipelineFrame());
        self.mutex.unlock();
        return .prepared;
    }

    pub fn submitSurface(self: *SurfaceSession, runtime: *render.RenderRuntime, execution: SurfaceExecutionInput) !SubmitResult {
        return switch (runtime.submit()) {
            .idle => .idle,
            .stale => .stale,
            .needs_full_prepare => .needs_full_prepare,
            .submit => |prepared_frame| blk: {
                lockMutex(&self.mutex);
                errdefer self.mutex.unlock();
                const prepared = &(self.prepared orelse {
                    runtime.requestFullPrepare(prepared_frame.token);
                    self.mutex.unlock();
                    break :blk .needs_full_prepare;
                });
                if (!sameToken(prepared_frame.token, prepared.*)) {
                    runtime.requestFullPrepare(prepared_frame.token);
                    self.mutex.unlock();
                    break :blk .needs_full_prepare;
                }
                markRenderedOutputs(&self.text_preparer.?.atlas, prepared.prepared.text_frame.raster_plan.outputs);
                const submitted = render.SurfaceFeedback{
                    .report = .{
                        .texture_id = execution.surface.texture_id,
                        .raster_uploads_committed = execution.uploads_committed,
                        .full_redraw = prepared.prepared.text_frame.scene.scene.full_redraw,
                        .scroll_up_px = prepared.prepared.text_frame.scene.scene.scroll_up_px,
                        .clear_draws = prepared.prepared.text_frame.scene.scene.clear_draws.len,
                        .background_draws = prepared.prepared.text_frame.scene.scene.background_draws.len,
                        .sprite_draws = prepared.prepared.text_frame.scene.scene.sprite_draws.len,
                        .decoration_draws = prepared.prepared.text_frame.scene.scene.decoration_draws.len,
                        .cursor_draws = prepared.prepared.text_frame.scene.scene.cursor_draws.len,
                    },
                    .resolve = prepared.resolve,
                    .surface = execution.surface,
                    .metrics = undefined,
                    .render_us = execution.render_us,
                    .content_valid = execution.content_valid,
                };
                var final = submitted;
                final.metrics = prepared.renderMetrics(final, final.render_us);
                runtime.acceptSubmitted(prepared.submittedFrame(final));
                self.target_valid = final.content_valid;
                prepared.deinit();
                self.prepared = null;
                self.mutex.unlock();
                break :blk .{ .rendered = final };
            },
        };
    }

    fn invalidatePreparedState(self: *SurfaceSession) void {
        self.target_valid = false;
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.text_preparer) |*preparer| preparer.clearAtlas();
    }

    fn ensureTextPreparer(self: *SurfaceSession, allocator: std.mem.Allocator) !*render.Text.TextFramePreparer {
        if (self.text_preparer == null) {
            var ft_hb = self.ftHbSource();
            self.text_preparer = try render.Text.TextFramePreparer.initWithProvider(
                allocator,
                2048,
                ft_hb.textProvider(),
            );
        }
        return &self.text_preparer.?;
    }

    fn ftHbSource(self: *SurfaceSession) render.Text.FtHbProvider.FtHbSource {
        return .{
            .ctx = self,
            .has_codepoint = providerHasCodepointThunk,
            .shaper = .{ .ctx = self, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = self, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = self, .call = providerRasterizeGlyphThunk },
        };
    }

    fn fontSession(self: *SurfaceSession, faces: []render.Text.FontSession.FontFaceRecord, active_resolve: ?*render.ResolveObservability) render.Text.FontSession.FontSession {
        self.text_state.active_resolve = active_resolve;
        var len: usize = 0;
        if (faces.len > len) {
            faces[len] = .{ .id = .{ .value = text_support.primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: u8 = 0;
        while (i < self.text_state.fallback_font_paths_len and len < faces.len) : (i += 1) {
            if (self.text_state.fallback_font_paths[i] == null) continue;
            faces[len] = .{ .id = .{ .value = i + 2 }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = text_support.primary_face_id },
            .faces = faces[0..len],
            .provider = .{ .ctx = self, .has_cell_text = providerHasCellTextThunk },
            .metrics = text_support.deriveCellMetrics(self),
        };
    }

    fn providerHasCodepointThunk(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32) bool {
        return text_support.providerHasCodepoint(SurfaceSession, ctx, face_id, codepoint);
    }

    fn providerHasCellTextThunk(ctx: *anyopaque, face_id: render.FontFaceId, text_value: render.CellText) bool {
        return text_support.providerHasCellText(SurfaceSession, ctx, face_id, text_value);
    }

    fn providerShapeRunThunk(ctx: *anyopaque, allocator: std.mem.Allocator, run: render.ResolvedRun, text_cache_view: render.LineTextCache, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics) anyerror!render.Text.ShapeRun.OwnedShapedRun {
        return text_support.providerShapeRun(SurfaceSession, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.SpriteRasterRequest) anyerror!render.Text.Rasterizer.RasterSpriteOutput {
        return text_glyph_raster.providerRasterizeSprite(SurfaceSession, ctx, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
        return text_support.providerLookupGlyph(SurfaceSession, ctx, face_id, codepoint, cell_metrics);
    }

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.RasterizeRequest) anyerror!render.RasterizeOutput {
        const self: *SurfaceSession = @ptrCast(@alignCast(ctx));
        const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
        const height = @max(req.cell_metrics.cell_h_px, 1);
        const alpha = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        errdefer allocator.free(alpha);
        @memset(alpha, 0);
        _ = text_glyph_raster.rasterizeProviderGlyph(self, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
        return .{
            .allocator = allocator,
            .width_px = width,
            .height_px = height,
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = text_support.providerGlyphAdvance(self, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
            .alpha_mask = alpha,
        };
    }

    fn prepareMetrics(timings: render.Text.PrepareTimings) render.PrepareMetrics {
        const total = timings.input_us + timings.sparse_us + timings.clusters_us + timings.resolve_us + timings.shape_us + timings.group_us + timings.scene_us + timings.raster_us + timings.atlas_us;
        return .{
            .sync_us = timings.input_us,
            .copy_us = timings.sparse_us + timings.clusters_us,
            .us = total,
            .surface_us = total,
            .input_us = timings.input_us,
            .sparse_us = timings.sparse_us,
            .clusters_us = timings.clusters_us,
            .resolve_us = timings.resolve_us,
            .shape_us = timings.shape_us,
            .group_us = timings.group_us,
            .scene_us = timings.scene_us,
            .raster_us = timings.raster_us,
            .atlas_us = timings.atlas_us,
        };
    }

    fn sameToken(token: render.FramePipeline.SnapshotToken, prepared: FrameRecord) bool {
        return token.snapshot_seq == prepared.render_seq and
            token.dirty_epoch == prepared.render_dirty_epoch and
            token.geometry_epoch == prepared.geometry_epoch;
    }

    fn markRenderedOutputs(atlas: *render.Text.AtlasCache.OwnedAtlasCache, outputs: []const render.Text.Rasterizer.RasterSpriteOutput) void {
        for (outputs) |output| _ = atlas.markRendered(output.key);
    }

    fn buildSurfaceDamageRects(
        allocator: std.mem.Allocator,
        render_px: render.PixelSize,
        cell_px: surface.CellSize,
        grid: render.GridMetrics,
        damage: anytype,
        scroll_up_px: u16,
        full_redraw: bool,
    ) ![]DamageRect {
        if (render_px.width == 0 or render_px.height == 0) return &.{};
        if (full_redraw or damage.full or scroll_up_px > 0) {
            const out = try allocator.alloc(DamageRect, 1);
            out[0] = .{ .x = 0, .y = 0, .width = render_px.width, .height = render_px.height };
            return out;
        }
        return buildDirtyRowRects(allocator, cell_px, grid, damage);
    }

    fn buildBufferDamageRects(
        allocator: std.mem.Allocator,
        render_px: render.PixelSize,
        cell_px: surface.CellSize,
        grid: render.GridMetrics,
        damage: anytype,
        scroll_up_px: u16,
        full_redraw: bool,
    ) ![]DamageRect {
        if (render_px.width == 0 or render_px.height == 0) return &.{};
        if (full_redraw or damage.full) {
            const out = try allocator.alloc(DamageRect, 1);
            out[0] = .{ .x = 0, .y = 0, .width = render_px.width, .height = render_px.height };
            return out;
        }
        if (scroll_up_px > 0) {
            var rects = std.ArrayList(DamageRect).empty;
            errdefer rects.deinit(allocator);
            try rects.append(allocator, .{
                .x = 0,
                .y = render_px.height - scroll_up_px,
                .width = render_px.width,
                .height = scroll_up_px,
            });
            const dirty = try buildDirtyRowRects(allocator, cell_px, grid, damage);
            defer if (dirty.len > 0) allocator.free(dirty);
            try rects.appendSlice(allocator, dirty);
            return try rects.toOwnedSlice(allocator);
        }
        return buildDirtyRowRects(allocator, cell_px, grid, damage);
    }

    fn buildDirtyRowRects(
        allocator: std.mem.Allocator,
        cell_px: surface.CellSize,
        grid: render.GridMetrics,
        damage: anytype,
    ) ![]DamageRect {
        const rows = @as(usize, grid.rows);
        if (rows == 0 or damage.dirty_rows.len != rows or damage.dirty_cols_start.len != rows or damage.dirty_cols_end.len != rows) {
            return &.{};
        }
        var rects = std.ArrayList(DamageRect).empty;
        errdefer rects.deinit(allocator);
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            if (!damage.dirty_rows[row]) continue;
            const start_col = @min(damage.dirty_cols_start[row], grid.cols -| 1);
            const end_col = @min(damage.dirty_cols_end[row], grid.cols -| 1);
            if (end_col < start_col) continue;
            try rects.append(allocator, .{
                .x = @as(i32, start_col) * @as(i32, cell_px.width),
                .y = @as(i32, @intCast(row)) * @as(i32, cell_px.height),
                .width = (@as(i32, end_col) - @as(i32, start_col) + 1) * @as(i32, cell_px.width),
                .height = @as(i32, cell_px.height),
            });
        }
        if (rects.items.len == 0) return &.{};
        return try rects.toOwnedSlice(allocator);
    }

    fn buildSpriteBatches(
        allocator: std.mem.Allocator,
        atlas_page_slots: u32,
        draws: []const render.TextSpriteDraw,
        outputs: []const render.Text.Rasterizer.RasterSpriteOutput,
    ) ![]SpriteBatch {
        if (draws.len == 0) return &.{};
        var batches = std.ArrayList(SpriteBatch).empty;
        errdefer batches.deinit(allocator);
        var current_pass: ?SpriteBatchPassKind = null;
        var first_instance: u32 = 0;
        var instance_count: u32 = 0;
        for (draws, 0..) |draw, idx| {
            const pass_kind = spritePassKindForDraw(draw, outputs);
            if (current_pass == null) {
                current_pass = pass_kind;
                first_instance = @intCast(idx);
                instance_count = 1;
                continue;
            }
            if (current_pass.? != pass_kind) {
                try batches.append(allocator, .{
                    .atlas_page = atlasPageForSlot(draws[first_instance].sprite.slot, atlas_page_slots),
                    .pass_kind = current_pass.?,
                    .first_instance = first_instance,
                    .instance_count = instance_count,
                });
                current_pass = pass_kind;
                first_instance = @intCast(idx);
                instance_count = 1;
                continue;
            }
            instance_count += 1;
        }
        try batches.append(allocator, .{
            .atlas_page = atlasPageForSlot(draws[first_instance].sprite.slot, atlas_page_slots),
            .pass_kind = current_pass.?,
            .first_instance = first_instance,
            .instance_count = instance_count,
        });
        return try batches.toOwnedSlice(allocator);
    }

    fn spritePassKindForDraw(
        draw: render.TextSpriteDraw,
        outputs: []const render.Text.Rasterizer.RasterSpriteOutput,
    ) SpriteBatchPassKind {
        for (outputs) |output| {
            if (output.key.value != draw.sprite.key.value) continue;
            return switch (output.color_mode) {
                .alpha => .alpha,
                .color => .color,
            };
        }
        return .alpha;
    }

    fn atlasPageForSlot(slot: u32, atlas_page_slots: u32) u16 {
        if (atlas_page_slots == 0) return 0;
        return @intCast(slot / atlas_page_slots);
    }

};
