//! Responsibility: implement the OpenGL ES backend owner surface.
//! Ownership: unified renderer GLES backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../render_core.zig").RenderCore;
const clip_rect = @import("../shared/clip_rect.zig");
const text_cache = @import("../shared/text_cache.zig");
const c_api = @import("internal/c_api.zig");
const c = c_api.c;
const FtLibrary = c_api.FtLibrary;
const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;

const primary_face_id: u32 = 1;

const ResolvedGlyphKey = struct {
    codepoint: u21,
    face_id: u32,
    glyph_id: u32,
};

fn fallbackFaceId(index: usize) u32 {
    return @intCast(index + 2);
}

fn missingGlyphKey(codepoint: u21) ResolvedGlyphKey {
    return .{ .codepoint = codepoint, .face_id = 0, .glyph_id = codepoint };
}

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
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
    clear_draws: usize,
    background_draws: usize,
    sprite_draws: usize,
    decoration_draws: usize,
    cursor_draws: usize,
};

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

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render_core.BackendConfig) Backend {
        return .{
            .config = config,
            .face_text_cache = text_cache.FaceTextCache.init(std.heap.c_allocator),
            .shape_run_cache = text_cache.ShapeRunCache.init(std.heap.c_allocator),
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
        if (self.atlas_slot_has_alpha.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_has_alpha);
            self.atlas_slot_has_alpha = &.{};
        }
        self.resetLoadedFace();
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
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
        if (texture_changed) self.surface_epoch +%= 1;
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

    pub fn textProvider(self: *Backend) render_core.Text.FtHbProvider.Adapter {
        return .{
            .ctx = self,
            .has_codepoint = providerHasCodepoint,
            .shaper = .{ .ctx = self, .shape_run = providerShapeRun },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSprite },
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
        try self.ensureAtlasStorageForRasterOutputs(outputs);
        var committed: usize = 0;
        for (outputs) |output| {
            const slot = findSceneSpriteSlot(scene, output.key) orelse continue;
            if (self.textSceneSlotCached(slot, output)) continue;
            self.copyRasterOutputToAtlas(slot, output);
            committed += 1;
        }
        return committed;
    }

    pub fn renderTextScene(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput,
    ) !TextSceneRenderReport {
        if (self.closed) return error.BackendClosed;
        const committed_uploads = try self.uploadTextSceneRaster(scene, outputs);
        if (hasCurrentContext()) {
            if (self.target_texture == null and self.config.target_texture != 0) {
                self.target_texture = self.config.target_texture;
                self.surface_epoch +%= 1;
            }
            try self.ensureOwnedTargetTexture();
            if (self.target_texture == null) return error.TargetTextureUnset;
            try self.beginTargetPass();
            defer self.endTargetPass();
            drawTextScene(self, self.config.surface_px, scene);
        } else if (!builtin.is_test) {
            return error.NoContext;
        }
        self.pass_count += 1;
        return .{
            .pass_index = self.pass_count,
            .raster_uploads_committed = committed_uploads,
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
        try self.resize(surface_px, cell_px);
        const rc = render_core.init(self.config, self.capabilities());
        var input = try rc.vtStateToTextSceneInput(allocator, state);
        defer input.deinit();
        var analysis = try self.analyzeTextCellsOptions(allocator, input.cells, input.grid, faces, input.options);
        defer analysis.deinit();
        return self.renderTextScene(analysis.scene.scene, analysis.raster_plan.outputs);
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
        };
    }

    fn deriveCellSize(self: *Backend) render_core.CellSize {
        const cell = self.deriveCellMetrics();
        return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
    }

    fn ensureAtlasStorage(self: *Backend) BackendError!void {
        const need_w = @max(self.config.cell_px.width, 1);
        const need_h = @max(self.config.cell_px.height, 1);
        return self.ensureAtlasStorageSized(need_w, need_h);
    }

    fn ensureAtlasStorageForRasterOutputs(self: *Backend, outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput) BackendError!void {
        var need_w = @max(self.config.cell_px.width, 1);
        var need_h = @max(self.config.cell_px.height, 1);
        for (outputs) |output| {
            need_w = @max(need_w, @max(output.width_px, 1));
            need_h = @max(need_h, @max(output.height_px, 1));
        }
        return self.ensureAtlasStorageSized(need_w, need_h);
    }

    fn ensureAtlasStorageSized(self: *Backend, need_w: u16, need_h: u16) BackendError!void {
        const need_stride: usize = @as(usize, need_w) * @as(usize, need_h);
        if (self.atlas_pixels.len != 0 and self.atlas_cell_w == need_w and self.atlas_cell_h == need_h) return;

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
        if (self.atlas_slot_has_alpha.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_has_alpha);
            self.atlas_slot_has_alpha = &.{};
        }
        const max_slots = self.capabilities().max_atlas_slots;
        self.atlas_pixels = try std.heap.c_allocator.alloc(u8, need_stride * @as(usize, max_slots));
        @memset(self.atlas_pixels, 0);
        self.atlas_slot_codepoint = try std.heap.c_allocator.alloc(u21, max_slots);
        @memset(self.atlas_slot_codepoint, 0);
        self.atlas_slot_face_id = try std.heap.c_allocator.alloc(u32, max_slots);
        @memset(self.atlas_slot_face_id, 0);
        self.atlas_slot_glyph_id = try std.heap.c_allocator.alloc(u32, max_slots);
        @memset(self.atlas_slot_glyph_id, 0);
        self.atlas_slot_sprite_key = try std.heap.c_allocator.alloc(u64, max_slots);
        @memset(self.atlas_slot_sprite_key, 0);
        self.atlas_slot_width = try std.heap.c_allocator.alloc(u16, max_slots);
        @memset(self.atlas_slot_width, 0);
        self.atlas_slot_height = try std.heap.c_allocator.alloc(u16, max_slots);
        @memset(self.atlas_slot_height, 0);
        self.atlas_slot_has_alpha = try std.heap.c_allocator.alloc(bool, max_slots);
        @memset(self.atlas_slot_has_alpha, false);
        self.atlas_cell_w = need_w;
        self.atlas_cell_h = need_h;
        self.atlas_slot_stride = need_stride;
        self.atlas_next_slot = 0;
    }

    fn slotCached(self: *const Backend, slot: u32, key: ResolvedGlyphKey, width: u16, height: u16) bool {
        const idx = @as(usize, slot);
        if (idx >= self.atlas_slot_codepoint.len) return false;
        if (idx >= self.atlas_slot_face_id.len or idx >= self.atlas_slot_glyph_id.len) return false;
        return self.atlas_slot_codepoint[idx] == key.codepoint and
            self.atlas_slot_face_id[idx] == key.face_id and
            self.atlas_slot_glyph_id[idx] == key.glyph_id and
            self.atlas_slot_width[idx] == width and
            self.atlas_slot_height[idx] == height;
    }

    fn textSceneSlotCached(self: *const Backend, slot: u32, output: render_core.Text.Rasterizer.RasterSpriteOutput) bool {
        const idx = @as(usize, slot);
        if (idx >= self.atlas_slot_sprite_key.len) return false;
        if (idx >= self.atlas_slot_width.len or idx >= self.atlas_slot_height.len) return false;
        return self.atlas_slot_sprite_key[idx] == output.key.value and
            self.atlas_slot_width[idx] == output.width_px and
            self.atlas_slot_height[idx] == output.height_px;
    }

    fn findCachedSlot(self: *const Backend, key: ResolvedGlyphKey, width: u16, height: u16) ?u32 {
        var idx: usize = 0;
        while (idx < self.atlas_slot_codepoint.len) : (idx += 1) {
            if (self.atlas_slot_width[idx] == 0 or self.atlas_slot_height[idx] == 0) continue;
            if (!self.slotCached(@intCast(idx), key, width, height)) continue;
            return @intCast(idx);
        }
        return null;
    }

    fn findCachedSlotForDraw(self: *const Backend, codepoint: u21, width: u16, height: u16) ?u32 {
        var idx: usize = 0;
        while (idx < self.atlas_slot_codepoint.len) : (idx += 1) {
            if (self.atlas_slot_width[idx] == 0 or self.atlas_slot_height[idx] == 0) continue;
            if (self.atlas_slot_codepoint[idx] != codepoint) continue;
            if (self.atlas_slot_width[idx] != width or self.atlas_slot_height[idx] != height) continue;
            return @intCast(idx);
        }
        return null;
    }

    fn allocateSlot(self: *Backend) ?u32 {
        var idx: usize = 0;
        while (idx < self.atlas_slot_width.len) : (idx += 1) {
            if (self.atlas_slot_width[idx] == 0 and self.atlas_slot_height[idx] == 0) {
                return @intCast(idx);
            }
        }
        if (self.atlas_slot_width.len == 0) return null;
        const slot = self.atlas_next_slot;
        self.atlas_next_slot = (self.atlas_next_slot + 1) % self.capabilities().max_atlas_slots;
        return slot;
    }

    fn markSlotCached(self: *Backend, slot: u32, key: ResolvedGlyphKey, width: u16, height: u16) void {
        const idx = @as(usize, slot);
        if (idx >= self.atlas_slot_codepoint.len) return;
        self.atlas_slot_codepoint[idx] = key.codepoint;
        if (idx < self.atlas_slot_face_id.len) self.atlas_slot_face_id[idx] = key.face_id;
        if (idx < self.atlas_slot_glyph_id.len) self.atlas_slot_glyph_id[idx] = key.glyph_id;
        self.atlas_slot_width[idx] = width;
        self.atlas_slot_height[idx] = height;
    }

    fn copyRasterOutputToAtlas(self: *Backend, slot: u32, output: render_core.Text.Rasterizer.RasterSpriteOutput) void {
        if (self.atlas_pixels.len == 0) return;
        const slot_idx = @as(usize, slot);
        const slot_off = slot_idx * self.atlas_slot_stride;
        if (slot_off + self.atlas_slot_stride > self.atlas_pixels.len) return;
        const dst = self.atlas_pixels[slot_off .. slot_off + self.atlas_slot_stride];
        @memset(dst, 0);
        const copy_w = @min(output.width_px, self.atlas_cell_w);
        const copy_h = @min(output.height_px, self.atlas_cell_h);
        for (0..copy_h) |yy| {
            const src_off = yy * @as(usize, output.width_px);
            const dst_off = yy * @as(usize, self.atlas_cell_w);
            @memcpy(dst[dst_off .. dst_off + copy_w], output.pixels[src_off .. src_off + copy_w]);
        }
        if (slot_idx < self.atlas_slot_codepoint.len) self.atlas_slot_codepoint[slot_idx] = 0;
        if (slot_idx < self.atlas_slot_face_id.len) self.atlas_slot_face_id[slot_idx] = 0;
        if (slot_idx < self.atlas_slot_glyph_id.len) self.atlas_slot_glyph_id[slot_idx] = @intCast(output.key.value & 0xffff_ffff);
        if (slot_idx < self.atlas_slot_sprite_key.len) self.atlas_slot_sprite_key[slot_idx] = output.key.value;
        if (slot_idx < self.atlas_slot_width.len) self.atlas_slot_width[slot_idx] = output.width_px;
        if (slot_idx < self.atlas_slot_height.len) self.atlas_slot_height[slot_idx] = output.height_px;
        self.markSlotAlpha(slot, dst, copy_w, copy_h);
    }

    fn markSlotAlpha(self: *Backend, slot: u32, pixels: []const u8, gw: u16, gh: u16) void {
        const slot_idx = @as(usize, slot);
        if (slot_idx >= self.atlas_slot_has_alpha.len) return;
        for (0..gh) |yy| {
            for (0..gw) |xx| {
                if (pixels[yy * @as(usize, self.atlas_cell_w) + xx] != 0) {
                    self.atlas_slot_has_alpha[slot_idx] = true;
                    return;
                }
            }
        }
        self.atlas_slot_has_alpha[slot_idx] = false;
    }

    fn rasterizeSlot(self: *Backend, slot: u32, codepoint: u21, width: u16, height: u16) void {
        if (self.atlas_pixels.len == 0) return;
        const slot_index = @as(usize, slot) * self.atlas_slot_stride;
        const dst = self.atlas_pixels[slot_index .. slot_index + self.atlas_slot_stride];
        @memset(dst, 0);
        const gw = @min(width, self.atlas_cell_w);
        const gh = @min(height, self.atlas_cell_h);
        if (self.rasterizeFromFont(dst, codepoint, gw, gh)) {
            self.resolve_stage = .loaded_exact_match;
            return;
        }
        self.resolve_stage = .missing_glyph;
        self.resolve_counters.fallback_misses += 1;
        rasterizeFallbackGlyph(dst, self.atlas_cell_w, self.atlas_cell_h, codepoint, gw, gh);
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
        if (self.atlas_pixels.len > 0) @memset(self.atlas_pixels, 0);
        if (self.atlas_slot_codepoint.len > 0) @memset(self.atlas_slot_codepoint, 0);
        if (self.atlas_slot_face_id.len > 0) @memset(self.atlas_slot_face_id, 0);
        if (self.atlas_slot_glyph_id.len > 0) @memset(self.atlas_slot_glyph_id, 0);
        if (self.atlas_slot_sprite_key.len > 0) @memset(self.atlas_slot_sprite_key, 0);
        if (self.atlas_slot_width.len > 0) @memset(self.atlas_slot_width, 0);
        if (self.atlas_slot_height.len > 0) @memset(self.atlas_slot_height, 0);
        if (self.atlas_slot_has_alpha.len > 0) @memset(self.atlas_slot_has_alpha, false);
        self.atlas_next_slot = 0;
        if (self.text_engine) |*engine| engine.clearAtlas();
    }

    fn ensureTextEngine(self: *Backend, allocator: std.mem.Allocator) !*render_core.Text.Engine.Engine {
        if (self.text_engine == null) {
            var adapter = self.textProvider();
            self.text_engine = try render_core.Text.Engine.Engine.initWithProvider(allocator, self.capabilities().max_atlas_slots, adapter.textProvider());
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
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    if (useDeterministicTestTextFallback(backend)) return codepoint != 0;
    if (!backend.ensureFont()) return false;
    if (face_id.value == primary_face_id) {
        const face = backend.ft_face orelse return false;
        return c.FT_Get_Char_Index(face, codepoint) != 0;
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    const face = backend.ensureFallbackFace(fallback_index) orelse return false;
    return c.FT_Get_Char_Index(face, codepoint) != 0;
}

fn providerHasCellText(ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const key = text_cache.FaceTextKey{ .face_id = face_id.value, .text_hash = text_cache.hashCellText(text) };
    const entry = backend.face_text_cache.map.getOrPut(key) catch return uncachedProviderHasCellText(ctx, face_id, text);
    if (entry.found_existing) {
        backend.resolve_counters.face_cache_hits += 1;
        return entry.value_ptr.*;
    }

    backend.resolve_counters.face_checks += 1;
    const result = uncachedProviderHasCellText(ctx, face_id, text);
    entry.value_ptr.* = result;
    return result;
}

fn uncachedProviderHasCellText(ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp == 0xfe0e or cp == 0xfe0f) continue;
        if (!providerHasCodepoint(ctx, face_id, cp)) return false;
    }
    return true;
}

