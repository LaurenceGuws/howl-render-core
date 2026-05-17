
const std = @import("std");
const damage = @import("damage.zig");
const geometry_mod = @import("geometry.zig");
const input = @import("input.zig");
const pipeline = @import("pipeline.zig");
const sprite_batch = @import("sprite_batch.zig");
const contract = @import("../text/contract.zig");
const text_pipeline = @import("../text/pipeline.zig");
const text = @import("../text/text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");
const text_glyph_raster = @import("../text/font/ft_hb/glyph_raster.zig");

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const SurfaceState = enum {
    idle,
    running,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const FramePixels = struct {
    render_width: i32,
    render_height: i32,
    grid_width: i32,
    grid_height: i32,

    pub fn renderWidth(self: FramePixels) u16 {
        return @intCast(@max(self.render_width, 1));
    }

    pub fn renderHeight(self: FramePixels) u16 {
        return @intCast(@max(self.render_height, 1));
    }

    pub fn gridWidth(self: FramePixels) u16 {
        return @intCast(@max(self.grid_width, 1));
    }

    pub fn gridHeight(self: FramePixels) u16 {
        return @intCast(@max(self.grid_height, 1));
    }
};

pub const GeometryResponse = struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
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

pub const SurfaceTextConfig = struct {
    surface_px: PixelSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
};

pub const SurfaceTextOwner = struct {
    session: SurfaceText,
    config: SurfaceTextConfig,
    font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayList([:0]u8) = .empty,

    pub fn create(config: SurfaceTextConfig) ?*SurfaceTextOwner {
        const owner = std.heap.c_allocator.create(SurfaceTextOwner) catch return null;
        owner.* = .{ .session = SurfaceText.init(), .config = config };
        return owner;
    }

    pub fn destroy(self: *SurfaceTextOwner) void {
        if (self.font_path) |path| std.heap.c_allocator.free(path);
        self.font_path = null;
        for (self.fallback_font_paths.items) |path| std.heap.c_allocator.free(path);
        self.fallback_font_paths.deinit(std.heap.c_allocator);
        self.session.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn invalidateTextState(self: *SurfaceTextOwner) void {
        text_support.resetLoadedFace(&self.session);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
    }
};

pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
};

pub const GlyphQuad = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    codepoint: u21,
    fg: contract.Rgba8,
    bg: ?contract.Rgba8 = null,
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

pub const Color = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    value: u24 = 0,
};

pub const CellFlags = packed struct {
    continuation: bool = false,
    _pad: u7 = 0,
};

pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    underline_color_set: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    underline_color: Color = .{ .kind = .default, .value = 0 },
    underline_style: UnderlineStyle = .straight,
    attrs: CellAttrs = .{},
    link_id: u32 = 0,
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
};

