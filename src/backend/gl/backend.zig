
// This backend is a contract pressure-test, not a host-shaped exception.
// Keep GL limited to C-lib glue, GPU objects, upload, draw, and backend-local mutation only.
// Do not let current host constraints push render policy or orchestration back down into this file.

const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../render.zig").Render;
const shared_text_cache = @import("../shared/text_cache.zig");
const atlas_mod = @import("internal/atlas.zig");
const draw_pass_mod = @import("internal/draw_pass.zig");
const c_api = @import("internal/c_api.zig");
const provider_mod = @import("internal/provider.zig");
const c = c_api.c;
const time_c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("time.h");
});
const FtLibrary = c_api.FtLibrary;
const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

const primary_face_id: u32 = provider_mod.primary_face_id;
const ResolvedGlyphKey = provider_mod.ResolvedGlyphKey;

fn fallbackFaceId(index: u32) u32 {
    return index + 2;
}

fn missingGlyphKey(codepoint: u21) ResolvedGlyphKey {
    return .{ .codepoint = codepoint, .face_id = 0, .glyph_id = codepoint };
}

fn monotonicNs() u64 {
    var ts: time_c.struct_timespec = undefined;
    if (time_c.clock_gettime(time_c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

/// Shared cell-size alias.
pub const CellSize = render.CellSize;
/// Shared surface color alias.
pub const SurfaceColor = render.SurfaceColor;
/// Shared surface cell flag alias.
pub const SurfaceCellFlags = render.SurfaceCellFlags;
/// Shared surface cell attribute alias.
pub const SurfaceCellAttrs = render.SurfaceCellAttrs;
/// Shared surface cell alias.
pub const SurfaceCell = render.SurfaceCell;
/// Shared surface grid model alias.
pub const SurfaceGridModel = render.SurfaceGridModel;
/// Shared surface cursor-shape alias.
pub const SurfaceCursorShape = render.SurfaceCursorShape;
/// Shared surface cursor-info alias.
pub const SurfaceCursorInfo = render.SurfaceCursorInfo;
/// Shared surface viewport-info alias.
pub const SurfaceViewportInfo = render.SurfaceViewportInfo;
/// Shared surface frame-data alias.
pub const SurfaceFrameData = render.SurfaceFrameData;
/// Shared retained surface handle alias.
pub const SurfaceHandle = render.SurfaceHandle;

/// Error set returned by backend lifecycle and render functions.
pub const BackendError = error{
    OutOfMemory,
    BackendClosed,
    NoContext,
    TargetTextureUnset,
    FramebufferIncomplete,
};

/// Render report returned after processing one render pass.
pub const RenderReport = struct {
    stats: render.RenderStats,
    pass_index: u64,
    atlas_uploads_committed: usize,
};

pub const TextSceneRenderReport = struct {
    pass_index: u64,
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

pub const PreparedTextFrame = render.Text.OwnedPreparedTextFrame;

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

pub const FrameLayout = struct {
    cell_px: render.CellSize,
    grid: render.GridSize,
};

pub const Config = render.BackendConfig;
pub const Capability = render.BackendCapability;
pub const Error = BackendError;
pub const Report = RenderReport;

/// GL backend implementation consuming render apis.
pub const Backend = struct {
    const MaxFallbackFonts = 24;
    pub const AtlasTexCols = 64;

    config: render.BackendConfig,
    pass_count: u64 = 0,
    closed: bool = false,
    atlas_pixels: []u8 = &.{},
    atlas_cell_w: u16 = 0,
    atlas_cell_h: u16 = 0,
    atlas_slot_stride: usize = 0,
    atlas_slot_codepoint: []u21 = &.{},
    atlas_slot_face_id: []u32 = &.{},
    atlas_slot_glyph_id: []u32 = &.{},
    atlas_slot_sprite_key: []u64 = &.{},
    atlas_slot_width: []u16 = &.{},
    atlas_slot_height: []u16 = &.{},
    atlas_slot_draw_x: []u16 = &.{},
    atlas_slot_draw_y: []u16 = &.{},
    atlas_slot_draw_w: []u16 = &.{},
    atlas_slot_draw_h: []u16 = &.{},
    atlas_slot_has_alpha: []bool = &.{},
    atlas_slot_gpu_uploaded: []bool = &.{},
    atlas_next_slot: u32 = 0,
    draw_pass: draw_pass_mod.DrawPass = .{},
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    ft_mutex: ThreadMutex = .{},
    font_analysis_mutex: ThreadMutex = .{},
    fallback_faces: [MaxFallbackFonts]?FtFace = [_]?FtFace{null} ** MaxFallbackFonts,
    fallback_hb_fonts: [MaxFallbackFonts]?HbFont = [_]?HbFont{null} ** MaxFallbackFonts,
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_content_valid: bool = false,
    target_fbo: u32 = 0,
    surface_epoch: u64 = 1,
    resolve_counters: render.ResolveCounters = .{},
    resolve_stage: render.ResolveStage = .style_policy,
    active_resolve: ?*render.ResolveObservability = null,
    face_text_cache: shared_text_cache.FaceTextCache,
    shape_run_cache: shared_text_cache.ShapeRunCache,
    glyph_cell_cache: shared_text_cache.GlyphCellCache,
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: u8 = 0,

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render.BackendConfig) Backend {
        return .{
            .config = config,
            .face_text_cache = shared_text_cache.FaceTextCache.init(std.heap.c_allocator),
            .shape_run_cache = shared_text_cache.ShapeRunCache.init(std.heap.c_allocator),
            .glyph_cell_cache = shared_text_cache.GlyphCellCache.init(std.heap.c_allocator),
        };
    }

    /// Release backend resources and prevent further rendering.
    pub fn deinit(self: *Backend) void {
        self.deinitAtlasStorage();
        draw_pass_mod.deinitDrawResources(self);
        self.resetLoadedFace();
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
        self.glyph_cell_cache.deinit();
        if (self.ft_lib != null) {
            _ = c.FT_Done_FreeType(self.ft_lib.?);
            self.ft_lib = null;
        }
        draw_pass_mod.deinitTargetObjects(self);
        self.target_texture = null;
        self.owns_target_texture = false;
        self.target_content_valid = false;
        self.closed = true;
    }

    /// Bind an external texture as this backend's render target.
    pub fn bindTargetTexture(self: *Backend, texture: u32) BackendError!void {
        if (self.closed) return error.BackendClosed;
        if (texture == 0) return error.TargetTextureUnset;
        const texture_changed = self.target_texture == null or self.target_texture.? != texture;
        if (self.owns_target_texture and self.target_texture != null and self.target_texture.? != texture and hasCurrentContext()) {
            var old_texture = self.target_texture.?;
            c.glDeleteTextures(1, @ptrCast(&old_texture));
        }
        self.target_texture = texture;
        self.owns_target_texture = false;
        if (texture_changed) {
            self.surface_epoch +%= 1;
            self.target_content_valid = false;
        }
    }

    pub fn setFontPath(self: *Backend, font_path: ?[:0]const u8) void {
        self.lockFontAnalysis();
        defer self.unlockFontAnalysis();
        self.config.font_path = font_path;
        self.resetLoadedFace();
        self.clearAtlasCache();
    }

    pub fn setFallbackFontPaths(self: *Backend, paths: []const [:0]const u8) void {
        self.lockFontAnalysis();
        defer self.unlockFontAnalysis();
        const n: u8 = @intCast(@min(paths.len, MaxFallbackFonts));
        self.fallback_font_paths_len = n;
        for (0..n) |i| self.fallback_font_paths[i] = paths[i];
        for (@as(usize, n)..MaxFallbackFonts) |i| self.fallback_font_paths[i] = null;
        self.resetLoadedFace();
        self.clearAtlasCache();
    }

    pub fn setFontSizePx(self: *Backend, font_size_px: u16) void {
        self.lockFontAnalysis();
        defer self.unlockFontAnalysis();
        self.config.font_size_px = @max(font_size_px, 1);
        self.resizeLoadedFaces();
        self.clearAtlasCache();
    }

    pub fn deriveFrameLayout(
        self: *Backend,
        render_px: render.PixelSize,
        grid_px: render.PixelSize,
    ) render.FrameGeometryError!FrameLayout {
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        const cell_px = self.deriveCellSize();
        return .{
            .cell_px = cell_px,
            .grid = render.deriveGridSize(grid_px, cell_px),
        };
    }

    pub fn textProvider(self: *Backend) render.Text.FtHbProvider.FtHbSource {
        return .{
            .ctx = self,
            .has_codepoint = providerHasCodepoint,
            .shaper = .{ .ctx = self, .shape_run = providerShapeRun },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSprite },
            .glyph_lookup = .{ .ctx = self, .lookup_glyph = providerLookupGlyph },
            .glyph_raster = .{ .ctx = self, .call = providerRasterizeGlyph },
        };
    }

    pub fn fontSession(self: *Backend, faces: []render.Text.FontSession.FontFaceRecord, active_resolve: ?*render.ResolveObservability) render.Text.FontSession.FontSession {
        self.active_resolve = active_resolve;
        var len: usize = 0;
        if (faces.len > len) {
            faces[len] = .{ .id = .{ .value = primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: u8 = 0;
        while (i < self.fallback_font_paths_len and len < faces.len) : (i += 1) {
            if (self.fallback_font_paths[i] == null) continue;
            faces[len] = .{ .id = .{ .value = fallbackFaceId(i) }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = primary_face_id },
            .faces = faces[0..len],
            .provider = .{ .ctx = self, .has_cell_text = providerHasCellText },
            .metrics = self.configuredCellMetrics(),
        };
    }

    pub fn uploadTextSceneRaster(
        self: *Backend,
        scene: render.TextScene,
        outputs: []const render.Text.Rasterizer.RasterSpriteOutput,
    ) BackendError!usize {
        return atlas_mod.uploadTextSceneRaster(self, scene, outputs);
    }

    /// Report backend capabilities used by render batch generation.
    pub fn capabilities(_: *const Backend) render.BackendCapability {
        return .{
            .max_atlas_slots = 2048,
            .supports_fill_rect = true,
            .supports_glyph_quads = true,
        };
    }

    pub fn applyFrameGeometry(self: *Backend, surface_px: render.PixelSize, cell_px: render.CellSize) BackendError!void {
        if (self.closed) return error.BackendClosed;
        const surface_changed = self.config.surface_px.width != surface_px.width or self.config.surface_px.height != surface_px.height;
        const cell_changed = self.config.cell_px.width != cell_px.width or self.config.cell_px.height != cell_px.height;
        self.config.surface_px = surface_px;
        self.config.cell_px = cell_px;
        if (cell_changed) self.clearAtlasCache();
        if (surface_changed) self.surface_epoch +%= 1;
        if (surface_changed) self.target_content_valid = false;
        if (surface_changed and self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
            draw_pass_mod.resizeOwnedTargetTexture(self);
        }
    }

    pub fn drawPreparedScene(self: *Backend, scene: render.TextScene) !TextSceneRenderReport {
        if (self.closed) return error.BackendClosed;
        if (!hasCurrentContext()) {
            if (builtin.is_test) {
                self.pass_count += 1;
                return draw_pass_mod.textSceneRenderReport(TextSceneRenderReport, self, scene);
            }
            return error.NoContext;
        }
        try draw_pass_mod.prepareSceneTarget(self);
        try draw_pass_mod.beginTargetPass(self);
        defer draw_pass_mod.endTargetPass(self);
        draw_pass_mod.drawTextScene(self, self.config.surface_px, scene);
        self.target_content_valid = true;
        self.pass_count += 1;
        return draw_pass_mod.textSceneRenderReport(TextSceneRenderReport, self, scene);
    }

    fn slotCached(self: *const Backend, slot: u32, key: ResolvedGlyphKey, width: u16, height: u16) bool {
        const idx = atlasSlotIndex(slot);
        if (idx >= self.atlas_slot_codepoint.len) return false;
        if (idx >= self.atlas_slot_face_id.len or idx >= self.atlas_slot_glyph_id.len) return false;
        return self.atlas_slot_codepoint[idx] == key.codepoint and
            self.atlas_slot_face_id[idx] == key.face_id and
            self.atlas_slot_glyph_id[idx] == key.glyph_id and
            self.atlas_slot_width[idx] == width and
            self.atlas_slot_height[idx] == height;
    }

    fn findCachedSlot(self: *const Backend, key: ResolvedGlyphKey, width: u16, height: u16) ?u32 {
        for (self.atlas_slot_codepoint, 0..) |_, idx| {
            if (self.atlas_slot_width[idx] == 0 or self.atlas_slot_height[idx] == 0) continue;
            if (!self.slotCached(@intCast(idx), key, width, height)) continue;
            return @intCast(idx);
        }
        return null;
    }

    fn findCachedSlotForDraw(self: *const Backend, codepoint: u21, width: u16, height: u16) ?u32 {
        for (self.atlas_slot_codepoint, 0..) |slot_codepoint, idx| {
            if (self.atlas_slot_width[idx] == 0 or self.atlas_slot_height[idx] == 0) continue;
            if (slot_codepoint != codepoint) continue;
            if (self.atlas_slot_width[idx] != width or self.atlas_slot_height[idx] != height) continue;
            return @intCast(idx);
        }
        return null;
    }

    fn allocateSlot(self: *Backend) ?u32 {
        for (self.atlas_slot_width, 0..) |slot_width, idx| {
            if (slot_width == 0 and self.atlas_slot_height[idx] == 0) {
                return @intCast(idx);
            }
        }
        if (self.atlas_slot_width.len == 0) return null;
        const slot = self.atlas_next_slot;
        self.atlas_next_slot = (self.atlas_next_slot + 1) % self.capabilities().max_atlas_slots;
        return slot;
    }

    fn markSlotCached(self: *Backend, slot: u32, key: ResolvedGlyphKey, width: u16, height: u16) void {
        const idx = atlasSlotIndex(slot);
        if (idx >= self.atlas_slot_codepoint.len) return;
        self.atlas_slot_codepoint[idx] = key.codepoint;
        if (idx < self.atlas_slot_face_id.len) self.atlas_slot_face_id[idx] = key.face_id;
        if (idx < self.atlas_slot_glyph_id.len) self.atlas_slot_glyph_id[idx] = key.glyph_id;
        self.atlas_slot_width[idx] = width;
        self.atlas_slot_height[idx] = height;
    }

    fn rasterizeSlot(self: *Backend, slot: u32, codepoint: u21, width: u16, height: u16) ResolvedGlyphKey {
        if (self.atlas_pixels.len == 0) return missingGlyphKey(codepoint);
        const slot_index = atlasSlotIndex(slot) * self.atlas_slot_stride;
        const dst = self.atlas_pixels[slot_index .. slot_index + self.atlas_slot_stride];
        @memset(dst, 0);
        const gw = @min(width, self.atlas_cell_w);
        const gh = @min(height, self.atlas_cell_h);
        if (provider_mod.rasterizeFromFont(self, dst, codepoint, gw, gh)) |key| {
            self.markSlotAlpha(slot, dst, gw, gh);
            return key;
        }
        self.resolve_stage = .missing_glyph;
        if (self.active_resolve) |obs| obs.stage = .missing_glyph;
        rasterizeFallbackGlyph(dst, self.atlas_cell_w, self.atlas_cell_h, codepoint, gw, gh);
        self.markSlotAlpha(slot, dst, gw, gh);
        return missingGlyphKey(codepoint);
    }

    fn markSlotAlpha(self: *Backend, slot: u32, pixels: []const u8, gw: u16, gh: u16) void {
        const slot_idx = atlasSlotIndex(slot);
        if (slot_idx >= self.atlas_slot_has_alpha.len) return;
        for (0..gh) |yy| {
            for (0..gw) |xx| {
                if (pixels[atlasPixelOffset(self.atlas_cell_w, @intCast(xx), @intCast(yy))] != 0) {
                    self.atlas_slot_has_alpha[slot_idx] = true;
                    return;
                }
            }
        }
        self.atlas_slot_has_alpha[slot_idx] = false;
    }

    fn lockFontAnalysis(self: *Backend) void {
        self.font_analysis_mutex.lock();
    }

    fn unlockFontAnalysis(self: *Backend) void {
        self.font_analysis_mutex.unlock();
    }

    fn ensurePrimaryFont(self: *Backend) bool {
        return provider_mod.ensurePrimaryFont(self);
    }

    fn ensureFont(self: *Backend) bool {
        return provider_mod.ensureFont(self);
    }

    fn resetLoadedFace(self: *Backend) void {
        provider_mod.resetLoadedFace(self);
        self.face_text_cache.clear();
        self.shape_run_cache.clear();
        self.glyph_cell_cache.clear();
    }

    fn resizeLoadedFaces(self: *Backend) void {
        provider_mod.resizeLoadedFaces(self);
        self.face_text_cache.clear();
        self.shape_run_cache.clear();
        self.glyph_cell_cache.clear();
    }

    fn ensureFallbackFace(self: *Backend, fallback_index: u32) ?FtFace {
        return provider_mod.ensureFallbackFace(self, fallback_index);
    }

    fn clearAtlasCache(self: *Backend) void {
        atlas_mod.clearAtlasCache(self);
    }

    fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
        return provider_mod.computeBaselineFromFace(face, cell_h);
    }

    fn deriveCellMetrics(self: *Backend) render.CellMetrics {
        return provider_mod.deriveCellMetrics(self);
    }

    fn configuredCellMetrics(self: *Backend) render.CellMetrics {
        return provider_mod.configuredCellMetrics(self);
    }

    fn deriveCellSize(self: *Backend) render.CellSize {
        return provider_mod.deriveCellSize(self);
    }

    fn deinitAtlasStorage(self: *Backend) void {
        freeOwnedSlice(u8, &self.atlas_pixels);
        freeOwnedSlice(u21, &self.atlas_slot_codepoint);
        freeOwnedSlice(u32, &self.atlas_slot_face_id);
        freeOwnedSlice(u32, &self.atlas_slot_glyph_id);
        freeOwnedSlice(u64, &self.atlas_slot_sprite_key);
        freeOwnedSlice(u16, &self.atlas_slot_width);
        freeOwnedSlice(u16, &self.atlas_slot_height);
        freeOwnedSlice(u16, &self.atlas_slot_draw_x);
        freeOwnedSlice(u16, &self.atlas_slot_draw_y);
        freeOwnedSlice(u16, &self.atlas_slot_draw_w);
        freeOwnedSlice(u16, &self.atlas_slot_draw_h);
        freeOwnedSlice(bool, &self.atlas_slot_has_alpha);
        freeOwnedSlice(bool, &self.atlas_slot_gpu_uploaded);
    }

};

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
}

fn atlasSlotIndex(slot: u32) usize {
    return @intCast(slot);
}

fn atlasPixelOffset(width: u16, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, width) + x;
}

fn providerHasCodepoint(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32) bool {
    return provider_mod.providerHasCodepoint(Backend, ctx, face_id, codepoint);
}

fn providerHasCellText(ctx: *anyopaque, face_id: render.FontFaceId, text: render.CellText) bool {
    return provider_mod.providerHasCellText(Backend, ctx, face_id, text);
}

fn providerShapeRun(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    return provider_mod.providerShapeRun(Backend, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
}

fn isIconCodepoint(cp: u32) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x1f100 and cp <= 0x1f1ff) or
        (cp >= 0xf0000 and cp <= 0xffffd) or
        (cp >= 0x100000 and cp <= 0x10fffd);
}

fn providerGlyphId(self: *Backend, face_id: render.FontFaceId, codepoint: u32) u32 {
    return provider_mod.providerGlyphId(self, face_id, codepoint);
}

fn providerGlyphAdvance(self: *Backend, face_id: render.FontFaceId, glyph_id: u32, cell_metrics: render.CellMetrics) f32 {
    return provider_mod.providerGlyphAdvance(self, face_id, glyph_id, cell_metrics);
}

fn providerRasterizeSprite(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render.SpriteRasterRequest,
) anyerror!render.Text.Rasterizer.RasterSpriteOutput {
    return provider_mod.providerRasterizeSprite(Backend, ctx, allocator, req);
}

fn providerLookupGlyph(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
    return provider_mod.providerLookupGlyph(Backend, ctx, face_id, codepoint, cell_metrics);
}

fn providerRasterizeGlyph(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.RasterizeRequest) anyerror!render.RasterizeOutput {
    const self: *Backend = @ptrCast(@alignCast(ctx));
    const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
    const height = @max(req.cell_metrics.cell_h_px, 1);
    const alpha = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(alpha);
    @memset(alpha, 0);
    _ = provider_mod.rasterizeProviderGlyph(self, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
    return .{
        .allocator = allocator,
        .width_px = width,
        .height_px = height,
        .bearing_x_px = 0,
        .bearing_y_px = 0,
        .advance_px = providerGlyphAdvance(self, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
        .alpha_mask = alpha,
    };
}

fn rasterizeSpecialSpriteAlpha(dst: []u8, width: u16, height: u16, codepoint: u32) void {
    const w = @max(width, 1);
    const h = @max(height, 1);
    const th_h: u16 = @max(1, h / 8);
    const th_v: u16 = th_h;
    switch (codepoint) {
        0x2500, 0x2501, 0x2574, 0x2576 => drawAlphaH(dst, w, h, th_h, .full),
        0x2502, 0x2503, 0x2575, 0x2577 => drawAlphaV(dst, w, h, th_v, .full),
        0x250c, 0x250d, 0x250e, 0x250f => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2510, 0x2511, 0x2512, 0x2513 => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2514, 0x2515, 0x2516, 0x2517 => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x2518, 0x2519, 0x251a, 0x251b => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x251c...0x2523 => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x2524...0x252b => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x252c...0x2533 => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2534...0x253b => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x253c...0x254b => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x256d => drawAlphaRoundedCorner(dst, w, h, .top_left, @max(th_h, th_v)),
        0x256e => drawAlphaRoundedCorner(dst, w, h, .top_right, @max(th_h, th_v)),
        0x2570 => drawAlphaRoundedCorner(dst, w, h, .bottom_left, @max(th_h, th_v)),
        0x256f => drawAlphaRoundedCorner(dst, w, h, .bottom_right, @max(th_h, th_v)),
        0x2580 => drawAlphaRect(dst, w, 0, 0, w, @max(1, h / 2), 255),
        0x2584 => {
            const hh = @max(1, h / 2);
            drawAlphaRect(dst, w, 0, h - hh, w, hh, 255);
        },
        0x2588 => drawAlphaRect(dst, w, 0, 0, w, h, 255),
        0x258c => drawAlphaRect(dst, w, 0, 0, @max(1, w / 2), h, 255),
        0x2590 => {
            const hw = @max(1, w / 2);
            drawAlphaRect(dst, w, w - hw, 0, hw, h, 255);
        },
        0x2591 => fillAlphaChecker(dst, w, h, 0x33),
        0x2592 => fillAlphaChecker(dst, w, h, 0x77),
        0x2593 => fillAlphaChecker(dst, w, h, 0xbb),
        else => {},
    }
}

const AlphaSegment = enum { full, left, right, top, bottom };
const AlphaCorner = enum { top_left, top_right, bottom_left, bottom_right };

fn drawAlphaH(dst: []u8, w: u16, h: u16, t: u16, segment: AlphaSegment) void {
    const y = (h - t) / 2;
    const mid = (w - @min(t, w)) / 2;
    const x: u16 = switch (segment) {
        .full, .top, .bottom => 0,
        .left => 0,
        .right => mid,
    };
    const width: u16 = switch (segment) {
        .full, .top, .bottom => w,
        .left => @max(mid + t, 1),
        .right => w - mid,
    };
    drawAlphaRect(dst, w, x, y, width, t, 255);
}

fn drawAlphaV(dst: []u8, w: u16, h: u16, t: u16, segment: AlphaSegment) void {
    const x = (w - t) / 2;
    const mid = (h - @min(t, h)) / 2;
    const y: u16 = switch (segment) {
        .full, .left, .right => 0,
        .top => 0,
        .bottom => mid,
    };
    const height: u16 = switch (segment) {
        .full, .left, .right => h,
        .top => @max(mid + t, 1),
        .bottom => h - mid,
    };
    drawAlphaRect(dst, w, x, y, t, height, 255);
}

fn drawAlphaRect(dst: []u8, stride: u16, x: u16, y: u16, width: u16, height: u16, alpha: u8) void {
    const stride_usize = @as(usize, stride);
    for (y..y + height) |yy| {
        const row = yy * stride_usize;
        for (x..x + width) |xx| dst[row + xx] = alpha;
    }
}

fn fillAlphaChecker(target: []u8, width: u16, height: u16, alpha: u8) void {
    for (0..height) |yy| {
        for (0..width) |xx| {
            if (((xx + yy) & 1) == 0) target[yy * @as(usize, width) + xx] = alpha;
        }
    }
}

fn drawAlphaRoundedCorner(dst: []u8, w: u16, h: u16, corner: AlphaCorner, thickness: u16) void {
    const wf = @as(f64, @floatFromInt(w));
    const hf = @as(f64, @floatFromInt(h));
    const mid_x = wf / 2.0;
    const mid_y = hf / 2.0;
    const t = @max(@as(f64, @floatFromInt(thickness)), 1.0);
    const p0 = switch (corner) {
        .top_left, .bottom_left => PointF{ .x = wf, .y = mid_y },
        .top_right, .bottom_right => PointF{ .x = 0.0, .y = mid_y },
    };
    const p1 = PointF{ .x = mid_x, .y = mid_y };
    const p2 = switch (corner) {
        .top_left, .top_right => PointF{ .x = mid_x, .y = hf },
        .bottom_left, .bottom_right => PointF{ .x = mid_x, .y = 0.0 },
    };
    drawAlphaQuadraticStroke(dst, w, h, p0, p1, p2, t);
}

const PointF = struct { x: f64, y: f64 };

fn drawAlphaQuadraticStroke(dst: []u8, w: u16, h: u16, p0: PointF, p1: PointF, p2: PointF, thickness: f64) void {
    const half = thickness / 2.0;
    const samples = 48;
    for (0..h) |yy| {
        for (0..w) |xx| {
            const px = @as(f64, @floatFromInt(xx)) + 0.5;
            const py = @as(f64, @floatFromInt(yy)) + 0.5;
            var min_d2: f64 = std.math.floatMax(f64);
            var i: usize = 0;
            while (i <= samples) : (i += 1) {
                const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples));
                const inv = 1.0 - u;
                const cx = inv * inv * p0.x + 2.0 * inv * u * p1.x + u * u * p2.x;
                const cy = inv * inv * p0.y + 2.0 * inv * u * p1.y + u * u * p2.y;
                const dx = px - cx;
                const dy = py - cy;
                min_d2 = @min(min_d2, dx * dx + dy * dy);
            }
            const dist = @sqrt(min_d2);
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            const alpha: u8 = @intFromFloat(@round(coverage * 255.0));
            const off = yy * @as(usize, w) + xx;
            dst[off] = @max(dst[off], alpha);
        }
    }
}

fn hasCurrentContext() bool {
    return c.glGetString(c.GL_VERSION) != null;
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

test {
    _ = @import("tests.zig");
}
