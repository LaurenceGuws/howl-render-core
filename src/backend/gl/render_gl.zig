//! Responsibility: implement the OpenGL backend owner surface.
//! Ownership: unified renderer GL backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../render_core.zig").RenderCore;
const clip_rect = @import("../shared/clip_rect.zig");
const shared_text_cache = @import("../shared/text_cache.zig");
const atlas_mod = @import("internal/atlas.zig");
const c_api = @import("internal/c_api.zig");
const provider_mod = @import("internal/provider.zig");
const c = c_api.c;
const FtLibrary = c_api.FtLibrary;
const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;

const primary_face_id: u32 = provider_mod.primary_face_id;
const ResolvedGlyphKey = provider_mod.ResolvedGlyphKey;

const TexturedGlyph = struct {
    clipped: clip_rect.ClipRect,
    color: render_core.Rgba8,
    tex_u0: f32,
    tex_v0: f32,
    tex_u1: f32,
    tex_v1: f32,
};

const QuadVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
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

/// Primary export surface for the GL renderer implementation.
pub const test_primary_face_id: u32 = provider_mod.primary_face_id;

pub fn testProviderGlyphId(self: *Backend, face_id: render_core.FontFaceId, codepoint: u32) u32 {
    return provider_mod.providerGlyphId(self, face_id, codepoint);
}

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

