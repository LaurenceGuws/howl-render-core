//! Responsibility: implement the OpenGL ES backend owner surface.
//! Ownership: unified renderer GLES backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../render.zig").Render;
const clip_rect = @import("../shared/clip_rect.zig");
const text_cache = @import("../shared/text_cache.zig");
const atlas_mod = @import("internal/atlas.zig");
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

pub const PreparedTextScene = render.Text.Engine.OwnedTextAnalysis;

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

/// GLES backend implementation consuming render apis.
pub const Backend = struct {
    const MaxFallbackFonts = 24;
    pub const AtlasTexCols = 64;

    config: render.BackendConfig,
    pass_count: u64 = 0,
    closed: bool = false,
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_content_valid: bool = false,
    target_fbo: u32 = 0,
    surface_epoch: u64 = 1,
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: u8 = 0,
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
    atlas_next_slot: u32 = 0,
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    ft_mutex: ThreadMutex = .{},
    font_analysis_mutex: ThreadMutex = .{},
    fallback_faces: [MaxFallbackFonts]?FtFace = [_]?FtFace{null} ** MaxFallbackFonts,
    fallback_hb_fonts: [MaxFallbackFonts]?HbFont = [_]?HbFont{null} ** MaxFallbackFonts,
    resolve_counters: render.ResolveCounters = .{},
    resolve_stage: render.ResolveStage = .style_policy,
    active_resolve: ?*render.ResolveObservability = null,
    text_engine: ?render.Text.Engine.Engine = null,
    face_text_cache: text_cache.FaceTextCache,
    shape_run_cache: text_cache.ShapeRunCache,
    glyph_cell_cache: text_cache.GlyphCellCache,

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render.BackendConfig) Backend {
        return .{
            .config = config,
            .face_text_cache = text_cache.FaceTextCache.init(std.heap.c_allocator),
            .shape_run_cache = text_cache.ShapeRunCache.init(std.heap.c_allocator),
            .glyph_cell_cache = text_cache.GlyphCellCache.init(std.heap.c_allocator),
        };
    }

    /// Release backend resources and prevent further rendering.
    pub fn deinit(self: *Backend) void {
        if (self.text_engine) |*engine| {
            engine.deinit();
            self.text_engine = null;
        }
        self.deinitAtlasStorage();
        self.resetLoadedFace();
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
        self.glyph_cell_cache.deinit();
        if (self.ft_lib != null) {
            _ = c.FT_Done_FreeType(self.ft_lib.?);
            self.ft_lib = null;
        }
        self.deinitTargetObjects();
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
            .max_atlas_slots = 1024,
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
            self.resizeOwnedTargetTexture();
        }
    }

    pub fn drawPreparedScene(self: *Backend, scene: render.TextScene) !TextSceneRenderReport {
        if (self.closed) return error.BackendClosed;
        if (hasCurrentContext()) {
            if (self.target_texture == null and self.config.target_texture != 0) {
                self.target_texture = self.config.target_texture;
                self.surface_epoch +%= 1;
                self.target_content_valid = false;
            }
            try self.ensureOwnedTargetTexture();
            if (self.target_texture == null) return error.TargetTextureUnset;
            try self.beginTargetPass();
            defer self.endTargetPass();
            drawTextScene(self, self.config.surface_px, scene);
            self.target_content_valid = true;
        } else if (!builtin.is_test) {
            return error.NoContext;
        }
        self.pass_count += 1;
        return .{
            .pass_index = self.pass_count,
            .texture_id = self.target_texture orelse 0,
            .raster_uploads_committed = 0,
            .full_redraw = scene.full_redraw,
            .scroll_up_px = scene.scroll_up_px,
            .clear_draws = scene.clear_draws.len,
            .background_draws = scene.background_draws.len,
            .sprite_draws = scene.sprite_draws.len,
            .decoration_draws = scene.decoration_draws.len,
            .cursor_draws = scene.cursor_draws.len,
        };
    }

    fn beginTargetPass(self: *Backend) BackendError!void {
        if (self.target_texture == null) return error.TargetTextureUnset;
        if (self.target_fbo == 0) {
            c.glGenFramebuffers(1, @ptrCast(&self.target_fbo));
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.target_fbo);
        c.glFramebufferTexture2D(
            c.GL_FRAMEBUFFER,
            c.GL_COLOR_ATTACHMENT0,
            c.GL_TEXTURE_2D,
            @intCast(self.target_texture.?),
            0,
        );
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
            return error.FramebufferIncomplete;
        }
    }

    fn ensureOwnedTargetTexture(self: *Backend) BackendError!void {
        if (self.target_texture != null) return;
        if (!hasCurrentContext() and !builtin.is_test) return error.NoContext;
        var texture: u32 = 0;
        c.glGenTextures(1, @ptrCast(&texture));
        if (texture == 0) return error.TargetTextureUnset;
        self.target_texture = texture;
        self.owns_target_texture = true;
        self.target_content_valid = false;
        self.surface_epoch +%= 1;
        self.resizeOwnedTargetTexture();
    }

    fn resizeOwnedTargetTexture(self: *Backend) void {
        const texture = self.target_texture orelse return;
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @as(c_int, @intCast(@max(self.config.surface_px.width, 1))),
            @as(c_int, @intCast(@max(self.config.surface_px.height, 1))),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        self.target_content_valid = false;
    }

    fn endTargetPass(_: *Backend) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
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
        if (self.text_engine) |*engine| engine.clearAtlas();
    }

    fn ensureTextEngine(self: *Backend, allocator: std.mem.Allocator) !*render.Text.Engine.Engine {
        if (self.text_engine == null) {
            var ft_hb = self.textProvider();
            self.text_engine = try render.Text.Engine.Engine.initWithProvider(allocator, self.capabilities().max_atlas_slots, ft_hb.textProvider());
        }
        return &self.text_engine.?;
    }

    fn rasterizeFromFont(self: *Backend, dst: []u8, codepoint: u21, gw: u16, gh: u16) ?ResolvedGlyphKey {
        if (!self.ensureFont()) return null;
        self.ft_mutex.lock();
        defer self.ft_mutex.unlock();
        if (self.ft_face) |face| {
            if (self.rasterizeGlyphFromFace(dst, self.hb_font, face, codepoint, primary_face_id, gw, gh)) |key| {
                self.resolve_stage = .loaded_exact_match;
                if (self.active_resolve) |obs| obs.stage = .loaded_exact_match;
                return key;
            }
        }

        const lib = self.ft_lib orelse return null;
        var i: u8 = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            const font_path = self.fallback_font_paths[i] orelse continue;
            var face: FtFace = undefined;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
            defer _ = c.FT_Done_Face(face);

            const fallback_hb = c_api.createHbFont(face);
            defer c_api.destroyHbFont(fallback_hb);

            const face_id = fallbackFaceId(i);
            if (self.rasterizeGlyphFromFace(dst, fallback_hb, face, codepoint, face_id, gw, gh)) |key| {
                self.resolve_stage = .discovery_fallback;
                if (self.active_resolve) |obs| {
                    obs.stage = .discovery_fallback;
                    obs.counters.fallback_hits += 1;
                }
                self.resolve_counters.fallback_hits += 1;
                return key;
            }
        }

        self.resolve_stage = .missing_glyph;
        if (self.active_resolve) |obs| {
            obs.stage = .missing_glyph;
            obs.counters.fallback_misses += 1;
            obs.counters.missing_glyphs += 1;
        }
        self.resolve_counters.fallback_misses += 1;
        self.resolve_counters.missing_glyphs += 1;
        return null;
    }

    fn resolveGlyphKey(self: *Backend, codepoint: u21) ?ResolvedGlyphKey {
        return provider_mod.resolveGlyphKey(self, codepoint);
    }

    fn rasterizeGlyphFromFace(self: *Backend, dst: []u8, hb_font: ?HbFont, face: FtFace, codepoint: u21, face_id: u32, gw: u16, gh: u16) ?ResolvedGlyphKey {
        if (!setFacePixelHeight(self, face)) return null;
        const glyph_id = shapeGlyphId(hb_font, face, codepoint);
        if (glyph_id == 0) return null;
        if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_RENDER) != 0) return null;
        const glyph = face.*.glyph;
        if (glyph == null) return null;
        const bitmap = glyph.*.bitmap;
        if (bitmap.buffer == null or bitmap.width <= 0 or bitmap.rows <= 0) return null;
        const bw: usize = @intCast(bitmap.width);
        const bh: usize = @intCast(bitmap.rows);
        const pitch_abs: usize = @intCast(@abs(bitmap.pitch));
        const pitch_is_negative = bitmap.pitch < 0;
        const placement = render.Text.Metrics.bitmapPlacement(
            .{ .cell_w_px = gw, .cell_h_px = gh, .baseline_px = @intCast(computeBaselineFromFace(face, gh)) },
            faceMetricsInput(face, 1),
            glyph.*.bitmap_left,
            glyph.*.bitmap_top,
            @intCast(bitmap.width),
            @intCast(bitmap.rows),
        );

        var wrote_any = false;
        for (0..bh) |yy| {
            for (0..bw) |xx| {
                const dx_i = placement.x_px + @as(i32, @intCast(xx));
                const dy_i = placement.y_px + @as(i32, @intCast(yy));
                if (dx_i < 0 or dy_i < 0) continue;
                const dx: u16 = @intCast(dx_i);
                const dy: u16 = @intCast(dy_i);
                if (dx >= gw or dy >= gh) continue;
                const src_y = if (pitch_is_negative) (bh - 1 - yy) else yy;
                const src_idx = src_y * pitch_abs + xx;
                const dst_idx = atlasPixelOffset(self.atlas_cell_w, dx, dy);
                dst[dst_idx] = bitmap.buffer[src_idx];
                wrote_any = true;
            }
        }
        self.resolve_counters.shaped_clusters += 1;
        if (self.active_resolve) |obs| obs.counters.shaped_clusters += 1;
        if (!wrote_any) return null;
        return .{ .codepoint = codepoint, .face_id = face_id, .glyph_id = glyph_id };
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
    }

    fn deinitTargetObjects(self: *Backend) void {
        if (self.target_fbo != 0 and hasCurrentContext()) {
            c.glDeleteFramebuffers(1, @ptrCast(&self.target_fbo));
            self.target_fbo = 0;
        }
        if (self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
            var texture = self.target_texture.?;
            c.glDeleteTextures(1, @ptrCast(&texture));
        }
    }
};

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
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
    const alpha = try allocator.alloc(u8, atlasPixelCount(width, height));
    errdefer allocator.free(alpha);
    @memset(alpha, 0);
    _ = provider_mod.rasterizeProviderGlyph(self, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
    return .{
        .allocator = allocator,
        .width_px = width,
        .height_px = height,
        .bearing_x_px = 0,
        .bearing_y_px = 0,
        .advance_px = provider_mod.providerGlyphAdvance(self, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
        .alpha_mask = alpha,
    };
}

fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    return c_api.shapeGlyphId(hb_font, face, codepoint);
}