fn providerShapeRun(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    text_cache_view: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
) anyerror!render_core.Text.ShapeRun.OwnedShapedRun {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const start = @as(usize, @intCast(run.run.cluster_start));
    const count = @as(usize, @intCast(run.run.cluster_count));
    const end = @min(start + count, clusters.len);
    backend.resolve_counters.shape_requests += 1;
    const shape_key = text_cache.ShapeRunKey{
        .face_id = run.run.font.face_id.value,
        .run_hash = text_cache.hashRunText(text_cache_view, clusters[start..end]),
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    if (try backend.shape_run_cache.getOwnedRun(allocator, shape_key, run)) |cached| {
        backend.resolve_counters.shape_cache_hits += 1;
        return cached;
    }

    const glyphs = try allocator.alloc(render_core.GlyphInstance, end - start);
    errdefer allocator.free(glyphs);
    for (clusters[start..end], 0..) |cluster, idx| {
        const glyph_id = providerGlyphId(backend, run.run.font.face_id, cluster.first_cp);
        const advance_px = providerGlyphAdvance(backend, run.run.font.face_id, glyph_id, cell_metrics);
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = glyph_id,
            .cluster_index = @intCast(start + idx),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = advance_px,
        };
    }
    var shaped = render_core.Text.ShapeRun.OwnedShapedRun{ .allocator = allocator, .run = run, .glyphs = glyphs };
    errdefer shaped.deinit();
    try backend.shape_run_cache.putRun(shape_key, shaped);
    return shaped;
}