/// GL backend implementation consuming render-core apis.
pub const Backend = struct {
    const MaxFallbackFonts = 24;
    pub const AtlasTexCols: usize = 64;

    config: render_core.BackendConfig,
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
    atlas_slot_has_alpha: []bool = &.{},
    atlas_next_slot: u32 = 0,
    atlas_texture: u32 = 0,
    atlas_tex_width: u16 = 0,
    atlas_tex_height: u16 = 0,
    scroll_scratch_texture: u32 = 0,
    scroll_scratch_width: u16 = 0,
    scroll_scratch_height: u16 = 0,
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    fallback_faces: [MaxFallbackFonts]?FtFace = [_]?FtFace{null} ** MaxFallbackFonts,
    fallback_hb_fonts: [MaxFallbackFonts]?HbFont = [_]?HbFont{null} ** MaxFallbackFonts,
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_fbo: u32 = 0,
    surface_epoch: u64 = 1,
    resolve_counters: render_core.ResolveCounters = .{},
    resolve_stage: render_core.ResolveStage = .style_policy,
    fill_vertices: []QuadVertex = &.{},
    glyph_vertices: []QuadVertex = &.{},
    fallback_fill_vertices: []QuadVertex = &.{},
    text_engine: ?render_core.TextStack.Engine.Engine = null,
    face_text_cache: shared_text_cache.FaceTextCache,
    shape_run_cache: shared_text_cache.ShapeRunCache,
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: usize = 0,

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render_core.BackendConfig) Backend {
        return .{
            .config = config,
            .face_text_cache = shared_text_cache.FaceTextCache.init(std.heap.c_allocator),
            .shape_run_cache = shared_text_cache.ShapeRunCache.init(std.heap.c_allocator),
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
        if (self.fill_vertices.len > 0) {
            std.heap.c_allocator.free(self.fill_vertices);
            self.fill_vertices = &.{};
        }
        if (self.glyph_vertices.len > 0) {
            std.heap.c_allocator.free(self.glyph_vertices);
            self.glyph_vertices = &.{};
        }
        if (self.fallback_fill_vertices.len > 0) {
            std.heap.c_allocator.free(self.fallback_fill_vertices);
            self.fallback_fill_vertices = &.{};
        }
        self.resetLoadedFace();
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
        if (self.ft_lib != null) {
            _ = c.FT_Done_FreeType(self.ft_lib.?);
            self.ft_lib = null;
        }
        if (self.atlas_texture != 0 and hasCurrentContext()) {
            c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
            self.atlas_texture = 0;
        }
        if (self.scroll_scratch_texture != 0 and hasCurrentContext()) {
            c.glDeleteTextures(1, @ptrCast(&self.scroll_scratch_texture));
            self.scroll_scratch_texture = 0;
        }
        if (self.target_fbo != 0 and hasCurrentContext()) {
            c.glDeleteFramebuffersEXT(1, @ptrCast(&self.target_fbo));
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

    pub fn textProvider(self: *Backend) render_core.TextStack.FtHbProvider.Adapter {
        return .{
            .ctx = self,
            .has_codepoint = providerHasCodepoint,
            .shaper = .{ .ctx = self, .shape_run = providerShapeRun },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSprite },
        };
    }

    pub fn fontSession(self: *Backend, faces: []render_core.TextStack.FontSession.FontFaceRecord) render_core.TextStack.FontSession.FontSession {
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
        faces: []render_core.TextStack.FontSession.FontFaceRecord,
    ) !render_core.TextStack.Engine.OwnedTextAnalysis {
        return self.analyzeTextCellsOptions(allocator, cells, grid, faces, .{});
    }

    pub fn analyzeTextCellsOptions(
        self: *Backend,
        allocator: std.mem.Allocator,
        cells: []const render_core.CellInput,
        grid: render_core.GridMetrics,
        faces: []render_core.TextStack.FontSession.FontFaceRecord,
        options: render_core.TextStack.Engine.AnalysisOptions,
    ) !render_core.TextStack.Engine.OwnedTextAnalysis {
        const engine = try self.ensureTextEngine(allocator);
        return engine.analyzeCellsWithSessionOptions(cells, grid, self.fontSession(faces), options);
    }

    pub fn uploadTextAnalysisRaster(self: *Backend, analysis: render_core.TextStack.Engine.OwnedTextAnalysis) BackendError!usize {
        return self.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    }

    pub fn uploadTextSceneRaster(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.TextStack.Rasterizer.RasterSpriteOutput,
    ) BackendError!usize {
        return atlas_mod.uploadTextSceneRaster(self, scene, outputs);
    }

    pub fn renderTextScene(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.TextStack.Rasterizer.RasterSpriteOutput,
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
            .max_atlas_slots = 2048,
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
        var faces: [MaxFallbackFonts + 1]render_core.TextStack.FontSession.FontFaceRecord = undefined;
        const scene_report = self.renderFrameStateTextScene(allocator, state, surface_px, cell_px, &faces) catch |err| return mapTextSceneRenderError(err);
        return renderReportFromTextScene(scene_report);
    }

    pub fn renderFrameStateTextScene(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
        faces: []render_core.TextStack.FontSession.FontFaceRecord,
    ) !TextSceneRenderReport {
        try self.resize(surface_px, cell_px);
        const rc = render_core.init(self.config, self.capabilities());
        var input = try rc.vtStateToTextSceneInput(allocator, state);
        defer input.deinit();
        var analysis = try self.analyzeTextCellsOptions(allocator, input.cells, input.grid, faces, input.options);
        defer analysis.deinit();
        return self.renderTextScene(analysis.scene.scene, analysis.raster_plan.outputs);
    }

    fn copyRasterOutputToAtlas(self: *Backend, slot: u32, output: render_core.TextStack.Rasterizer.RasterSpriteOutput) void {
        atlas_mod.copyRasterOutputToAtlas(self, slot, output);
    }

    fn ensureAtlasStorage(self: *Backend) BackendError!void {
        const need_w = @max(self.config.cell_px.width, 1);
        const need_h = @max(self.config.cell_px.height, 1);
        return self.ensureAtlasStorageSized(need_w, need_h);
    }

    fn ensureAtlasStorageForRasterOutputs(self: *Backend, outputs: []const render_core.TextStack.Rasterizer.RasterSpriteOutput) BackendError!void {
        return atlas_mod.ensureAtlasStorageForRasterOutputs(self, outputs);
    }

    fn ensureAtlasStorageSized(self: *Backend, need_w: u16, need_h: u16) BackendError!void {
        return atlas_mod.ensureAtlasStorageSized(self, need_w, need_h);
    }

    fn ensureAtlasTexture(self: *Backend) BackendError!void {
        return atlas_mod.ensureAtlasTexture(self);
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

    fn textSceneSlotCached(self: *const Backend, slot: u32, output: render_core.TextStack.Rasterizer.RasterSpriteOutput) bool {
        return atlas_mod.textSceneSlotCached(self, slot, output);
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

    fn rasterizeSlot(self: *Backend, slot: u32, codepoint: u21, width: u16, height: u16) ResolvedGlyphKey {
        if (self.atlas_pixels.len == 0) return missingGlyphKey(codepoint);
        const slot_index = @as(usize, slot) * self.atlas_slot_stride;
        const dst = self.atlas_pixels[slot_index .. slot_index + self.atlas_slot_stride];
        @memset(dst, 0);
        const gw = @min(width, self.atlas_cell_w);
        const gh = @min(height, self.atlas_cell_h);
        if (self.rasterizeFromFont(dst, codepoint, gw, gh)) |key| {
            self.markSlotAlpha(slot, dst, gw, gh);
            return key;
        }
        self.resolve_stage = .missing_glyph;
        rasterizeFallbackGlyph(dst, self.atlas_cell_w, self.atlas_cell_h, codepoint, gw, gh);
        self.markSlotAlpha(slot, dst, gw, gh);
        return missingGlyphKey(codepoint);
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

    fn ensureFreeTypeLibrary(self: *Backend) bool {
        if (self.ft_lib != null) return true;
        var lib: FtLibrary = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return false;
        self.ft_lib = lib;
        return true;
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
    }

    fn resetFallbackFaces(self: *Backend) void {
        var i: usize = 0;
        while (i < MaxFallbackFonts) : (i += 1) {
            if (self.fallback_hb_fonts[i] != null and builtin.target.abi != .android) {
                c.hb_font_destroy(@ptrCast(self.fallback_hb_fonts[i].?));
                self.fallback_hb_fonts[i] = null;
            }
            if (self.fallback_faces[i] != null) {
                _ = c.FT_Done_Face(self.fallback_faces[i].?);
                self.fallback_faces[i] = null;
            }
        }
    }

    fn ensureFallbackFace(self: *Backend, fallback_index: usize) ?FtFace {
        return provider_mod.ensureFallbackFace(self, fallback_index);
    }

    fn clearAtlasCache(self: *Backend) void {
        atlas_mod.clearAtlasCache(self);
        if (self.text_engine) |*engine| engine.clearAtlas();
    }

    fn ensureTextEngine(self: *Backend, allocator: std.mem.Allocator) !*render_core.TextStack.Engine.Engine {
        if (self.text_engine == null) {
            var adapter = self.textProvider();
            self.text_engine = try render_core.TextStack.Engine.Engine.initWithProvider(allocator, self.capabilities().max_atlas_slots, adapter.textProvider());
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
                c.hb_font_destroy(@ptrCast(fallback_hb.?));
            };
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
        const placement = render_core.TextStack.Metrics.bitmapPlacement(
            .{ .cell_w_px = gw, .cell_h_px = gh, .baseline_px = @intCast(computeBaselineFromFace(face, gh)) },
            faceMetricsInput(face, 1),
            glyph.*.bitmap_left,
            glyph.*.bitmap_top,
            @intCast(bitmap.width),
            @intCast(bitmap.rows),
        );

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
            }
        }
        self.resolve_counters.shaped_clusters += 1;
        return .{ .codepoint = codepoint, .face_id = face_id, .glyph_id = glyph_id };
    }

    fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
        return provider_mod.computeBaselineFromFace(face, cell_h);
    }

    fn deriveCellMetrics(self: *Backend) render_core.CellMetrics {
        return provider_mod.deriveCellMetrics(self);
    }

    fn configuredCellMetrics(self: *Backend) render_core.CellMetrics {
        return provider_mod.configuredCellMetrics(self);
    }

    fn deriveCellSize(self: *Backend) render_core.CellSize {
        return provider_mod.deriveCellSize(self);
    }

    fn beginTargetPass(self: *Backend) BackendError!void {
        if (self.target_texture == null) return error.TargetTextureUnset;
        if (self.target_fbo == 0) {
            c.glGenFramebuffersEXT(1, @ptrCast(&self.target_fbo));
        }
        c.glBindFramebufferEXT(c.GL_FRAMEBUFFER_EXT, self.target_fbo);
        c.glFramebufferTexture2DEXT(
            c.GL_FRAMEBUFFER_EXT,
            c.GL_COLOR_ATTACHMENT0_EXT,
            c.GL_TEXTURE_2D,
            @intCast(self.target_texture.?),
            0,
        );
        if (c.glCheckFramebufferStatusEXT(c.GL_FRAMEBUFFER_EXT) != c.GL_FRAMEBUFFER_COMPLETE_EXT) {
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
        c.glBindFramebufferEXT(c.GL_FRAMEBUFFER_EXT, 0);
    }
};

fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    if (builtin.target.abi == .android) return c.FT_Get_Char_Index(face, codepoint);
    if (hb_font) |font| {
        const buffer = c.hb_buffer_create() orelse return c.FT_Get_Char_Index(face, codepoint);
        defer c.hb_buffer_destroy(buffer);
        var cp: u32 = codepoint;
        c.hb_buffer_add_utf32(buffer, &cp, 1, 0, 1);
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(@ptrCast(font), buffer, null, 0);
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
        if (infos != null and count > 0) {
            const gid = infos[0].codepoint;
            if (gid != 0) return gid;
        }
    }
    return c.FT_Get_Char_Index(face, codepoint);
}

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
) anyerror!render_core.TextStack.ShapeRun.OwnedShapedRun {
    return provider_mod.providerShapeRun(Backend, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
}

fn fallbackProviderShapeRun(
    backend: *Backend,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
    start: usize,
    end: usize,
) anyerror!render_core.TextStack.ShapeRun.OwnedShapedRun {
    const glyphs = try allocator.alloc(render_core.GlyphInstance, end - start);
    errdefer allocator.free(glyphs);
    for (clusters[start..end], 0..) |cluster, idx| {
        const glyph_id = providerGlyphId(backend, run.run.font.face_id, cluster.first_cp);
        const shaped_advance = providerGlyphAdvance(backend, run.run.font.face_id, glyph_id, cell_metrics);
        const advance_px = if (isIconCodepoint(cluster.first_cp)) @max(shaped_advance, providerGlyphVisualWidth(backend, run.run.font.face_id, glyph_id)) else shaped_advance;
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = glyph_id,
            .cluster_index = @intCast(start + idx),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = advance_px,
        };
    }
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
}