fn setFacePixelHeight(self: *const Backend, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
}

fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return render.Text.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
}

fn cellSizeFromFace(face: FtFace, font_size_px: u16) render.CellSize {
    const cell = cellMetricsFromFace(face, font_size_px);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

fn cellMetricsFromFace(face: FtFace, font_size_px: u16) render.CellMetrics {
    return render.Text.Metrics.cellMetricsFromFaceMetrics(faceMetricsInput(face, font_size_px));
}

fn faceMetricsInput(face: FtFace, font_size_px: u16) render.Text.Metrics.FaceMetrics26Dot6 {
    const metrics = face.*.size.*.metrics;
    return .{
        .ascender = @intCast(metrics.ascender),
        .descender = @intCast(metrics.descender),
        .height = @intCast(metrics.height),
        .max_advance = asciiCellAdvance(face, @intCast(metrics.max_advance)),
        .fallback_font_px = @max(font_size_px, 1),
    };
}

fn asciiCellAdvance(face: FtFace, fallback_advance: i32) i32 {
    var max_advance: i32 = 0;
    var cp: u32 = 32;
    while (cp < 128) : (cp += 1) {
        const glyph_index = c.FT_Get_Char_Index(face, cp);
        if (glyph_index == 0) continue;
        if (c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_DEFAULT) != 0) continue;
        if (face.*.glyph == null) continue;
        max_advance = @max(max_advance, @as(i32, @intCast(face.*.glyph.*.metrics.horiAdvance)));
    }
    return if (max_advance > 0) max_advance else fallback_advance;
}

