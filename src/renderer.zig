//! Responsibility: own the selected render backend runtime surface.
//! Ownership: backend locking, staged prepare/submit lifetime, and renderer counters.
//! Reason: keep terminal packages from wrapping backend internals directly.

const builtin = @import("builtin");
const std = @import("std");
const frame_input = @import("frame_input.zig");
const render_options = @import("render_options");
const render = @import("render.zig").Render;
const time_c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("time.h");
});
const backend_mod = switch (render_options.render_backend) {
    .gl => @import("backend/gl/backend.zig"),
    .gles => @import("backend/gles/backend.zig"),
};

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const Renderer = struct {
    backend: backend_mod.Backend,
    mutex: ThreadMutex = .{},
    text_engine: ?render.Text.Engine.Engine = null,
    prepared: ?FrameRecord = null,
    resolve: render.ResolveObservability = .{},
    target_valid: bool = false,
    target_epoch: u64 = 0,

    pub const FrameLayout = struct {
        cell_px: render.CellSize,
        grid: render.GridSize,
    };

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

    pub const SubmittedReport = struct {
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

    pub const PreparedFrame = struct {
        prepared: backend_mod.PreparedTextScene,

        pub fn deinit(self: *PreparedFrame) void {
            self.prepared.deinit();
            self.* = undefined;
        }

        pub fn timings(self: *const PreparedFrame) PreparedTimings {
            const t = self.prepared.timings;
            return .{
                .input_us = t.input_us,
                .sparse_us = t.sparse_us,
                .clusters_us = t.clusters_us,
                .resolve_us = t.resolve_us,
                .shape_us = t.shape_us,
                .group_us = t.group_us,
                .scene_us = t.scene_us,
                .raster_us = t.raster_us,
                .atlas_us = t.atlas_us,
            };
        }

        pub fn damageKind(self: *const PreparedFrame) DamageKind {
            if (self.prepared.scene.scene.full_redraw) return .full;
            if (self.prepared.scene.scene.scroll_up_px > 0) return .scroll;
            return .partial;
        }
    };

    pub const FrameRecord = struct {
        render_seq: u64,
        render_dirty_epoch: u64,
        geometry_epoch: u64,
        prepare_metrics: render.PrepareMetrics,
        resolve: render.ResolveObservability,
        raster_uploads_committed: u32,
        prepared: PreparedFrame,

        pub fn deinit(self: *FrameRecord) void {
            self.prepared.deinit();
            self.* = undefined;
        }

        pub fn pipelineFrame(self: *const FrameRecord, request: render.FramePipeline.RenderRequest) render.FramePipeline.PreparedFrame {
            const damage_kind: render.FramePipeline.DamageKind = switch (self.prepared.damageKind()) {
                .full => .full,
                .scroll => .scroll,
                .partial => .partial,
            };
            const damage_base_seq = if (damage_kind == .partial or damage_kind == .scroll) request.token.damage_base_seq else 0;
            const token = render.FramePipeline.SnapshotToken{
                .snapshot_seq = self.render_seq,
                .dirty_epoch = self.render_dirty_epoch,
                .geometry_epoch = self.geometry_epoch,
                .damage_base_seq = damage_base_seq,
                .damage_kind = damage_kind,
            };
            return .{
                .token = token,
                .required_base_seq = damage_base_seq,
                .required_target_epoch = request.known_target_epoch,
            };
        }

        pub fn renderMetrics(self: *const FrameRecord, submitted: Submitted, render_us: u64) render.RenderMetrics {
            const report = submitted.report;
            const counters = submitted.resolve.counters;
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
                .uploads = self.raster_uploads_committed,
                .face_checks = counters.face_checks,
                .face_cache_hits = counters.face_cache_hits,
                .shape_requests = counters.shape_requests,
                .shape_cache_hits = counters.shape_cache_hits,
                .fallback_hits = counters.fallback_hits,
                .fallback_misses = counters.fallback_misses,
                .missing_glyphs = counters.missing_glyphs,
            };
        }

        pub fn submittedFrame(self: *const FrameRecord, submitted: Submitted) render.FramePipeline.SubmittedFrame {
            return .{
                .token = .{
                    .snapshot_seq = self.render_seq,
                    .dirty_epoch = self.render_dirty_epoch,
                    .geometry_epoch = self.geometry_epoch,
                    .damage_base_seq = 0,
                    .damage_kind = submitted.damageKind(),
                },
                .target_epoch = submitted.surface.epoch,
                .surface_epoch = submitted.surface.epoch,
                .content_valid = submitted.surface.texture_id != 0,
            };
        }
    };

    pub const Submitted = struct {
        report: SubmittedReport,
        resolve: render.ResolveObservability,
        surface: render.SurfaceHandle,
        metrics: render.RenderMetrics,
        render_us: u64,

        pub fn damageKind(self: Submitted) render.FramePipeline.DamageKind {
            if (self.report.full_redraw) return .full;
            if (self.report.scroll_up_px > 0) return .scroll;
            return .partial;
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
        rendered: Submitted,
    };

    pub fn init(config: render.BackendConfig) Renderer {
        return .{ .backend = backend_mod.Backend.init(config) };
    }

    pub fn deinit(self: *Renderer) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.text_engine) |*engine| {
            engine.deinit();
            self.text_engine = null;
        }
        self.backend.deinit();
    }

    pub fn setFontPath(self: *Renderer, font_path: ?[:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFontPath(font_path);
        self.invalidatePreparedState();
    }

    pub fn setFallbackFontPaths(self: *Renderer, paths: []const [:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFallbackFontPaths(paths);
        self.invalidatePreparedState();
    }

    pub fn setFontSizePx(self: *Renderer, font_size_px: u16) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFontSizePx(font_size_px);
        self.invalidatePreparedState();
    }

    pub fn deriveFrameLayout(
        self: *Renderer,
        render_px: render.PixelSize,
        grid_px: render.PixelSize,
    ) render.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const layout = try self.backend.deriveFrameLayout(render_px, grid_px);
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn prepareFrame(
        self: *Renderer,
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
        try self.backend.applyFrameGeometry(query.render_px, query.cell_px);
        if (self.target_epoch != query.epoch) {
            self.target_epoch = query.epoch;
            self.target_valid = false;
        }
        var input = try frame_input.vtStateToTextSceneInput(allocator, state);
        defer input.deinit();
        if (!self.target_valid) {
            if (self.text_engine) |*engine| engine.clearAtlas();
            input.options.scene.damage.full = true;
            input.options.scene.damage.scroll_up_rows = 0;
        }
        self.resolve = .{};
        const engine = try self.ensureTextEngine(allocator);
        var prepared = try engine.analyzeCellsWithSessionOptions(
            input.cells,
            input.grid,
            self.backend.fontSession(&faces, &self.resolve),
            input.options,
        );
        errdefer prepared.deinit();
        const raster_uploads_committed = try self.backend.uploadTextSceneRaster(prepared.scene.scene, prepared.raster_plan.outputs);
        markRenderedOutputs(&self.text_engine.?.atlas, prepared.raster_plan.outputs);
        self.prepared = .{
            .render_seq = request.token.snapshot_seq,
            .render_dirty_epoch = request.token.dirty_epoch,
            .geometry_epoch = request.token.geometry_epoch,
            .prepare_metrics = prepareMetrics(prepared.timings),
            .resolve = self.resolve,
            .raster_uploads_committed = @intCast(raster_uploads_committed),
            .prepared = .{ .prepared = prepared },
        };
        _ = runtime.publishPrepared(self.prepared.?.pipelineFrame(request));
        self.mutex.unlock();
        return .prepared;
    }

    pub fn submitFrame(self: *Renderer, runtime: *render.RenderRuntime) !SubmitResult {
        return switch (runtime.submit()) {
            .idle => .idle,
            .stale => .stale,
            .needs_full_prepare => .needs_full_prepare,
            .submit => |prepared_frame| blk: {
                const query = runtime.surfaceQuery();
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
                const render_start_ns = monotonicNs();
                const report = try self.backend.drawPreparedScene(prepared.prepared.prepared.scene.scene);
                const submitted = Submitted{
                    .report = .{
                        .texture_id = report.texture_id,
                        .raster_uploads_committed = prepared.raster_uploads_committed,
                        .full_redraw = report.full_redraw,
                        .scroll_up_px = report.scroll_up_px,
                        .clear_draws = report.clear_draws,
                        .background_draws = report.background_draws,
                        .sprite_draws = report.sprite_draws,
                        .decoration_draws = report.decoration_draws,
                        .cursor_draws = report.cursor_draws,
                    },
                    .resolve = prepared.resolve,
                    .surface = .{
                        .texture_id = report.texture_id,
                        .width = @max(query.render_px.width, 1),
                        .height = @max(query.render_px.height, 1),
                        .epoch = query.epoch,
                    },
                    .metrics = undefined,
                    .render_us = elapsedUs(render_start_ns),
                };
                var final = submitted;
                final.metrics = prepared.renderMetrics(final, final.render_us);
                runtime.acceptSubmitted(prepared.submittedFrame(final));
                self.target_valid = final.surface.texture_id != 0;
                prepared.deinit();
                self.prepared = null;
                self.mutex.unlock();
                break :blk .{ .rendered = final };
            },
        };
    }

    fn invalidatePreparedState(self: *Renderer) void {
        self.target_valid = false;
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.text_engine) |*engine| engine.clearAtlas();
    }

    fn monotonicNs() u64 {
        var ts: time_c.struct_timespec = undefined;
        if (time_c.clock_gettime(time_c.CLOCK_MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
    }

    fn elapsedUs(start_ns: u64) u64 {
        return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
    }

    fn ensureTextEngine(self: *Renderer, allocator: std.mem.Allocator) !*render.Text.Engine.Engine {
        if (self.text_engine == null) {
            var ft_hb = self.backend.textProvider();
            self.text_engine = try render.Text.Engine.Engine.initWithProvider(
                allocator,
                self.backend.capabilities().max_atlas_slots,
                ft_hb.textProvider(),
            );
        }
        return &self.text_engine.?;
    }

    fn prepareMetrics(timings: render.Text.Engine.PrepareTimings) render.PrepareMetrics {
        const total = timings.input_us + timings.sparse_us + timings.clusters_us + timings.resolve_us + timings.shape_us + timings.group_us + timings.scene_us + timings.raster_us + timings.atlas_us;
        return .{
            .us = total,
            .renderer_us = total,
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

};
