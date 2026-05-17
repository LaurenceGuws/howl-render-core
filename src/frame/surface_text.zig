const std = @import("std");
const damage = @import("damage.zig");
const geometry_mod = @import("geometry.zig");
const input = @import("input.zig");
const pipeline = @import("pipeline.zig");
const submit_feedback = @import("submit_feedback.zig");
const surface = @import("surface.zig");
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

pub const SurfaceTextConfig = struct {
    surface_px: surface.PixelSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
};

pub const SurfaceText = struct {
    text_state: text_support.State,
    mutex: ThreadMutex = .{},
    text_preparer: ?text.TextFramePreparer = null,

    const TextContext = struct {
        session: *SurfaceText,
        session_config: SurfaceTextConfig,
    };

    pub const FrameLayout = surface.SurfaceLayout;
    pub const PreparedTimings = surface.PrepareMetrics;
    pub const DamageKind = enum { partial, scroll, full };
    pub const SubmittedReport = surface.SurfaceExecutionReport;
    pub const SurfaceExecutionInput = struct {
        surface: surface.SurfaceHandle,
        uploads_committed: usize,
        render_us: u64,
        content_valid: bool = true,
    };
    pub const PrepareInput = struct {
        config: SurfaceTextConfig,
        request: pipeline.RenderRequest,
        query: surface.SurfaceQuery,
        state: surface.FrameData,
        target_valid: bool,
    };

    const PreparedPlans = struct {
        surface_damage_rects: []surface.DamageRect,
        buffer_damage_rects: []surface.DamageRect,

        fn deinit(self: PreparedPlans, allocator: std.mem.Allocator) void {
            if (self.surface_damage_rects.len > 0) allocator.free(self.surface_damage_rects);
            if (self.buffer_damage_rects.len > 0) allocator.free(self.buffer_damage_rects);
        }
    };

    pub fn init() SurfaceText {
        return .{ .text_state = text_support.State.init(std.heap.c_allocator) };
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
        render_px: surface.PixelSize,
        grid_px: surface.PixelSize,
    ) geometry_mod.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        var context = TextContext{ .session = self, .session_config = config };
        const cell_px = text_support.deriveCellSize(&context);
        const layout = surface.SurfaceLayout{ .cell_px = cell_px, .grid = geometry_mod.deriveGridSize(grid_px, cell_px) };
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn prepareSurface(self: *SurfaceText, allocator: std.mem.Allocator, prepare: PrepareInput) !surface.PreparedSurface {
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
        var prepared = try preparer.prepareCellsWithSessionOptions(text_input.cells, text_input.grid, fontSession(&context, &faces, &resolve), text_input.options);
        errdefer prepared.deinit();
        const plans = try buildPreparedPlans(allocator, prepare, text_input.grid, prepared);
        errdefer plans.deinit(allocator);
        const owned = ownPreparedSurface(allocator, prepare, text_input.grid, prepared, resolve, plans);
        self.mutex.unlock();
        return owned;
    }

    pub fn submitSurface(self: *SurfaceText, prepared: *surface.PreparedSurface, execution: SurfaceExecutionInput) !surface.SurfaceFeedback {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        submit_feedback.markRendered(&self.text_preparer.?.atlas, prepared.text_frame.raster_plan.outputs);
        const submitted = surface.SurfaceFeedback{
            .damage_kind = submit_feedback.damageKind(prepared),
            .uploads_committed = execution.uploads_committed,
            .resolve = prepared.resolve,
            .surface = execution.surface,
            .metrics = undefined,
            .render_us = execution.render_us,
            .content_valid = execution.content_valid,
        };
        var final = submitted;
        final.metrics = submit_feedback.renderMetrics(
            surface.RenderMetrics,
            prepared.prepare_metrics,
            prepared,
            final.uploads_committed,
            final.resolve.counters,
            final.render_us,
        );
        self.mutex.unlock();
        return final;
    }

    pub fn atlasRaster(self: *SurfaceText, key: contract.SpriteKey) ?text.AtlasCache.StoredRaster {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const preparer = self.text_preparer orelse return null;
        return preparer.atlas.rasterForKey(key);
    }

    fn buildPreparedPlans(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: text.OwnedPreparedTextFrame,
    ) !PreparedPlans {
        const surface_damage_rects = try damage.buildSurfaceRects(surface.PixelSize, surface.CellSize, contract.GridMetrics, surface.DamageRect, allocator, prepare.query.render_px, prepare.query.cell_px, grid, prepare.state.damage, prepared.scene.scene.scroll_up_px, prepared.scene.scene.full_redraw);
        errdefer if (surface_damage_rects.len > 0) allocator.free(surface_damage_rects);
        const buffer_damage_rects = try damage.buildBufferRects(surface.PixelSize, surface.CellSize, contract.GridMetrics, surface.DamageRect, allocator, prepare.query.render_px, prepare.query.cell_px, grid, prepare.state.damage, prepared.scene.scene.scroll_up_px, prepared.scene.scene.full_redraw);
        errdefer if (buffer_damage_rects.len > 0) allocator.free(buffer_damage_rects);
        return .{
            .surface_damage_rects = surface_damage_rects,
            .buffer_damage_rects = buffer_damage_rects,
        };
    }

    fn ownPreparedSurface(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: text.OwnedPreparedTextFrame,
        resolve: text_pipeline.ResolveObservability,
        plans: PreparedPlans,
    ) surface.PreparedSurface {
        return .{
            .allocator = allocator,
            .request = prepare.request,
            .required_surface_epoch = prepare.request.known_target_epoch,
            .geometry_epoch = prepare.request.token.geometry_epoch,
            .render_px = prepare.query.render_px,
            .cell_px = prepare.query.cell_px,
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .surface_damage_rects = plans.surface_damage_rects,
            .buffer_damage_rects = plans.buffer_damage_rects,
            .text_frame = prepared,
            .resolve = resolve,
            .prepare_metrics = prepareMetrics(prepared.timings),
        };
    }

    fn ensureTextPreparer(self: *SurfaceText, allocator: std.mem.Allocator, context: *TextContext) !*text.TextFramePreparer {
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try text.TextFramePreparer.initWithProvider(allocator, 2048, ft_hb.textProvider());
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

    fn prepareMetrics(timings: text.PrepareTimings) surface.PrepareMetrics {
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