fn providerGlyphId(self: *Backend, face_id: render_core.FontFaceId, codepoint: u32) u32 {
    if (useDeterministicTestTextFallback(self)) return codepoint;
    if (!self.ensureFont()) return 0;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return 0;
        return shapeGlyphId(self.hb_font, face, @intCast(codepoint));
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return 0;
    const face = self.ensureFallbackFace(fallback_index) orelse return 0;
    return shapeGlyphId(self.fallback_hb_fonts[fallback_index], face, @intCast(codepoint));
}

fn providerGlyphAdvance(self: *Backend, face_id: render_core.FontFaceId, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    const fallback: f32 = @floatFromInt(cell_metrics.cell_w_px);
    if (glyph_id == 0) return fallback;
    if (useDeterministicTestTextFallback(self)) return fallback;
    const face = if (face_id.value == primary_face_id)
        self.ft_face
    else
        self.ensureFallbackFace(if (face_id.value >= 2) face_id.value - 2 else return fallback);
    if (face == null) return fallback;
    if (c.FT_Load_Glyph(face.?, glyph_id, c.FT_LOAD_DEFAULT) != 0) return fallback;
    if (face.?.*.glyph == null) return fallback;
    return @as(f32, @floatFromInt(@as(i32, @intCast(face.?.*.glyph.*.advance.x)))) / 64.0;
}

