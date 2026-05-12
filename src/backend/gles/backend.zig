//! Responsibility: implement the OpenGL ES backend owner surface.
//! Ownership: unified renderer GLES backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../render_core.zig").RenderCore;
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

const primary_face_id: u32 = provider_mod.primary_face_id;

const ResolvedGlyphKey = provider_mod.ResolvedGlyphKey;

fn fallbackFaceId(index: usize) u32 {
    return @intCast(index + 2);
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
pub const CellSize = render_core.CellSize;
/// Shared surface color alias.
pub const SurfaceColor = render_core.SurfaceColor;
/// Shared surface cell flag alias.
pub const SurfaceCellFlags = render_core.SurfaceCellFlags;
/// Shared surface cell attribute alias.
pub const SurfaceCellAttrs = render_core.SurfaceCellAttrs;
/// Shared surface cell alias.
pub const SurfaceCell = render_core.SurfaceCell;
/// Shared surface grid model alias.
pub const SurfaceGridModel = render_core.SurfaceGridModel;
/// Shared surface cursor-shape alias.
pub const SurfaceCursorShape = render_core.SurfaceCursorShape;
/// Shared surface cursor-info alias.
pub const SurfaceCursorInfo = render_core.SurfaceCursorInfo;
/// Shared surface viewport-info alias.
pub const SurfaceViewportInfo = render_core.SurfaceViewportInfo;
/// Shared surface frame-data alias.
pub const SurfaceFrameData = render_core.SurfaceFrameData;
/// Shared retained surface handle alias.
pub const SurfaceHandle = render_core.SurfaceHandle;

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
    stats: render_core.RenderStats,
    pass_index: u64,
    atlas_uploads_committed: usize,
};

pub const TextSceneRenderReport = struct {
    pass_index: u64,
    raster_uploads_committed: usize,
    full_redraw: bool,
    scroll_up_px: u16,
    clear_draws: usize,
    background_draws: usize,
    sprite_draws: usize,
    decoration_draws: usize,
    cursor_draws: usize,
};

pub const PreparedTextScene = render_core.Text.Engine.OwnedTextAnalysis;

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

pub const FrameLayout = struct {
    cell_px: render_core.CellSize,
    grid: render_core.GridSize,
};

/// Primary export surface for the GLES renderer implementation.
pub const Config = render_core.BackendConfig;
pub const Capability = render_core.BackendCapability;
pub const Error = BackendError;
pub const Report = RenderReport;

pub fn init(config: Config) Backend {
    return Backend.init(config);
}

/// Derive grid dimensions through the shared render-core policy.
pub fn deriveGridSize(grid_px: render_core.PixelSize, cell_px: CellSize) render_core.GridSize {
    return render_core.deriveGridSize(grid_px, cell_px);
}

/// Validate frame geometry and derive grid dimensions.
pub fn deriveGridForFrame(
    render_px: render_core.PixelSize,
    grid_px: render_core.PixelSize,
    cell_px: CellSize,
) render_core.FrameGeometryError!render_core.GridSize {
    return render_core.deriveGridForFrame(render_px, grid_px, cell_px);
}