fn hasCurrentContext() bool {
    return c.glGetString(c.GL_VERSION) != null;
}

fn mapTextSceneRenderError(err: anyerror) BackendError {
    return switch (err) {
        error.BackendClosed => error.BackendClosed,
        error.NoContext => error.NoContext,
        error.TargetTextureUnset => error.TargetTextureUnset,
        error.FramebufferIncomplete => error.FramebufferIncomplete,
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutOfMemory,
    };
}

fn renderReportFromTextScene(report: TextSceneRenderReport) RenderReport {
    return .{
        .stats = .{
            .fills = report.clear_draws + report.background_draws + report.decoration_draws + report.cursor_draws,
            .glyphs = report.sprite_draws,
            .atlas_uploads = report.raster_uploads_committed,
            .has_cursor = report.cursor_draws > 0,
            .full_redraw = true,
        },
        .pass_index = report.pass_index,
        .atlas_uploads_committed = report.raster_uploads_committed,
    };
}

fn drawTextScene(backend: *const Backend, surface: render.PixelSize, scene: render.TextScene) void {
    c.glViewport(0, 0, @as(c_int, @intCast(surface.width)), @as(c_int, @intCast(surface.height)));
    if (scene.full_redraw) {
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0.0, 0.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    } else if (scene.scroll_up_px > 0) {
        applyScrollReusePx(backend, surface, scene.scroll_up_px);
    }
    c.glDisable(c.GL_DEPTH_TEST);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    defer c.glDisable(c.GL_BLEND);

    for (scene.clear_draws) |draw| {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    for (scene.background_draws) |draw| {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    for (scene.decoration_draws) |draw| {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    for (scene.sprite_draws) |draw| {
        drawSceneSprite(backend, surface, draw);
    }
    for (scene.cursor_draws) |draw| {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
}

fn applyScrollReusePx(backend: *const Backend, surface_px: render.PixelSize, scroll_px_u16: u16) void {
    const texture = backend.target_texture orelse return;
    const scroll_px = @as(u32, scroll_px_u16);
    const width = @as(u32, surface_px.width);
    const height = @as(u32, surface_px.height);
    if (scroll_px == 0 or scroll_px >= height or width == 0) return;
    const preserved_h = height - scroll_px;
    const bytes = rgbaByteCount(@intCast(width), @intCast(preserved_h));
    const pixels = std.heap.c_allocator.alloc(u8, bytes) catch return;
    defer std.heap.c_allocator.free(pixels);
    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glReadPixels(
        0,
        0,
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(preserved_h)),
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        pixels.ptr,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        0,
        @as(c_int, @intCast(scroll_px)),
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(preserved_h)),
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        pixels.ptr,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}

fn drawSceneSprite(backend: *const Backend, surface: render.PixelSize, draw: render.TextSpriteDraw) void {
    if (backend.atlas_pixels.len == 0) return;
    const slot = atlasSlotIndex(draw.sprite.slot);
    if (slot >= backend.atlas_slot_width.len or slot >= backend.atlas_slot_height.len) return;
    if (slot >= backend.atlas_slot_draw_x.len or slot >= backend.atlas_slot_draw_y.len or slot >= backend.atlas_slot_draw_w.len or slot >= backend.atlas_slot_draw_h.len) return;
    const slot_index = slot * backend.atlas_slot_stride;
    if (slot_index + backend.atlas_slot_stride > backend.atlas_pixels.len) return;
    const src = backend.atlas_pixels[slot_index .. slot_index + backend.atlas_slot_stride];
    const draw_x = backend.atlas_slot_draw_x[slot];
    const draw_y = backend.atlas_slot_draw_y[slot];
    const gw = @min(backend.atlas_slot_draw_w[slot], backend.atlas_cell_w -| draw_x);
    const gh = @min(backend.atlas_slot_draw_h[slot], backend.atlas_cell_h -| draw_y);
    if (gw == 0 or gh == 0) return;
    for (0..gh) |yy| {
        for (0..gw) |xx| {
            const src_x: u16 = draw_x + @as(u16, @intCast(xx));
            const src_y: u16 = draw_y + @as(u16, @intCast(yy));
            const idx = atlasPixelOffset(backend.atlas_cell_w, src_x, src_y);
            const alpha = src[idx];
            if (alpha == 0) continue;
            var color = draw.color;
            color.a = @intCast((@as(u16, color.a) * @as(u16, alpha)) / 255);
            drawRect(surface, draw.x_px + @as(i32, src_x), draw.y_px + @as(i32, src_y), 1, 1, color);
        }
    }
}

fn fallbackSlot(self: *Backend, fallback_index: u32) ?usize {
    if (fallback_index >= self.fallback_font_paths_len) return null;
    return @intCast(fallback_index);
}

fn atlasSlotIndex(slot: u32) usize {
    return @intCast(slot);
}

fn atlasPixelOffset(width: u16, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, width) + x;
}

fn atlasPixelCount(width: u16, height: u16) usize {
    return @as(usize, width) * @as(usize, height);
}

fn rgbaByteCount(width: u16, height: u16) usize {
    return atlasPixelCount(width, height) * 4;
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn drawRect(surface: render.PixelSize, x: i32, y: i32, width: u16, height: u16, color: render.Rgba8) void {
    const clipped = clip_rect.clipRect(surface, x, y, width, height) orelse return;
    const inv_255 = 1.0 / 255.0;
    c.glEnable(c.GL_SCISSOR_TEST);
    defer c.glDisable(c.GL_SCISSOR_TEST);
    c.glScissor(
        clipped.x,
        clipped.y,
        clipped.w,
        clipped.h,
    );
    c.glClearColor(
        @as(f32, @floatFromInt(color.r)) * inv_255,
        @as(f32, @floatFromInt(color.g)) * inv_255,
        @as(f32, @floatFromInt(color.b)) * inv_255,
        @as(f32, @floatFromInt(color.a)) * inv_255,
    );
    c.glClear(c.GL_COLOR_BUFFER_BIT);
}

test {
    _ = @import("tests.zig");
}
