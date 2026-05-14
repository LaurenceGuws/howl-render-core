//! Responsibility: own the selected render backend runtime surface.
//! Ownership: backend locking, staged prepare/submit lifetime, and renderer counters.
//! Reason: keep terminal packages from wrapping backend internals directly.

const std = @import("std");
const render_options = @import("render_options");
const render = @import("render.zig").Render;
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

    pub const Prepared = struct {
        resolve_before: render.ResolveCounters,
        frame: PreparedFrame,
    };

    pub const FrameRecord = struct {
        render_seq: u64,
        render_dirty_epoch: u64,
        geometry_epoch: u64,
        sync_us: u64,
        copy_us: u64,
        prepare_metrics: render.PrepareMetrics,
        resolve_before: render.ResolveCounters,
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
            const resolve_after = submitted.resolve_after;
            return .{
                .sync_us = self.sync_us,
                .copy_us = self.copy_us,
                .render_us = render_us,
                .glyphs = report.sprite_draws,
                .fills = report.clear_draws + report.background_draws + report.decoration_draws + report.cursor_draws,
                .clear_fills = report.clear_draws,
                .background_fills = report.background_draws,
                .decoration_fills = report.decoration_draws,
                .cursor_fills = report.cursor_draws,
                .uploads = report.raster_uploads_committed,
                .face_checks = resolve_after.face_checks -| self.resolve_before.face_checks,
                .face_cache_hits = resolve_after.face_cache_hits -| self.resolve_before.face_cache_hits,
                .shape_requests = resolve_after.shape_requests -| self.resolve_before.shape_requests,
                .shape_cache_hits = resolve_after.shape_cache_hits -| self.resolve_before.shape_cache_hits,
                .fallback_hits = resolve_after.fallback_hits -| self.resolve_before.fallback_hits,
                .fallback_misses = resolve_after.fallback_misses -| self.resolve_before.fallback_misses,
                .missing_glyphs = resolve_after.missing_glyphs -| self.resolve_before.missing_glyphs,
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
        resolve_after: render.ResolveCounters,
        surface: render.SurfaceHandle,

        pub fn damageKind(self: Submitted) render.FramePipeline.DamageKind {
            if (self.report.full_redraw) return .full;
            if (self.report.scroll_up_px > 0) return .scroll;
            return .partial;
        }
    };

    pub fn init(config: render.BackendConfig) Renderer {
        return .{ .backend = backend_mod.Backend.init(config) };
    }

    pub fn deinit(self: *Renderer) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.deinit();
    }

    pub fn setFontPath(self: *Renderer, font_path: ?[:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFontPath(font_path);
    }

    pub fn setFallbackFontPaths(self: *Renderer, paths: []const [:0]const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFallbackFontPaths(paths);
    }

    pub fn setFontSizePx(self: *Renderer, font_size_px: u16) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.backend.setFontSizePx(font_size_px);
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
        state: render.SurfaceFrameData,
        surface_px: render.PixelSize,
        cell_px: render.CellSize,
    ) !Prepared {
        var faces: [32]render.Text.FontSession.FontFaceRecord = undefined;
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        const resolve_before = self.backend.resolveCounters();
        const prepared = try self.backend.prepareFrame(allocator, state, surface_px, cell_px, &faces);
        self.mutex.unlock();
        return .{ .resolve_before = resolve_before, .frame = .{ .prepared = prepared } };
    }

    pub fn submitFrame(self: *Renderer, frame: *PreparedFrame) !Submitted {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        const report = try self.backend.submitFrame(&frame.prepared);
        const resolve_after = self.backend.resolveCounters();
        const surface = self.backend.surfaceHandle();
        self.mutex.unlock();
        return .{
            .report = .{
                .raster_uploads_committed = report.raster_uploads_committed,
                .full_redraw = report.full_redraw,
                .scroll_up_px = report.scroll_up_px,
                .clear_draws = report.clear_draws,
                .background_draws = report.background_draws,
                .sprite_draws = report.sprite_draws,
                .decoration_draws = report.decoration_draws,
                .cursor_draws = report.cursor_draws,
            },
            .resolve_after = resolve_after,
            .surface = surface,
        };
    }

};