fn providerGlyphVisualWidth(self: *Backend, face_id: render_core.FontFaceId, glyph_id: u32) f32 {
    if (glyph_id == 0) return 0;
    if (!self.ensureFont()) return 0;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return 0;
        return glyphVisualWidthPx(face, glyph_id);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return 0;
    const face = self.ensureFallbackFace(fallback_index) orelse return 0;
    return glyphVisualWidthPx(face, glyph_id);
}

const ShapingFace = struct {
    face: FtFace,
    hb_font: ?HbFont,
    owns_face: bool,
};

fn acquireShapingFace(self: *Backend, face_id: render_core.FontFaceId) ?ShapingFace {
    if (!self.ensureFont()) return null;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return null;
        return .{ .face = face, .hb_font = self.hb_font, .owns_face = false };
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return null;
    const face = self.ensureFallbackFace(fallback_index) orelse return null;
    return .{ .face = face, .hb_font = self.fallback_hb_fonts[fallback_index], .owns_face = false };
}

fn releaseShapingFace(_: *Backend, shaped: ShapingFace) void {
    if (shaped.owns_face) {
        if (shaped.hb_font != null and builtin.target.abi != .android) {
            c.hb_font_destroy(@ptrCast(shaped.hb_font.?));
        }
        _ = c.FT_Done_Face(shaped.face);
    }
}