pub const DamageInfo = struct {
    full: bool = true,
    scroll_up_rows: u16 = 0,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const ViewportInfo = struct {
    cols: u16,
    rows: u16,
    scroll_row: usize = 0,
    is_alternate_screen: bool = false,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
};

pub const FrameData = struct {
    viewport: ViewportInfo,
    grid: GridModel,
    cursor: CursorInfo,
    damage: DamageInfo = .{},
};

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
    request: pipeline.RenderRequest,
    required_surface_epoch: u64,
    geometry_epoch: u64,
    atlas_page_slots: u32,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    surface_damage_rects: []DamageRect = &.{},
    buffer_damage_rects: []DamageRect = &.{},
    sprite_batches: []SpriteBatch = &.{},
    text_frame: text.OwnedPreparedTextFrame,
    resolve: text_pipeline.ResolveObservability = .{},
    prepare_metrics: PrepareMetrics = .{},

    pub fn deinit(self: *PreparedSurface) void {
        if (self.surface_damage_rects.len > 0) self.allocator.free(self.surface_damage_rects);
        if (self.buffer_damage_rects.len > 0) self.allocator.free(self.buffer_damage_rects);
        if (self.sprite_batches.len > 0) self.allocator.free(self.sprite_batches);
        self.text_frame.deinit();
        self.* = undefined;
    }

    pub fn damageKind(self: *const PreparedSurface) pipeline.DamageKind {
        if (self.text_frame.scene.scene.full_redraw) return .full;
        if (self.text_frame.scene.scene.scroll_up_px > 0) return .scroll;
        return .partial;
    }

    pub fn pipelineFrame(self: *const PreparedSurface) pipeline.PreparedFrame {
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
    resolve: text_pipeline.ResolveObservability,
    surface: SurfaceHandle,
    metrics: RenderMetrics,
    render_us: u64,
    content_valid: bool = true,

    pub fn damageKind(self: SurfaceFeedback) pipeline.DamageKind {
        if (self.report.full_redraw) return .full;
        if (self.report.scroll_up_px > 0) return .scroll;
        return .partial;
    }
};

pub const SurfaceText = struct {
    text_state: text_support.State,
    mutex: ThreadMutex = .{},
    text_preparer: ?text.TextFramePreparer = null,

    const TextContext = struct {
        session: *SurfaceText,
        session_config: SurfaceTextConfig,
    };

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
        surface: SurfaceHandle,
        uploads_committed: usize,
        render_us: u64,
        content_valid: bool = true,
    };

    pub const PrepareInput = struct {
        config: SurfaceTextConfig,
        request: pipeline.RenderRequest,
        query: SurfaceQuery,
        state: FrameData,
        target_valid: bool,
    };

    pub fn init() SurfaceText {
        return .{
            .text_state = text_support.State.init(std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *SurfaceText) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.text_preparer) |*preparer| {
            preparer.deinit();
            self.text_preparer = null;
        }
        self.text_state.deinit();
    }

    pub fn deriveFrameLayout(
        self: *SurfaceText,
        config: SurfaceTextConfig,
        render_px: PixelSize,
        grid_px: PixelSize,
    ) geometry_mod.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        var context = TextContext{ .session = self, .session_config = config };
        const cell_px = text_support.deriveCellSize(&context);
        const layout = SurfaceLayout{ .cell_px = cell_px, .grid = geometry_mod.deriveGridSize(grid_px, cell_px) };
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn prepareSurface(self: *SurfaceText, allocator: std.mem.Allocator, prepare: PrepareInput) !PreparedSurface {
        var faces: [32]text.FontSession.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        var text_input = try input.vtStateToTextSceneInput(allocator, prepare.state);
        defer text_input.deinit();
        if (!prepare.target_valid) {
            if (self.text_preparer) |*preparer| preparer.clearAtlas();
            text_input.options.scene.damage.full = true;
            text_input.options.scene.damage.scroll_up_rows = 0;
        }
        var resolve: text_pipeline.ResolveObservability = .{};
        const preparer = try self.ensureTextPreparer(allocator, &context);
        var prepared = try preparer.prepareCellsWithSessionOptions(
            text_input.cells,
            text_input.grid,
            fontSession(&context, &faces, &resolve),
            text_input.options,
        );
        errdefer prepared.deinit();
        const plans = try buildPreparedPlans(allocator, prepare, text_input.grid, prepared);
        errdefer plans.deinit(allocator);
        const owned = ownPreparedSurface(allocator, prepare, text_input.grid, prepared, resolve, plans);
        self.mutex.unlock();
        return owned;
    }

    const PreparedPlans = struct {
        surface_damage_rects: []DamageRect,
        buffer_damage_rects: []DamageRect,
        sprite_batches: []SpriteBatch,

        fn deinit(self: PreparedPlans, allocator: std.mem.Allocator) void {
            if (self.surface_damage_rects.len > 0) allocator.free(self.surface_damage_rects);
            if (self.buffer_damage_rects.len > 0) allocator.free(self.buffer_damage_rects);
            if (self.sprite_batches.len > 0) allocator.free(self.sprite_batches);
        }
    };

    fn buildPreparedPlans(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: text.OwnedPreparedTextFrame,
    ) !PreparedPlans {
        const surface_damage_rects = try damage.buildSurfaceRects(PixelSize, CellSize, contract.GridMetrics, DamageRect, allocator, prepare.query.render_px, prepare.query.cell_px, grid, prepare.state.damage, prepared.scene.scene.scroll_up_px, prepared.scene.scene.full_redraw);
        errdefer if (surface_damage_rects.len > 0) allocator.free(surface_damage_rects);
        const buffer_damage_rects = try damage.buildBufferRects(PixelSize, CellSize, contract.GridMetrics, DamageRect, allocator, prepare.query.render_px, prepare.query.cell_px, grid, prepare.state.damage, prepared.scene.scene.scroll_up_px, prepared.scene.scene.full_redraw);
        errdefer if (buffer_damage_rects.len > 0) allocator.free(buffer_damage_rects);
        const sprite_batches = try sprite_batch.buildBatches(SpriteBatch, SpriteBatchPassKind, allocator, 2048, prepared.scene.scene.sprite_draws, prepared.raster_plan.outputs);
        errdefer if (sprite_batches.len > 0) allocator.free(sprite_batches);
        return .{
            .surface_damage_rects = surface_damage_rects,
            .buffer_damage_rects = buffer_damage_rects,
            .sprite_batches = sprite_batches,
        };
    }

    fn ownPreparedSurface(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: text.OwnedPreparedTextFrame,
        resolve: text_pipeline.ResolveObservability,
        plans: PreparedPlans,
    ) PreparedSurface {
        return .{
            .allocator = allocator,
            .request = prepare.request,
            .required_surface_epoch = prepare.request.known_target_epoch,
            .geometry_epoch = prepare.request.token.geometry_epoch,
            .atlas_page_slots = 2048,
            .render_px = prepare.query.render_px,
            .cell_px = prepare.query.cell_px,
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .surface_damage_rects = plans.surface_damage_rects,
            .buffer_damage_rects = plans.buffer_damage_rects,
            .sprite_batches = plans.sprite_batches,
            .text_frame = prepared,
            .resolve = resolve,
            .prepare_metrics = prepareMetrics(prepared.timings),
        };
    }

    pub fn submitSurface(self: *SurfaceText, prepared: *PreparedSurface, execution: SurfaceExecutionInput) !SurfaceFeedback {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        markRenderedOutputs(&self.text_preparer.?.atlas, prepared.text_frame.raster_plan.outputs);
        const submitted = SurfaceFeedback{
            .report = .{
                .texture_id = execution.surface.texture_id,
                .raster_uploads_committed = execution.uploads_committed,
                .full_redraw = prepared.text_frame.scene.scene.full_redraw,
                .scroll_up_px = prepared.text_frame.scene.scene.scroll_up_px,
                .clear_draws = prepared.text_frame.scene.scene.clear_draws.len,
                .background_draws = prepared.text_frame.scene.scene.background_draws.len,
                .sprite_draws = prepared.text_frame.scene.scene.sprite_draws.len,
                .decoration_draws = prepared.text_frame.scene.scene.decoration_draws.len,
                .cursor_draws = prepared.text_frame.scene.scene.cursor_draws.len,
            },
            .resolve = prepared.resolve,
            .surface = execution.surface,
            .metrics = undefined,
            .render_us = execution.render_us,
            .content_valid = execution.content_valid,
        };
        var final = submitted;
        final.metrics = renderMetrics(prepared.prepare_metrics, final, final.render_us);
        self.mutex.unlock();
        return final;
    }

    fn ensureTextPreparer(self: *SurfaceText, allocator: std.mem.Allocator, context: *TextContext) !*text.TextFramePreparer {
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try text.TextFramePreparer.initWithProvider(
                allocator,
                2048,
                ft_hb.textProvider(),
            );
        }
        return &self.text_preparer.?;
    }

    fn ftHbSource(context: *TextContext) text.FtHbProvider.FtHbSource {
        return .{
            .ctx = context,
            .has_codepoint = providerHasCodepointThunk,
            .shaper = .{ .ctx = context, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = context, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = context, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = context, .call = providerRasterizeGlyphThunk },
        };
    }

    fn fontSession(context: *TextContext, faces: []text.FontSession.FontFaceRecord, active_resolve: ?*text_pipeline.ResolveObservability) text.FontSession.FontSession {
        context.session.text_state.active_resolve = active_resolve;
        var len: usize = 0;
        if (faces.len > len) {
            faces[len] = .{ .id = .{ .value = text_support.primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: u8 = 0;
        while (i < context.session.text_state.fallback_font_paths_len and len < faces.len) : (i += 1) {
            if (context.session.text_state.fallback_font_paths[i] == null) continue;
            faces[len] = .{ .id = .{ .value = i + 2 }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = text_support.primary_face_id },
            .faces = faces[0..len],
            .provider = .{ .ctx = context, .has_cell_text = providerHasCellTextThunk },
            .metrics = text_support.deriveCellMetrics(context),
        };
    }

    fn providerHasCodepointThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32) bool {
        return text_support.providerHasCodepoint(TextContext, ctx, face_id, codepoint);
    }

    fn providerHasCellTextThunk(ctx: *anyopaque, face_id: contract.FontFaceId, text_value: contract.CellText) bool {
        return text_support.providerHasCellText(TextContext, ctx, face_id, text_value);
    }

    fn providerShapeRunThunk(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache_view: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!text.ShapeRun.OwnedShapedRun {
        return text_support.providerShapeRun(TextContext, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!text.Rasterizer.RasterSpriteOutput {
        return text_glyph_raster.providerRasterizeSprite(TextContext, ctx, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32, cell_metrics: contract.CellMetrics) text.Provider.LookupGlyphResult {
        return text_support.providerLookupGlyph(TextContext, ctx, face_id, codepoint, cell_metrics);
    }

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: text_pipeline.RasterizeRequest) anyerror!text_pipeline.RasterizeOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
        const height = @max(req.cell_metrics.cell_h_px, 1);
        const alpha = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        errdefer allocator.free(alpha);
        @memset(alpha, 0);
        _ = text_glyph_raster.rasterizeProviderGlyph(context, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
        return .{
            .allocator = allocator,
            .width_px = width,
            .height_px = height,
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = text_support.providerGlyphAdvance(context, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
            .alpha_mask = alpha,
        };
    }

    fn prepareMetrics(timings: text.PrepareTimings) PrepareMetrics {
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

    fn markRenderedOutputs(atlas: *text.AtlasCache.OwnedAtlasCache, outputs: []const text.Rasterizer.RasterSpriteOutput) void {
        for (outputs) |output| _ = atlas.markRendered(output.key);
    }

    fn renderMetrics(prepare_metrics: PrepareMetrics, feedback: SurfaceFeedback, render_us: u64) RenderMetrics {
        const report = feedback.report;
        const counters = feedback.resolve.counters;
        return .{
            .sync_us = prepare_metrics.sync_us,
            .copy_us = prepare_metrics.copy_us,
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

};