fn providerRasterizeSprite(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render_core.SpriteRasterRequest,
) anyerror!render_core.Text.Rasterizer.RasterSpriteOutput {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const width = @max(req.width_px, 1);
    const height = @max(req.height_px, 1);
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    if (req.group.kind == .box_fallback) {
        rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
        return .{
            .allocator = allocator,
            .key = req.key,
            .width_px = width,
            .height_px = height,
            .color_mode = req.color_mode,
            .pixels = pixels,
        };
    }

    if (useDeterministicTestTextFallback(backend)) {
        rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
        return .{
            .allocator = allocator,
            .key = req.key,
            .width_px = width,
            .height_px = height,
            .color_mode = req.color_mode,
            .pixels = pixels,
        };
    }

    var pen_x: f32 = 0;
    for (req.group.glyphs, 0..) |glyph, glyph_idx| {
        const x_px = @as(i32, @intFromFloat(std.math.floor(pen_x + glyph.x_offset_px)));
        const y_px = @as(i32, @intFromFloat(std.math.floor(glyph.y_offset_px)));
        _ = rasterizeProviderGlyph(backend, pixels, width, height, req.baseline_px, glyph.face_id, glyph.glyph_id, x_px, y_px, @intCast(glyph_idx));
        pen_x += glyph.x_advance_px;
    }

    return .{
        .allocator = allocator,
        .key = req.key,
        .width_px = width,
        .height_px = height,
        .color_mode = req.color_mode,
        .pixels = pixels,
    };
}