fn textForCluster(text_cache_view: render_core.LineTextCache, cluster: render_core.CellCluster) render_core.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache_view.texts.len) return text_cache_view.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn glyphVisualWidthPx(face: FtFace, glyph_id: u32) f32 {
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_DEFAULT) != 0) return 0;
    if (face.*.glyph == null) return 0;
    const metrics = face.*.glyph.*.metrics;
    if (metrics.width <= 0) return 0;
    return @as(f32, @floatFromInt(@as(i32, @intCast(metrics.width)))) / 64.0;
}

fn isIconCodepoint(cp: u32) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x1f100 and cp <= 0x1f1ff) or
        (cp >= 0xf0000 and cp <= 0xffffd) or
        (cp >= 0x100000 and cp <= 0x10fffd);
}

fn providerGlyphId(self: *Backend, face_id: render_core.FontFaceId, codepoint: u32) u32 {
    return provider_mod.providerGlyphId(self, face_id, codepoint);
}

fn providerGlyphAdvance(self: *Backend, face_id: render_core.FontFaceId, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    return provider_mod.providerGlyphAdvance(self, face_id, glyph_id, cell_metrics);
}

fn providerRasterizeSprite(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render_core.SpriteRasterRequest,
) anyerror!render_core.TextStack.Rasterizer.RasterSpriteOutput {
    return provider_mod.providerRasterizeSprite(Backend, ctx, allocator, req);
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
        0x2591 => fillAlphaPattern(dst, w, h, 0x33),
        0x2592 => fillAlphaPattern(dst, w, h, 0x77),
        0x2593 => fillAlphaPattern(dst, w, h, 0xbb),
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

fn fillAlphaPattern(dst: []u8, w: u16, h: u16, alpha: u8) void {
    for (0..h) |yy| {
        for (0..w) |xx| {
            if (((xx + yy) & 1) == 0) dst[yy * @as(usize, w) + xx] = alpha;
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

fn findSceneSpriteSlot(scene: render_core.TextScene, key: render_core.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn rasterizeProviderGlyph(self: *Backend, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render_core.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (!self.ensureFont()) return false;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return false;
        return rasterizeProviderGlyphFromFace(self, dst, width, height, baseline_px, face, glyph_id, x_origin_px, y_origin_px, glyph_index);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    const face = self.ensureFallbackFace(fallback_index) orelse return false;
    return rasterizeProviderGlyphFromFace(self, dst, width, height, baseline_px, face, glyph_id, x_origin_px, y_origin_px, glyph_index);
}

fn rasterizeProviderGlyphFromFace(self: *Backend, dst: []u8, width: u16, height: u16, baseline_px: i16, face: FtFace, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    _ = self;
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
    const baseline: i32 = if (baseline_px > 0) baseline_px else @intCast(Backend.computeBaselineFromFace(face, height));
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

fn glyphAdvanceFromFace(self: *const Backend, face: FtFace, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    if (!setFacePixelHeight(self, face)) return @floatFromInt(cell_metrics.cell_w_px);
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_DEFAULT) != 0) return @floatFromInt(cell_metrics.cell_w_px);
    if (face.*.glyph == null) return @floatFromInt(cell_metrics.cell_w_px);
    return render_core.TextStack.Metrics.advancePx(@intCast(face.*.glyph.*.advance.x), cell_metrics.cell_w_px);
}

fn setFacePixelHeight(self: *const Backend, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
}

fn cellSizeFromFace(face: FtFace, font_size_px: u16) render_core.CellSize {
    const cell = cellMetricsFromFace(face, font_size_px);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

fn cellMetricsFromFace(face: FtFace, font_size_px: u16) render_core.CellMetrics {
    return render_core.TextStack.Metrics.cellMetricsFromFaceMetrics(faceMetricsInput(face, font_size_px));
}

fn faceMetricsInput(face: FtFace, font_size_px: u16) render_core.TextStack.Metrics.FaceMetrics26Dot6 {
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

fn drawTextScene(backend: *Backend, surface: render_core.PixelSize, scene: render_core.TextScene) void {
    c.glViewport(0, 0, @as(c_int, @intCast(surface.width)), @as(c_int, @intCast(surface.height)));
    c.glDisable(c.GL_DEPTH_TEST);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glLoadIdentity();
    c.glOrtho(
        0.0,
        @as(f64, @floatFromInt(surface.width)),
        @as(f64, @floatFromInt(surface.height)),
        0.0,
        -1.0,
        1.0,
    );
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();
    c.glDisable(c.GL_TEXTURE_2D);
    defer {
        c.glDisable(c.GL_TEXTURE_2D);
        c.glPopMatrix();
        c.glMatrixMode(c.GL_PROJECTION);
        c.glPopMatrix();
        c.glMatrixMode(c.GL_MODELVIEW);
    }

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    defer c.glDisable(c.GL_BLEND);

    if (scene.full_redraw) {
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0.0, 0.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    } else if (scene.scroll_up_px > 0) {
        applyScrollReusePx(backend, surface, scene.scroll_up_px);
    }

    drawSceneClears(backend, surface, scene.clear_draws);
    drawSceneBackgrounds(backend, surface, scene.background_draws);
    drawSceneDecorations(backend, surface, scene.decoration_draws);
    if (backend.atlas_texture != 0) {
        c.glEnable(c.GL_TEXTURE_2D);
        c.glBindTexture(c.GL_TEXTURE_2D, backend.atlas_texture);
        c.glTexEnvi(c.GL_TEXTURE_ENV, c.GL_TEXTURE_ENV_MODE, c.GL_MODULATE);
    }
    drawSceneSprites(backend, surface, scene.sprite_draws);
    if (backend.atlas_texture != 0) {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glDisable(c.GL_TEXTURE_2D);
    }
    drawSceneCursors(backend, surface, scene.cursor_draws);
}

fn drawSceneBackgrounds(backend: *Backend, surface: render_core.PixelSize, backgrounds: []const render_core.TextBackgroundDraw) void {
    if (backgrounds.len == 0) return;
    var vertices = ensureVertexCapacity(&backend.fill_vertices, backgrounds.len * 4) orelse {
        for (backgrounds) |draw| drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    var count: usize = 0;
    for (backgrounds) |draw| {
        _ = appendRectVertices(surface, vertices, &count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn drawSceneClears(backend: *Backend, surface: render_core.PixelSize, clears: []const render_core.TextClearDraw) void {
    if (clears.len == 0) return;
    var vertices = ensureVertexCapacity(&backend.fill_vertices, clears.len * 4) orelse {
        for (clears) |draw| drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    var count: usize = 0;
    for (clears) |draw| {
        _ = appendRectVertices(surface, vertices, &count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn drawSceneDecorations(backend: *Backend, surface: render_core.PixelSize, decorations: []const render_core.TextDecorationDraw) void {
    if (decorations.len == 0) return;
    var vertices = ensureVertexCapacity(&backend.fill_vertices, decorations.len * 4) orelse {
        for (decorations) |draw| drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    var count: usize = 0;
    for (decorations) |draw| {
        _ = appendRectVertices(surface, vertices, &count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn drawSceneCursors(backend: *Backend, surface: render_core.PixelSize, cursors: []const render_core.TextCursorDraw) void {
    if (cursors.len == 0) return;
    var vertices = ensureVertexCapacity(&backend.fill_vertices, cursors.len * 4) orelse {
        for (cursors) |draw| drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    var count: usize = 0;
    for (cursors) |draw| {
        _ = appendRectVertices(surface, vertices, &count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn drawSceneSprites(backend: *Backend, surface: render_core.PixelSize, draws: []const render_core.TextSpriteDraw) void {
    if (draws.len == 0) return;
    var sprite_vertices = ensureVertexCapacity(&backend.glyph_vertices, draws.len * 4) orelse {
        for (draws) |draw| drawSceneSprite(backend, surface, draw);
        return;
    };
    var sprite_count: usize = 0;
    for (draws) |draw| {
        const textured = prepareTexturedSceneSprite(backend, surface, draw) orelse continue;
        appendTexturedGlyphVertices(sprite_vertices, &sprite_count, textured);
    }
    drawTexturedVertices(sprite_vertices[0..sprite_count]);
}

fn drawSceneSprite(backend: *const Backend, surface: render_core.PixelSize, draw: render_core.TextSpriteDraw) void {
    const textured = prepareTexturedSceneSprite(backend, surface, draw) orelse return;
    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4ub(textured.color.r, textured.color.g, textured.color.b, textured.color.a);
    c.glBegin(c.GL_QUADS);
    emitTexturedGlyph(textured);
    c.glEnd();
}

fn applyScrollReusePx(backend: *Backend, surface_px: render_core.PixelSize, scroll_px_u16: u16) void {
    const scroll_px = @as(u32, scroll_px_u16);
    const width = @as(u32, surface_px.width);
    const height = @as(u32, surface_px.height);
    if (scroll_px == 0 or scroll_px >= height) return;
    ensureScrollScratchTexture(backend, surface_px) catch return;
    if (backend.scroll_scratch_texture == 0) return;

    c.glBindTexture(c.GL_TEXTURE_2D, backend.scroll_scratch_texture);
    c.glCopyTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        0,
        0,
        0,
        0,
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(height)),
    );

    c.glDisable(c.GL_BLEND);
    c.glEnable(c.GL_TEXTURE_2D);
    c.glBindTexture(c.GL_TEXTURE_2D, backend.scroll_scratch_texture);
    c.glTexEnvi(c.GL_TEXTURE_ENV, c.GL_TEXTURE_ENV_MODE, c.GL_REPLACE);
    c.glColor4ub(255, 255, 255, 255);
    c.glBegin(c.GL_QUADS);
    const top_v: f32 = 1.0 - @as(f32, @floatFromInt(scroll_px)) / @as(f32, @floatFromInt(height));
    c.glTexCoord2f(0.0, top_v);
    c.glVertex2f(0.0, 0.0);
    c.glTexCoord2f(1.0, top_v);
    c.glVertex2f(@floatFromInt(width), 0.0);
    c.glTexCoord2f(1.0, 0.0);
    c.glVertex2f(@floatFromInt(width), @floatFromInt(height - scroll_px));
    c.glTexCoord2f(0.0, 0.0);
    c.glVertex2f(0.0, @floatFromInt(height - scroll_px));
    c.glEnd();
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glDisable(c.GL_TEXTURE_2D);
}

fn ensureScrollScratchTexture(backend: *Backend, surface_px: render_core.PixelSize) BackendError!void {
    if (backend.scroll_scratch_texture == 0) {
        c.glGenTextures(1, @ptrCast(&backend.scroll_scratch_texture));
        if (backend.scroll_scratch_texture == 0) return error.TargetTextureUnset;
    }
    if (backend.scroll_scratch_width == surface_px.width and backend.scroll_scratch_height == surface_px.height) return;
    backend.scroll_scratch_width = surface_px.width;
    backend.scroll_scratch_height = surface_px.height;
    c.glBindTexture(c.GL_TEXTURE_2D, backend.scroll_scratch_texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        @as(c_int, @intCast(@max(surface_px.width, 1))),
        @as(c_int, @intCast(@max(surface_px.height, 1))),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}

fn ensureVertexCapacity(buffer: *[]QuadVertex, needed: usize) ?[]QuadVertex {
    if (needed == 0) return buffer.*;
    if (buffer.len >= needed) return buffer.*;
    const new_buffer = std.heap.c_allocator.realloc(buffer.*, needed) catch return null;
    buffer.* = new_buffer;
    return new_buffer;
}

fn appendRectVertices(surface: render_core.PixelSize, vertices: []QuadVertex, count: *usize, x: i32, y: i32, width: u16, height: u16, color: render_core.Rgba8) bool {
    const clipped = clip_rect.clipRectTopOrigin(surface, x, y, width, height) orelse return false;
    if (count.* + 4 > vertices.len) return false;
    appendQuad(vertices, count, clipped, color, 0, 0, 0, 0);
    return true;
}

fn appendTexturedGlyphVertices(vertices: []QuadVertex, count: *usize, glyph: TexturedGlyph) void {
    if (count.* + 4 > vertices.len) return;
    appendQuad(vertices, count, glyph.clipped, glyph.color, glyph.tex_u0, glyph.tex_v0, glyph.tex_u1, glyph.tex_v1);
}

fn appendQuad(vertices: []QuadVertex, count: *usize, clipped: clip_rect.ClipRect, color: render_core.Rgba8, tex_u0: f32, tex_v0: f32, tex_u1: f32, tex_v1: f32) void {
    const x0: f32 = @floatFromInt(clipped.x);
    const y0: f32 = @floatFromInt(clipped.y);
    const x1: f32 = @floatFromInt(clipped.x + clipped.w);
    const y1: f32 = @floatFromInt(clipped.y + clipped.h);
    vertices[count.* + 0] = .{ .x = x0, .y = y0, .u = tex_u0, .v = tex_v0, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[count.* + 1] = .{ .x = x1, .y = y0, .u = tex_u1, .v = tex_v0, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[count.* + 2] = .{ .x = x1, .y = y1, .u = tex_u1, .v = tex_v1, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[count.* + 3] = .{ .x = x0, .y = y1, .u = tex_u0, .v = tex_v1, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    count.* += 4;
}

fn drawSolidVertices(vertices: []const QuadVertex) void {
    if (vertices.len == 0) return;
    c.glDisable(c.GL_TEXTURE_2D);
    drawVertexArray(vertices, false);
}

fn drawTexturedVertices(vertices: []const QuadVertex) void {
    if (vertices.len == 0) return;
    c.glEnable(c.GL_TEXTURE_2D);
    drawVertexArray(vertices, true);
}

fn drawVertexArray(vertices: []const QuadVertex, textured: bool) void {
    if (vertices.len == 0) return;
    c.glEnableClientState(c.GL_VERTEX_ARRAY);
    c.glEnableClientState(c.GL_COLOR_ARRAY);
    if (textured) c.glEnableClientState(c.GL_TEXTURE_COORD_ARRAY);
    defer {
        if (textured) c.glDisableClientState(c.GL_TEXTURE_COORD_ARRAY);
        c.glDisableClientState(c.GL_COLOR_ARRAY);
        c.glDisableClientState(c.GL_VERTEX_ARRAY);
    }

    const stride: c.GLsizei = @intCast(@sizeOf(QuadVertex));
    c.glVertexPointer(2, c.GL_FLOAT, stride, &vertices[0].x);
    c.glColorPointer(4, c.GL_UNSIGNED_BYTE, stride, &vertices[0].r);
    if (textured) c.glTexCoordPointer(2, c.GL_FLOAT, stride, &vertices[0].u);
    c.glDrawArrays(c.GL_QUADS, 0, @intCast(vertices.len));
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render_core.TextStack.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn useDeterministicTestTextFallback(backend: *Backend) bool {
    return builtin.is_test and backend.config.font_path == null and backend.fallback_font_paths_len == 0;
}

fn drawRect(surface: render_core.PixelSize, x: i32, y: i32, width: u16, height: u16, color: render_core.Rgba8) void {
    const clipped = clip_rect.clipRectTopOrigin(surface, x, y, width, height) orelse return;
    c.glDisable(c.GL_TEXTURE_2D);
    c.glColor4ub(color.r, color.g, color.b, color.a);
    c.glBegin(c.GL_QUADS);
    c.glVertex2f(@floatFromInt(clipped.x), @floatFromInt(clipped.y));
    c.glVertex2f(@floatFromInt(clipped.x + clipped.w), @floatFromInt(clipped.y));
    c.glVertex2f(@floatFromInt(clipped.x + clipped.w), @floatFromInt(clipped.y + clipped.h));
    c.glVertex2f(@floatFromInt(clipped.x), @floatFromInt(clipped.y + clipped.h));
    c.glEnd();
}

fn prepareTexturedSceneSprite(backend: *const Backend, surface: render_core.PixelSize, draw: render_core.TextSpriteDraw) ?TexturedGlyph {
    if (backend.atlas_texture == 0 or backend.atlas_pixels.len == 0) return null;
    const slot = @as(usize, draw.sprite.slot);
    if (slot >= backend.atlas_slot_has_alpha.len or !backend.atlas_slot_has_alpha[slot]) return null;
    const slot_index = slot * backend.atlas_slot_stride;
    if (slot_index + backend.atlas_slot_stride > backend.atlas_pixels.len) return null;
    const gw = @min(@min(draw.width_px, backend.atlas_cell_w), if (slot < backend.atlas_slot_width.len) backend.atlas_slot_width[slot] else draw.width_px);
    const gh = @min(@min(draw.height_px, backend.atlas_cell_h), if (slot < backend.atlas_slot_height.len) backend.atlas_slot_height[slot] else draw.height_px);
    if (gw == 0 or gh == 0) return null;
    const clipped = clip_rect.clipRectTopOrigin(surface, draw.x_px, draw.y_px, gw, gh) orelse return null;
    const cols = @min(backend.capabilities().max_atlas_slots, Backend.AtlasTexCols);
    const slot_x = (slot % cols) * @as(usize, backend.atlas_cell_w);
    const slot_y = (slot / cols) * @as(usize, backend.atlas_cell_h);

    const clip_dx: usize = @intCast(@max(clipped.x - draw.x_px, 0));
    const clip_dy: usize = @intCast(@max(clipped.y - draw.y_px, 0));
    return .{
        .clipped = clipped,
        .color = draw.color,
        .tex_u0 = @as(f32, @floatFromInt(slot_x + clip_dx)) / @as(f32, @floatFromInt(backend.atlas_tex_width)),
        .tex_v0 = @as(f32, @floatFromInt(slot_y + clip_dy)) / @as(f32, @floatFromInt(backend.atlas_tex_height)),
        .tex_u1 = @as(f32, @floatFromInt(slot_x + clip_dx + @as(usize, @intCast(clipped.w)))) / @as(f32, @floatFromInt(backend.atlas_tex_width)),
        .tex_v1 = @as(f32, @floatFromInt(slot_y + clip_dy + @as(usize, @intCast(clipped.h)))) / @as(f32, @floatFromInt(backend.atlas_tex_height)),
    };
}

fn emitTexturedGlyph(glyph: TexturedGlyph) void {
    c.glTexCoord2f(glyph.tex_u0, glyph.tex_v0);
    c.glVertex2f(@floatFromInt(glyph.clipped.x), @floatFromInt(glyph.clipped.y));
    c.glTexCoord2f(glyph.tex_u1, glyph.tex_v0);
    c.glVertex2f(@floatFromInt(glyph.clipped.x + glyph.clipped.w), @floatFromInt(glyph.clipped.y));
    c.glTexCoord2f(glyph.tex_u1, glyph.tex_v1);
    c.glVertex2f(@floatFromInt(glyph.clipped.x + glyph.clipped.w), @floatFromInt(glyph.clipped.y + glyph.clipped.h));
    c.glTexCoord2f(glyph.tex_u0, glyph.tex_v1);
    c.glVertex2f(@floatFromInt(glyph.clipped.x), @floatFromInt(glyph.clipped.y + glyph.clipped.h));
}

test "backend rejects operations after deinit" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    backend.deinit();

    try std.testing.expectError(error.BackendClosed, backend.resize(.{ .width = 800, .height = 600 }, .{ .width = 10, .height = 20 }));
}

test "backend exposes text provider and font session scaffold" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const session = backend.fontSession(&faces);
    try std.testing.expect(provider.face_provider != null);
    try std.testing.expectEqual(@as(u32, primary_face_id), session.primary_face.value);
    try std.testing.expectEqual(@as(usize, 1), session.faces.len);
    try std.testing.expectEqual(@as(u16, 8), session.metrics.cell_w_px);
    try std.testing.expectEqual(@as(u16, 16), session.metrics.cell_h_px);
}

test "backend text session metrics respect configured cell size" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 9, .height = 17 },
    });
    defer backend.deinit();
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    const session = backend.fontSession(&faces);
    try std.testing.expectEqual(@as(u16, 9), session.metrics.cell_w_px);
    try std.testing.expectEqual(@as(u16, 17), session.metrics.cell_h_px);
    try std.testing.expect(session.metrics.baseline_px > 0);
    try std.testing.expect(session.metrics.baseline_px <= 17);
}

test "backend text provider shaper returns glyph instances" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const clusters = [_]render_core.CellCluster{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = 'A',
        .style = .regular,
        .presentation = .any,
    }};
    const run = render_core.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = primary_face_id }, .style = .regular, .presentation = .any },
    } };
    const cache_view = render_core.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} }} };
    var shaped = try provider.shaper.shapeRun(std.testing.allocator, run, cache_view, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
    try std.testing.expectEqual(@as(u32, primary_face_id), shaped.glyphs[0].face_id.value);
}

test "backend text provider rasterizer returns sprite output" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const glyph = render_core.GlyphInstance{
        .face_id = .{ .value = primary_face_id },
        .glyph_id = providerGlyphId(&backend, .{ .value = primary_face_id }, 'A'),
        .cluster_index = 0,
    };
    const group = render_core.GlyphGroup{
        .first_cell = 0,
        .cell_span = 1,
        .glyphs = &.{glyph},
        .sprite_key = .{ .value = 123 },
        .kind = .normal,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render_core.TextStack.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    try std.testing.expectEqual(@as(u16, 8), out.width_px);
    try std.testing.expectEqual(@as(u16, 16), out.height_px);
    try std.testing.expectEqual(@as(usize, 8 * 16), out.pixels.len);
}

test "backend text provider rasterizer draws box fallback alpha" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const group = render_core.GlyphGroup{
        .first_cell = 0,
        .first_cp = 0x2500,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 2500 },
        .kind = .box_fallback,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render_core.TextStack.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    var lit: usize = 0;
    for (out.pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit >= 8);
    try std.testing.expect(lit < out.pixels.len);
}

test "backend analyzes text cells through provider-backed engine" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
    };
    var faces: [8]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, &faces);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 2), analysis.groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
}

test "backend analyzes text cells with scene cursor options" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCellsOptions(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces, .{
        .scene = .{ .cursor = .{ .cell_col = 0, .cell_row = 0, .shape = .beam, .color = white } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.cursor_draws.len);
}

test "backend uploads text analysis raster outputs into atlas memory" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer analysis.deinit();
    const committed = try backend.uploadTextAnalysisRaster(analysis);
    try std.testing.expectEqual(@as(usize, 1), committed);
    const committed_scene = try backend.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    try std.testing.expectEqual(@as(usize, 0), committed_scene);
    try std.testing.expect(backend.atlas_pixels.len > 0);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expect(slot_idx < backend.atlas_slot_has_alpha.len);
    try std.testing.expect(backend.atlas_slot_width[slot_idx] == 8);
}

test "backend text analysis reuses retained scene atlas for unchanged glyphs" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;

    var first = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.raster_plan.outputs.len);

    var second = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.raster_plan.outputs.len);
    try std.testing.expectEqual(first.scene.scene.sprite_draws[0].sprite.slot, second.scene.scene.sprite_draws[0].sprite.slot);
}

test "backend text scene cache treats transparent raster output as cached" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    var outputs = [_]render_core.TextStack.Rasterizer.RasterSpriteOutput{.{
        .allocator = std.testing.allocator,
        .key = .{ .value = 77 },
        .width_px = 8,
        .height_px = 16,
        .pixels = try std.testing.allocator.alloc(u8, 8 * 16),
    }};
    defer outputs[0].deinit();
    @memset(outputs[0].pixels, 0);

    const draw = render_core.TextSpriteDraw{
        .sprite = .{ .slot = 0, .key = outputs[0].key },
        .x_px = 0,
        .y_px = 0,
        .width_px = 8,
        .height_px = 16,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };
    const scene = render_core.TextScene{
        .cells = &.{},
        .sprite_draws = &.{draw},
        .missing = &.{},
    };

    const first = try backend.uploadTextSceneRaster(scene, &outputs);
    const second = try backend.uploadTextSceneRaster(scene, &outputs);
    try std.testing.expectEqual(@as(usize, 1), first);
    try std.testing.expectEqual(@as(usize, 0), second);
    try std.testing.expect(!backend.atlas_slot_has_alpha[0]);
}

test "backend renders text scene handoff without legacy glyph batch" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black, .underline = true }};
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer analysis.deinit();
    const report = try backend.renderTextScene(analysis.scene.scene, analysis.raster_plan.outputs);
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expectEqual(@as(usize, 1), report.raster_uploads_committed);
    try std.testing.expectEqual(analysis.scene.scene.background_draws.len, report.background_draws);
    try std.testing.expectEqual(analysis.scene.scene.sprite_draws.len, report.sprite_draws);
    try std.testing.expectEqual(analysis.scene.scene.decoration_draws.len, report.decoration_draws);
}

test "backend text scene report includes cursor draws" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cursor = render_core.TextCursorDraw{ .x_px = 8, .y_px = 16, .width_px = 2, .height_px = 16, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    const scene = render_core.TextScene{
        .cells = &.{},
        .background_draws = &.{},
        .sprite_draws = &.{},
        .decoration_draws = &.{},
        .cursor_draws = &.{cursor},
        .raster_requests = &.{},
        .missing = &.{},
    };
    const report = try backend.renderTextScene(scene, &.{});
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend renders frame state through opt-in text scene path" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render_core.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    const report = try backend.renderFrameStateTextScene(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, &faces);
    try std.testing.expectEqual(@as(usize, 1), report.sprite_draws);
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend renderFrameState uses text scene renderer" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render_core.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    const report = try backend.renderFrameState(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expectEqual(@as(usize, 1), report.stats.glyphs);
    try std.testing.expect(report.stats.has_cursor);
}

test "backend text scene atlas storage fits multicell sprites" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
    };
    var faces: [4]render_core.TextStack.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, &faces);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    _ = try backend.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_cell_w);
    try std.testing.expect(slot_idx < backend.atlas_slot_width.len);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_slot_width[slot_idx]);
}

test {
    _ = @import("tests.zig");
}
