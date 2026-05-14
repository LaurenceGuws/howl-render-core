//! Responsibility: provide a single render owner surface.
//! Ownership: render orchestration API.
//! Reason: keep hosts/backends on one coherent entrypoint.

const std = @import("std");
const types = @import("types.zig");
const frame_input = @import("frame_input.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const frame_queue = @import("frame_queue.zig");
const frame_snapshot = @import("frame_snapshot.zig");
const frame_metrics = @import("frame_metrics.zig");
const surface = @import("surface.zig");
const text_contract = @import("text_contract.zig");
const text_pipeline = @import("text_pipeline.zig");
const text = @import("text.zig");

pub const Render = struct {
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
    pub const CellInput = types.CellInput;
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
    pub const SnapshotOwner = struct {
        snapshot: FrameSnapshot,

        pub fn create(rows: u16, cols: u16) ?*SnapshotOwner {
            if (rows == 0 or cols == 0) return null;
            const owner = std.heap.c_allocator.create(SnapshotOwner) catch return null;
            owner.snapshot = FrameSnapshot.init(std.heap.c_allocator, rows, cols) catch {
                std.heap.c_allocator.destroy(owner);
                return null;
            };
            return owner;
        }

        pub fn destroy(self: *SnapshotOwner) void {
            self.snapshot.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(self);
        }
    };
    pub const PrepareMetrics = frame_metrics.PrepareMetrics;
    pub const RenderMetrics = frame_metrics.RenderMetrics;
    pub const Metrics = frame_metrics.RuntimeMetrics;
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
        ) SourceReceipt {
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
            submitted_token: ?frame_pipeline.SnapshotToken,
        ) ?frame_pipeline.SnapshotToken {
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
            damage_kind: frame_pipeline.DamageKind,
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

        fn classify(self: *const PublicationState, source: SourceView) frame_pipeline.DamageKind {
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
        pub const Owner = struct {
            runtime: RenderRuntime,

            pub fn create() ?*Owner {
                const owner = std.heap.c_allocator.create(Owner) catch return null;
                owner.runtime = RenderRuntime.init(std.heap.c_allocator);
                return owner;
            }

            pub fn destroy(self: *Owner) void {
                self.runtime.deinit();
                std.heap.c_allocator.destroy(self);
            }
        };

        pub const Metrics = Render.Metrics;
        allocator: std.mem.Allocator,
        surface_owner: FrameQueue.TerminalSurface = .{},
        render_px: types.PixelSize = .{ .width = 0, .height = 0 },
        grid_px: types.PixelSize = .{ .width = 0, .height = 0 },
        cell_px: types.CellSize = .{ .width = 0, .height = 0 },
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

        pub fn acceptSource(self: *RenderRuntime, source: SourceView) SourceReceipt {
            std.debug.assert(source.cols > 0);
            std.debug.assert(source.rows > 0);
            std.debug.assert(source.snapshot.cols == source.cols);
            std.debug.assert(source.snapshot.rows == source.rows);
            std.debug.assert(source.scrollback_offset <= source.scrollback_count);
            return self.publication_state.acceptSource(self.allocator, source, self.geometry_epoch);
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
            if (self.publication_state.takePendingToken(self.geometry_epoch, self.surface_owner.submittedToken())) |token| {
                _ = self.surface_owner.publishSnapshot(token, .opportunistic);
            }
            return self.surface_owner.takePrepare();
        }

        pub fn hasPendingPublication(self: *const RenderRuntime) bool {
            return self.publication_state.hasPending();
        }

        pub fn publishPrepared(self: *RenderRuntime, prepared: frame_pipeline.PreparedFrame) u64 {
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

        pub fn acceptSubmitted(self: *RenderRuntime, frame: frame_pipeline.SubmittedFrame) void {
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
    pub const FrameGeometryError = error{
        InvalidSurfaceSize,
        InvalidGridSize,
    };
    config: types.BackendConfig,
    capability: types.BackendCapability,

    pub fn init(config: BackendConfig, capability: BackendCapability) Render {
        return .{
            .config = config,
            .capability = capability,
        };
    }

    /// Canonical active-path frame-to-text input conversion.
    pub fn vtStateToTextSceneInput(
        _: *const Render,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedTextSceneInput {
        return frame_input.vtStateToTextSceneInput(allocator, state);
    }

    pub fn vtStateToFrameTextInput(
        _: *const Render,
        allocator: std.mem.Allocator,
        state: anytype,
    ) !OwnedFrameTextInput {
        return frame_input.vtStateToFrameTextInput(allocator, state);
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

test "render runtime owns source publication and retained-frame queue" {
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 3);
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

    const clean_source = Render.SourceView{
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
    try std.testing.expect(runtime.publication_state.publication != null);
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication_state.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication_state.publication.?.snapshot.cells.items[5].codepoint);
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

    const duplicate_source = Render.SourceView{
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
    try std.testing.expectEqual(@as(u21, 'a'), runtime.publication_state.publication.?.snapshot.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), runtime.publication_state.publication.?.snapshot.cells.items[5].codepoint);

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
    snapshot.clearDirty();
    snapshot.dirty = .partial;
    snapshot.dirty_rows.items[0] = true;
    snapshot.dirty_cols_start.items[0] = 2;
    snapshot.dirty_cols_end.items[0] = 2;
    snapshot.cells.items[2].codepoint = 'Q';
    const selection_receipt = runtime.acceptSource(selection_source);
    try std.testing.expect(selection_receipt.published);
    try std.testing.expectEqual(frame_pipeline.DamageKind.partial, selection_receipt.damage_kind);
    try std.testing.expectEqual(@as(u21, 'Q'), runtime.publication_state.publication.?.snapshot.cells.items[2].codepoint);

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

test "render runtime metrics stay owned by render" {
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 2);
    defer snapshot.deinit(std.testing.allocator);
    snapshot.clearDirty();

    const empty_metrics = runtime.takeMetrics();
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.prepare_requests);
    try std.testing.expectEqual(@as(u64, 0), empty_metrics.submit_valid);

    const geometry_receipt = runtime.syncGeometry(.{
        .render_px = .{ .width = 16, .height = 32 },
        .grid_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(geometry_receipt.changed);
    try std.testing.expectEqual(@as(u64, 1), geometry_receipt.geometry_epoch);

    const source = Render.SourceView{
        .snapshot = &snapshot,
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
    const receipt = runtime.acceptSource(source);
    try std.testing.expect(receipt.published);
    try std.testing.expect(receipt.queued);
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
    const stale_receipt = runtime.acceptSource(stale);
    try std.testing.expect(stale_receipt.published);
    try std.testing.expect(stale_receipt.queued);
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