fn findSceneSpriteSlot(scene: render_core.TextScene, key: render_core.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn rasterizeProviderGlyph(self: *Backend, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render_core.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (useDeterministicTestTextFallback(self)) {
        rasterizeFallbackGlyph(dst, width, height, @intCast(glyph_id), width, height);
        return true;
    }
    if (!self.ensureFont()) return false;
    const face = if (face_id.value == primary_face_id)
        self.ft_face
    else
        self.ensureFallbackFace(if (face_id.value >= 2) face_id.value - 2 else return false);
    if (face == null) return false;
    return rasterizeProviderGlyphFromFace(dst, width, height, baseline_px, face.?, glyph_id, x_origin_px, y_origin_px, glyph_index);
}

fn useDeterministicTestTextFallback(self: *const Backend) bool {
    return builtin.is_test and self.config.font_path == null;
}

fn rasterizeProviderGlyphFromFace(dst: []u8, width: u16, height: u16, baseline_px: i16, face: FtFace, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (glyph_id == 0) return false;
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_RENDER) != 0) return false;
    const glyph = face.*.glyph;
    if (glyph == null) return false;
    const bitmap = glyph.*.bitmap;
    if (bitmap.buffer == null or bitmap.width <= 0 or bitmap.rows <= 0) return false;
    const bw: usize = @intCast(bitmap.width);
    const bh: usize = @intCast(bitmap.rows);
    const pitch_abs: usize = @intCast(@abs(bitmap.pitch));
    const pitch_is_negative = bitmap.pitch < 0;
    const baseline: i32 = if (baseline_px > 0) baseline_px else computeBaselineFromFace(face, height);
    const origin = cellBitmapOrigin(width, baseline, glyph.*.bitmap_left, glyph.*.bitmap_top, @intCast(bitmap.width), x_origin_px, y_origin_px, glyph_index);

    for (0..bh) |yy| {
        for (0..bw) |xx| {
            const dx_i = origin.x_px + @as(i32, @intCast(xx));
            const dy_i = origin.y_px + @as(i32, @intCast(yy));
            if (dx_i < 0 or dy_i < 0) continue;
            const dx: usize = @intCast(dx_i);
            const dy: usize = @intCast(dy_i);
            if (dx >= width or dy >= height) continue;
            const src_y = if (pitch_is_negative) (bh - 1 - yy) else yy;
            dst[dy * @as(usize, width) + dx] = bitmap.buffer[src_y * pitch_abs + xx];
        }
    }
    return true;
}