/// GLES backend implementation consuming render-core apis.
pub const Backend = struct {
    const MaxFallbackFonts = 24;

    config: render_core.BackendConfig,
    pass_count: u64 = 0,
    closed: bool = false,
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_content_valid: bool = false,
    target_fbo: u32 = 0,
    surface_epoch: u64 = 1,
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: usize = 0,
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
    fallback_faces: [MaxFallbackFonts]?FtFace = [_]?FtFace{null} ** MaxFallbackFonts,
    fallback_hb_fonts: [MaxFallbackFonts]?HbFont = [_]?HbFont{null} ** MaxFallbackFonts,
    resolve_counters: render_core.ResolveCounters = .{},
    resolve_stage: render_core.ResolveStage = .style_policy,
    text_engine: ?render_core.Text.Engine.Engine = null,
    face_text_cache: text_cache.FaceTextCache,
    shape_run_cache: text_cache.ShapeRunCache,
    glyph_cell_cache: text_cache.GlyphCellCache,

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render_core.BackendConfig) Backend {
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
        if (self.atlas_pixels.len > 0) {
            std.heap.c_allocator.free(self.atlas_pixels);
            self.atlas_pixels = &.{};
        }
        if (self.atlas_slot_codepoint.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_codepoint);
            self.atlas_slot_codepoint = &.{};
        }
        if (self.atlas_slot_face_id.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_face_id);
            self.atlas_slot_face_id = &.{};
        }
        if (self.atlas_slot_glyph_id.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_glyph_id);
            self.atlas_slot_glyph_id = &.{};
        }
        if (self.atlas_slot_sprite_key.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_sprite_key);
            self.atlas_slot_sprite_key = &.{};
        }
        if (self.atlas_slot_width.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_width);
            self.atlas_slot_width = &.{};
        }
        if (self.atlas_slot_height.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_height);
            self.atlas_slot_height = &.{};
        }
        if (self.atlas_slot_draw_x.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_draw_x);
            self.atlas_slot_draw_x = &.{};
        }
        if (self.atlas_slot_draw_y.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_draw_y);
            self.atlas_slot_draw_y = &.{};
        }
        if (self.atlas_slot_draw_w.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_draw_w);
            self.atlas_slot_draw_w = &.{};
        }
        if (self.atlas_slot_draw_h.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_draw_h);
            self.atlas_slot_draw_h = &.{};
        }
        if (self.atlas_slot_has_alpha.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_has_alpha);
            self.atlas_slot_has_alpha = &.{};
        }
        self.resetLoadedFace();
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
        self.glyph_cell_cache.deinit();
        if (self.target_fbo != 0 and hasCurrentContext()) {
            c.glDeleteFramebuffers(1, @ptrCast(&self.target_fbo));
            self.target_fbo = 0;
        }
        if (self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
            var texture = self.target_texture.?;
            c.glDeleteTextures(1, @ptrCast(&texture));
        }
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

    pub fn targetTexture(self: *const Backend) u32 {
        return self.target_texture orelse 0;
    }

    pub fn surfaceHandle(self: *const Backend) SurfaceHandle {
        return .{
            .texture_id = self.target_texture orelse 0,
            .width = @max(self.config.surface_px.width, 1),
            .height = @max(self.config.surface_px.height, 1),
            .epoch = self.surface_epoch,
        };
    }

    pub fn setFontPath(self: *Backend, font_path: ?[:0]const u8) void {
        self.config.font_path = font_path;
        self.resetLoadedFace();
        self.clearAtlasCache();
    }

    pub fn setFallbackFontPaths(self: *Backend, paths: []const [:0]const u8) void {
        const n = @min(paths.len, MaxFallbackFonts);
        self.fallback_font_paths_len = n;
        var i: usize = 0;
        while (i < n) : (i += 1) self.fallback_font_paths[i] = paths[i];
        while (i < MaxFallbackFonts) : (i += 1) self.fallback_font_paths[i] = null;
        self.resetLoadedFace();
        self.clearAtlasCache();
    }

    pub fn setFontSizePx(self: *Backend, font_size_px: u16) void {
        self.config.font_size_px = @max(font_size_px, 1);
        self.resetLoadedFace();
        self.clearAtlasCache();
    }

    pub fn deriveFrameLayout(
        self: *Backend,
        render_px: render_core.PixelSize,
        grid_px: render_core.PixelSize,
    ) render_core.FrameGeometryError!FrameLayout {
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        const cell_px = self.deriveCellSize();
        return .{
            .cell_px = cell_px,
            .grid = render_core.deriveGridSize(grid_px, cell_px),
        };
    }

    pub fn resolveCounters(self: *const Backend) render_core.ResolveCounters {
        return self.resolve_counters;
    }

    pub fn lastResolveStage(self: *const Backend) render_core.ResolveStage {
        return self.resolve_stage;
    }

    pub fn textProvider(self: *Backend) render_core.Text.FtHbProvider.FtHbSource {
        return .{
            .ctx = self,
            .has_codepoint = providerHasCodepoint,
            .shaper = .{ .ctx = self, .shape_run = providerShapeRun },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSprite },
            .glyph_lookup = .{ .ctx = self, .lookup_glyph = providerLookupGlyph },
            .glyph_raster = .{ .ctx = self, .call = providerRasterizeGlyph },
        };
    }

    pub fn fontSession(self: *Backend, faces: []render_core.Text.FontSession.FontFaceRecord) render_core.Text.FontSession.FontSession {
        var len: usize = 0;
        if (faces.len > len) {
            faces[len] = .{ .id = .{ .value = primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: usize = 0;
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

    pub fn analyzeTextCells(
        self: *Backend,
        allocator: std.mem.Allocator,
        cells: []const render_core.CellInput,
        grid: render_core.GridMetrics,
        faces: []render_core.Text.FontSession.FontFaceRecord,
    ) !render_core.Text.Engine.OwnedTextAnalysis {
        return self.analyzeTextCellsOptions(allocator, cells, grid, faces, .{});
    }

    pub fn analyzeTextCellsOptions(
        self: *Backend,
        allocator: std.mem.Allocator,
        cells: []const render_core.CellInput,
        grid: render_core.GridMetrics,
        faces: []render_core.Text.FontSession.FontFaceRecord,
        options: render_core.Text.Engine.AnalysisOptions,
    ) !render_core.Text.Engine.OwnedTextAnalysis {
        const engine = try self.ensureTextEngine(allocator);
        return engine.analyzeCellsWithSessionOptions(cells, grid, self.fontSession(faces), options);
    }

    pub fn uploadTextAnalysisRaster(self: *Backend, analysis: render_core.Text.Engine.OwnedTextAnalysis) BackendError!usize {
        return self.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    }

    pub fn uploadTextSceneRaster(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput,
    ) BackendError!usize {
        return atlas_mod.uploadTextSceneRaster(self, scene, outputs);
    }

    fn ensureAtlasStorageForRasterOutputs(self: *Backend, outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput) BackendError!void {
        return atlas_mod.ensureAtlasStorageForRasterOutputs(self, outputs);
    }

    pub fn renderTextScene(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput,
    ) !TextSceneRenderReport {
        if (self.closed) return error.BackendClosed;
        var committed_uploads: usize = 0;
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
            committed_uploads = try self.uploadTextSceneRaster(scene, outputs);
            drawTextScene(self, self.config.surface_px, scene);
            self.target_content_valid = true;
        } else if (!builtin.is_test) {
            return error.NoContext;
        } else {
            committed_uploads = try self.uploadTextSceneRaster(scene, outputs);
        }
        self.pass_count += 1;
        return .{
            .pass_index = self.pass_count,
            .raster_uploads_committed = committed_uploads,
            .full_redraw = scene.full_redraw,
            .scroll_up_px = scene.scroll_up_px,
            .clear_draws = scene.clear_draws.len,
            .background_draws = scene.background_draws.len,
            .sprite_draws = scene.sprite_draws.len,
            .decoration_draws = scene.decoration_draws.len,
            .cursor_draws = scene.cursor_draws.len,
        };
    }

    /// Report backend capabilities used by render-core batch generation.
    pub fn capabilities(_: *const Backend) render_core.BackendCapability {
        return .{
            .max_atlas_slots = 1024,
            .supports_fill_rect = true,
            .supports_glyph_quads = true,
        };
    }

    /// Update surface and cell dimensions after window resize.
    pub fn resize(self: *Backend, surface_px: render_core.PixelSize, cell_px: render_core.CellSize) BackendError!void {
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

    /// Canonical active render path for frame snapshots.
    pub fn renderFrameState(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
    ) BackendError!RenderReport {
        var faces: [MaxFallbackFonts + 1]render_core.Text.FontSession.FontFaceRecord = undefined;
        const scene_report = self.renderFrameStateTextScene(allocator, state, surface_px, cell_px, &faces) catch |err| return mapTextSceneRenderError(err);
        return renderReportFromTextScene(scene_report);
    }

    pub fn renderFrameStateTextScene(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
        faces: []render_core.Text.FontSession.FontFaceRecord,
    ) !TextSceneRenderReport {
        var prepared = try self.prepareFrameStateTextScene(allocator, state, surface_px, cell_px, faces);
        defer prepared.deinit();
        return self.submitPreparedTextScene(&prepared);
    }

    pub fn prepareFrameStateTextScene(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
        faces: []render_core.Text.FontSession.FontFaceRecord,
    ) !PreparedTextScene {
        try self.resize(surface_px, cell_px);
        const rc = render_core.init(self.config, self.capabilities());
        const input_start_ns = monotonicNs();
        var input = try rc.vtStateToTextSceneInput(allocator, state);
        const input_us = elapsedUs(input_start_ns);
        defer input.deinit();
        if (!self.target_content_valid) {
            // Scroll/partial damage needs a retained target base. If the target content is
            // invalid, the backend must escalate this frame to full redraw.
            if (self.text_engine) |*engine| engine.clearAtlas();
            self.clearAtlasCache();
            input.options.scene.damage.full = true;
            input.options.scene.damage.scroll_up_rows = 0;
        }
        var analysis = try self.analyzeTextCellsOptions(allocator, input.cells, input.grid, faces, input.options);
        errdefer analysis.deinit();
        const atlas_start_ns = monotonicNs();
        try self.ensureAtlasStorageForRasterOutputs(analysis.raster_plan.outputs);
        analysis.timings.atlas_us += elapsedUs(atlas_start_ns);
        analysis.timings.input_us = input_us;
        return analysis;
    }

    pub fn submitPreparedTextScene(self: *Backend, prepared: *PreparedTextScene) !TextSceneRenderReport {
        return self.renderTextScene(prepared.scene.scene, prepared.raster_plan.outputs);
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

    fn deriveCellMetrics(self: *Backend) render_core.CellMetrics {
        if (self.ensurePrimaryFont()) {
            return cellMetricsFromFace(self.ft_face.?, self.config.font_size_px);
        }
        if (self.ft_lib) |lib| {
            var i: usize = 0;
            while (i < self.fallback_font_paths_len) : (i += 1) {
                const font_path = self.fallback_font_paths[i] orelse continue;
                var face: FtFace = undefined;
                if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
                defer _ = c.FT_Done_Face(face);
                if (!setFacePixelHeight(self, face)) continue;
                return cellMetricsFromFace(face, self.config.font_size_px);
            }
        }
        return render_core.Text.Metrics.defaultCellMetrics(self.config.font_size_px);
    }

    fn configuredCellMetrics(self: *Backend) render_core.CellMetrics {
        const cell_w = @max(self.config.cell_px.width, 1);
        const cell_h = @max(self.config.cell_px.height, 1);
        const baseline = if (self.ensurePrimaryFont())
            computeBaselineFromFace(self.ft_face.?, cell_h)
        else
            @as(i32, @intCast(@max(cell_h - @divFloor(cell_h, 5), 1)));
        return .{
            .cell_w_px = cell_w,
            .cell_h_px = cell_h,
            .baseline_px = @intCast(std.math.clamp(baseline, 1, @as(i32, @intCast(cell_h)))),
            .box_thickness_px = render_core.Text.Metrics.defaultBoxThickness(cell_h),
        };
    }

    fn deriveCellSize(self: *Backend) render_core.CellSize {
        const cell = self.deriveCellMetrics();
        return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
    }

    fn ensureFont(self: *Backend) bool {
        if (self.ensurePrimaryFont()) {
            self.resolve_stage = .loaded_exact_match;
            return true;
        }
        if (!self.ensureFreeTypeLibrary()) return false;

        var i: usize = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            if (self.fallback_font_paths[i] == null) continue;
            if (self.ensureFallbackFace(i) != null) {
                self.resolve_stage = .discovery_fallback;
                return true;
            }
        }

        self.resolve_stage = .missing_glyph;
        self.resolve_counters.missing_glyphs += 1;
        return false;
    }

    fn resetLoadedFace(self: *Backend) void {
        self.resetFallbackFaces();
        self.face_text_cache.clear();
        self.shape_run_cache.clear();
        self.glyph_cell_cache.clear();
        if (self.ft_face != null) {
            if (self.hb_font != null and builtin.target.abi != .android) {
                c.hb_font_destroy(self.hb_font.?);
                self.hb_font = null;
            }
            _ = c.FT_Done_Face(self.ft_face.?);
            self.ft_face = null;
        }
        if (self.ft_lib != null) {
            _ = c.FT_Done_FreeType(self.ft_lib.?);
            self.ft_lib = null;
        }
    }

    fn resetFallbackFaces(self: *Backend) void {
        var i: usize = 0;
        while (i < MaxFallbackFonts) : (i += 1) {
            if (self.fallback_hb_fonts[i] != null and builtin.target.abi != .android) {
                c.hb_font_destroy(self.fallback_hb_fonts[i].?);
                self.fallback_hb_fonts[i] = null;
            }
            if (self.fallback_faces[i] != null) {
                _ = c.FT_Done_Face(self.fallback_faces[i].?);
                self.fallback_faces[i] = null;
            }
        }
    }

    fn ensureFreeTypeLibrary(self: *Backend) bool {
        if (self.ft_lib != null) return true;
        var lib: FtLibrary = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return false;
        self.ft_lib = lib;
        return true;
    }

    fn ensurePrimaryFont(self: *Backend) bool {
        if (self.ft_face != null) return true;
        if (!self.ensureFreeTypeLibrary()) return false;
        if (self.config.font_path == null) return false;

        var face: FtFace = undefined;
        const lib = self.ft_lib.?;
        const font_path = self.config.font_path.?;
        if (c.FT_New_Face(lib, font_path, 0, &face) != 0) return false;
        if (!setFacePixelHeight(self, face)) {
            _ = c.FT_Done_Face(face);
            return false;
        }

        self.ft_face = face;
        if (builtin.target.abi != .android) {
            self.hb_font = @ptrCast(c.hb_ft_font_create_referenced(face));
        }
        return true;
    }

    fn ensureFallbackFace(self: *Backend, fallback_index: usize) ?FtFace {
        if (fallback_index >= self.fallback_font_paths_len) return null;
        if (self.fallback_faces[fallback_index]) |face| return face;
        if (!self.ensureFreeTypeLibrary()) return null;
        const font_path = self.fallback_font_paths[fallback_index] orelse return null;
        const lib = self.ft_lib orelse return null;
        var face: FtFace = undefined;
        if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return null;
        if (!setFacePixelHeight(self, face)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        self.fallback_faces[fallback_index] = face;
        if (builtin.target.abi != .android) {
            self.fallback_hb_fonts[fallback_index] = @ptrCast(c.hb_ft_font_create_referenced(face));
        }
        return face;
    }

    fn clearAtlasCache(self: *Backend) void {
        atlas_mod.clearAtlasCache(self);
        if (self.text_engine) |*engine| engine.clearAtlas();
    }

    fn ensureTextEngine(self: *Backend, allocator: std.mem.Allocator) !*render_core.Text.Engine.Engine {
        if (self.text_engine == null) {
            var ft_hb = self.textProvider();
            self.text_engine = try render_core.Text.Engine.Engine.initWithProvider(allocator, self.capabilities().max_atlas_slots, ft_hb.textProvider());
        }
        return &self.text_engine.?;
    }

    fn rasterizeFromFont(self: *Backend, dst: []u8, codepoint: u21, gw: u16, gh: u16) ?ResolvedGlyphKey {
        if (!self.ensureFont()) return null;
        if (self.ft_face) |face| {
            if (self.rasterizeGlyphFromFace(dst, self.hb_font, face, codepoint, primary_face_id, gw, gh)) |key| {
                self.resolve_stage = .loaded_exact_match;
                return key;
            }
        }

        const lib = self.ft_lib orelse return null;
        var i: usize = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            const font_path = self.fallback_font_paths[i] orelse continue;
            var face: FtFace = undefined;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
            defer _ = c.FT_Done_Face(face);

            var fallback_hb: ?HbFont = null;
            defer if (fallback_hb != null and builtin.target.abi != .android) {
                c.hb_font_destroy(fallback_hb.?);
            };
            if (!setFacePixelHeight(self, face)) continue;
            if (builtin.target.abi != .android) {
                fallback_hb = @ptrCast(c.hb_ft_font_create_referenced(face));
            }

            const face_id = fallbackFaceId(i);
            if (self.rasterizeGlyphFromFace(dst, fallback_hb, face, codepoint, face_id, gw, gh)) |key| {
                self.resolve_stage = .discovery_fallback;
                self.resolve_counters.fallback_hits += 1;
                return key;
            }
        }

        self.resolve_stage = .missing_glyph;
        self.resolve_counters.fallback_misses += 1;
        self.resolve_counters.missing_glyphs += 1;
        return null;
    }

    fn resolveGlyphKey(self: *Backend, codepoint: u21) ?ResolvedGlyphKey {
        _ = self.ensureFont();
        if (self.ft_face) |face| {
            if (setFacePixelHeight(self, face)) {
                const glyph_id = shapeGlyphId(self.hb_font, face, codepoint);
                if (glyph_id != 0) return .{ .codepoint = codepoint, .face_id = primary_face_id, .glyph_id = glyph_id };
            }
        }
        return null;
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
        const placement = render_core.Text.Metrics.bitmapPlacement(
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
                const dx: usize = @intCast(dx_i);
                const dy: usize = @intCast(dy_i);
                if (dx >= gw or dy >= gh) continue;
                const src_y = if (pitch_is_negative) (bh - 1 - yy) else yy;
                const src_idx = src_y * pitch_abs + xx;
                const dst_idx = dy * @as(usize, self.atlas_cell_w) + dx;
                dst[dst_idx] = bitmap.buffer[src_idx];
                wrote_any = true;
            }
        }
        self.resolve_counters.shaped_clusters += 1;
        if (!wrote_any) return null;
        return .{ .codepoint = codepoint, .face_id = face_id, .glyph_id = glyph_id };
    }
};

fn providerHasCodepoint(ctx: *anyopaque, face_id: render_core.FontFaceId, codepoint: u32) bool {
    return provider_mod.providerHasCodepoint(Backend, ctx, face_id, codepoint);
}

fn providerHasCellText(ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
    return provider_mod.providerHasCellText(Backend, ctx, face_id, text);
}

fn providerShapeRun(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    text_cache_view: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
) anyerror!render_core.Text.ShapeRun.OwnedShapedRun {
    return provider_mod.providerShapeRun(Backend, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
}

fn providerRasterizeSprite(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render_core.SpriteRasterRequest,
) anyerror!render_core.Text.Rasterizer.RasterSpriteOutput {
    return provider_mod.providerRasterizeSprite(Backend, ctx, allocator, req);
}

fn providerLookupGlyph(ctx: *anyopaque, face_id: render_core.FontFaceId, codepoint: u32, cell_metrics: render_core.CellMetrics) render_core.Text.Provider.LookupGlyphResult {
    return provider_mod.providerLookupGlyph(Backend, ctx, face_id, codepoint, cell_metrics);
}

fn providerRasterizeGlyph(ctx: *anyopaque, allocator: std.mem.Allocator, req: render_core.RasterizeRequest) anyerror!render_core.RasterizeOutput {
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
        .advance_px = provider_mod.providerGlyphAdvance(self, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
        .alpha_mask = alpha,
    };
}

fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    if (hb_font) |font| {
        const buffer = c.hb_buffer_create() orelse return c.FT_Get_Char_Index(face, codepoint);
        defer c.hb_buffer_destroy(buffer);
        var cp: u32 = codepoint;
        c.hb_buffer_add_utf32(buffer, &cp, 1, 0, 1);
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(font, buffer, null, 0);
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
        if (infos != null and count > 0) {
            const gid = infos[0].codepoint;
            if (gid != 0) return gid;
        }
    }
    return c.FT_Get_Char_Index(face, codepoint);
}

fn setFacePixelHeight(self: *const Backend, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
}

fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return render_core.Text.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
}

fn cellSizeFromFace(face: FtFace, font_size_px: u16) render_core.CellSize {
    const cell = cellMetricsFromFace(face, font_size_px);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

fn cellMetricsFromFace(face: FtFace, font_size_px: u16) render_core.CellMetrics {
    return render_core.Text.Metrics.cellMetricsFromFaceMetrics(faceMetricsInput(face, font_size_px));
}

fn faceMetricsInput(face: FtFace, font_size_px: u16) render_core.Text.Metrics.FaceMetrics26Dot6 {
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

fn drawTextScene(backend: *const Backend, surface: render_core.PixelSize, scene: render_core.TextScene) void {
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

fn applyScrollReusePx(backend: *const Backend, surface_px: render_core.PixelSize, scroll_px_u16: u16) void {
    const texture = backend.target_texture orelse return;
    const scroll_px = @as(u32, scroll_px_u16);
    const width = @as(u32, surface_px.width);
    const height = @as(u32, surface_px.height);
    if (scroll_px == 0 or scroll_px >= height or width == 0) return;
    const preserved_h = height - scroll_px;
    const bytes = @as(usize, width) * @as(usize, preserved_h) * 4;
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

fn drawSceneSprite(backend: *const Backend, surface: render_core.PixelSize, draw: render_core.TextSpriteDraw) void {
    if (backend.atlas_pixels.len == 0) return;
    const slot = @as(usize, draw.sprite.slot);
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
            const src_x = @as(usize, draw_x) + xx;
            const src_y = @as(usize, draw_y) + yy;
            const idx = src_y * @as(usize, backend.atlas_cell_w) + src_x;
            const alpha = src[idx];
            if (alpha == 0) continue;
            var color = draw.color;
            color.a = @intCast((@as(u16, color.a) * @as(u16, alpha)) / 255);
            drawRect(surface, draw.x_px + @as(i32, @intCast(src_x)), draw.y_px + @as(i32, @intCast(src_y)), 1, 1, color);
        }
    }
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render_core.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn drawRect(surface: render_core.PixelSize, x: i32, y: i32, width: u16, height: u16, color: render_core.Rgba8) void {
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