fn cellBitmapOrigin(cell_width: u16, baseline: i32, bitmap_left: i32, bitmap_top: i32, bitmap_width: u16, x_offset: i32, y_offset: i32, glyph_index: u32) struct { x_px: i32, y_px: i32 } {
    var x_px = x_offset + bitmap_left;
    if (glyph_index < 4 and x_px > 0 and x_px + @as(i32, @intCast(bitmap_width)) > @as(i32, @intCast(cell_width))) {
        const extra = x_px + @as(i32, @intCast(bitmap_width)) - @as(i32, @intCast(cell_width));
        x_px = if (extra > x_px) 0 else x_px - extra;
    }
    const yoff = y_offset + bitmap_top;
    const y_px = if (yoff > 0 and yoff > baseline) 0 else baseline - yoff;
    return .{ .x_px = x_px, .y_px = y_px };
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
    if (backend.atlas_pixels.len == 0) {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    }
    const slot = @as(usize, draw.sprite.slot);
    if (slot >= backend.atlas_slot_width.len or slot >= backend.atlas_slot_height.len) return;
    const slot_index = slot * backend.atlas_slot_stride;
    if (slot_index + backend.atlas_slot_stride > backend.atlas_pixels.len) return;
    const src = backend.atlas_pixels[slot_index .. slot_index + backend.atlas_slot_stride];
    const gw = @min(draw.width_px, backend.atlas_cell_w);
    const gh = @min(draw.height_px, backend.atlas_cell_h);
    var drew_any = false;
    for (0..gh) |yy| {
        for (0..gw) |xx| {
            const idx = yy * @as(usize, backend.atlas_cell_w) + xx;
            const alpha = src[idx];
            if (alpha == 0) continue;
            drew_any = true;
            var color = draw.color;
            color.a = @intCast((@as(u16, color.a) * @as(u16, alpha)) / 255);
            drawRect(surface, draw.x_px + @as(i32, @intCast(xx)), draw.y_px + @as(i32, @intCast(yy)), 1, 1, color);
        }
    }
    if (!drew_any) {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
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
