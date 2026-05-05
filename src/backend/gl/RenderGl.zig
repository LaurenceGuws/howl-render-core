//! Responsibility: implement the OpenGL backend owner surface.
//! Ownership: unified renderer GL backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../render_core.zig").RenderCore;
const trace = @import("../../trace.zig");
const clip_rect = @import("../shared/clip_rect.zig");
const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    if (builtin.target.abi != .android) {
        @cInclude("harfbuzz/hb.h");
        @cInclude("harfbuzz/hb-ft.h");
    }
});
const FtLibrary = c.FT_Library;
const FtFace = c.FT_Face;
const HbFont = if (builtin.target.abi == .android) usize else *c.hb_font_t;

const primary_face_id: u32 = 1;

const ResolvedGlyphKey = struct {
    codepoint: u21,
    face_id: u32,
    glyph_id: u32,
};

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

fn stdoutLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, fmt ++ "\n", args) catch return;
    _ = c.printf("%s", line.ptr);
    _ = c.fflush(c.stdout);
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
} || render_core.RenderBatchValidationError;

/// Render report returned after processing one render batch.
pub const RenderReport = struct {
    stats: render_core.RenderBatchStats,
    pass_index: u64,
    atlas_uploads_committed: usize,
};

pub const TextSceneRenderReport = struct {
    pass_index: u64,
    raster_uploads_committed: usize,
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
pub const RenderGl = struct {
    /// Backend config alias.
    pub const Config = render_core.BackendConfig;
    /// Backend capability alias.
    pub const Capability = render_core.BackendCapability;
    /// Backend error alias.
    pub const Error = BackendError;
    /// Render report alias.
    pub const Report = RenderReport;

    /// Construct backend from config.
    pub fn init(config: Config) Backend {
        return Backend.init(config);
    }
};

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
    const AtlasTexCols: usize = 64;

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
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_fbo: u32 = 0,
    surface_epoch: u64 = 1,
    resolve_counters: render_core.ResolveCounters = .{},
    resolve_stage: render_core.ResolveStage = .style_policy,
    fill_vertices: []QuadVertex = &.{},
    glyph_vertices: []QuadVertex = &.{},
    fallback_fill_vertices: []QuadVertex = &.{},
    retained_frame: render_core.RetainedFrame = .{},
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: usize = 0,

    /// Initialize a backend instance from shared backend config.
    pub fn init(config: render_core.BackendConfig) Backend {
        return .{ .config = config };
    }

    /// Release backend resources and prevent further rendering.
    pub fn deinit(self: *Backend) void {
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
        self.retained_frame.deinit(std.heap.c_allocator);
        if (self.ft_face != null) {
            if (self.hb_font != null and builtin.target.abi != .android) {
                c.hb_font_destroy(@ptrCast(self.hb_font.?));
                self.hb_font = null;
            }
            _ = c.FT_Done_Face(self.ft_face.?);
            self.ft_face = null;
        }
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
        var adapter = self.textProvider();
        var engine = try render_core.TextStack.Engine.Engine.initWithProvider(allocator, self.capabilities().max_atlas_slots, adapter.textProvider());
        defer engine.deinit();
        return engine.analyzeLegacyCellsWithSessionOptions(cells, grid, self.fontSession(faces), options);
    }

    pub fn uploadTextAnalysisRaster(self: *Backend, analysis: render_core.TextStack.Engine.OwnedTextAnalysis) BackendError!usize {
        return self.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    }

    pub fn uploadTextSceneRaster(
        self: *Backend,
        scene: render_core.TextScene,
        outputs: []const render_core.TextStack.Rasterizer.RasterSpriteOutput,
    ) BackendError!usize {
        try self.ensureAtlasStorageForRasterOutputs(outputs);
        if (hasCurrentContext()) try self.ensureAtlasTexture();
        var committed: usize = 0;
        for (outputs) |output| {
            const slot = findSceneSpriteSlot(scene, output.key) orelse continue;
            self.copyRasterOutputToAtlas(slot, output);
            if (hasCurrentContext()) self.uploadAtlasSlot(slot);
            committed += 1;
        }
        return committed;
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
        self.config.surface_px = surface_px;
        self.config.cell_px = cell_px;
        if (surface_changed) self.surface_epoch +%= 1;
        if (surface_changed and self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
            self.resizeOwnedTargetTexture();
        }
    }

    /// Validate and render a batch against backend config/capability.
    pub fn renderBatch(_: *Backend, _: render_core.RenderBatch) BackendError!RenderReport {
        @panic("GL RenderBatch/GlyphQuad text path is retired; use renderTextScene/renderFrameState");
    }

    /// Build batch from VT state and render it.
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

    pub fn prepareFrameState(
        _: *Backend,
        _: std.mem.Allocator,
        _: anytype,
        _: render_core.PixelSize,
        _: render_core.CellSize,
    ) BackendError!render_core.OwnedRenderBatch {
        @panic("GL prepareFrameState legacy RenderBatch path is retired; use renderFrameStateTextScene/renderFrameState");
    }

    pub fn prepareRetainedFrameState(
        _: *Backend,
        _: std.mem.Allocator,
        _: SurfaceFrameData,
        _: render_core.PixelSize,
        _: render_core.CellSize,
    ) BackendError!render_core.OwnedRenderBatch {
        @panic("GL prepareRetainedFrameState legacy RenderBatch path is retired; use renderFrameStateTextScene/renderFrameState");
    }

    fn uploadAtlas(self: *Backend, batch: render_core.RenderBatch) BackendError!usize {
        if (batch.atlas_uploads.len == 0) return 0;
        const start_ns = monotonicNs();
        try self.ensureAtlasStorage();
        if (hasCurrentContext()) try self.ensureAtlasTexture();
        var committed: usize = 0;
        var fast_hits: usize = 0;
        const resolved_hits: usize = 0;
        for (batch.atlas_uploads) |upload| {
            if (self.findCachedSlotForDraw(upload.codepoint, upload.width, upload.height) != null) {
                fast_hits += 1;
                continue;
            }
            const slot = self.allocateSlot() orelse continue;
            const key = self.rasterizeSlot(slot, upload.codepoint, upload.width, upload.height);
            self.markSlotCached(slot, key, upload.width, upload.height);
            if (hasCurrentContext()) self.uploadAtlasSlot(slot);
            committed += 1;
        }
        trace.renderAtlas("gl",
            batch.atlas_uploads.len,
            fast_hits,
            resolved_hits,
            committed,
            @divTrunc(monotonicNs() - start_ns, std.time.ns_per_us),
        );
        return committed;
    }

    fn uploadAtlasSlot(self: *Backend, slot: u32) void {
        if (self.atlas_texture == 0 or self.atlas_pixels.len == 0) return;
        const slot_idx = @as(usize, slot);
        const slot_off = slot_idx * self.atlas_slot_stride;
        if (slot_off + self.atlas_slot_stride > self.atlas_pixels.len) return;
        const cols = @min(self.capabilities().max_atlas_slots, AtlasTexCols);
        const cell_w = @as(usize, self.atlas_cell_w);
        const cell_h = @as(usize, self.atlas_cell_h);
        const x = (slot_idx % cols) * cell_w;
        const y = (slot_idx / cols) * cell_h;
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            @as(c_int, @intCast(x)),
            @as(c_int, @intCast(y)),
            @as(c_int, @intCast(cell_w)),
            @as(c_int, @intCast(cell_h)),
            c.GL_ALPHA,
            c.GL_UNSIGNED_BYTE,
            self.atlas_pixels[slot_off..].ptr,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    fn copyRasterOutputToAtlas(self: *Backend, slot: u32, output: render_core.TextStack.Rasterizer.RasterSpriteOutput) void {
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
        if (slot_idx < self.atlas_slot_width.len) self.atlas_slot_width[slot_idx] = output.width_px;
        if (slot_idx < self.atlas_slot_height.len) self.atlas_slot_height[slot_idx] = output.height_px;
        self.markSlotAlpha(slot, dst, copy_w, copy_h);
    }

    fn ensureAtlasStorage(self: *Backend) BackendError!void {
        const need_w = @max(self.config.cell_px.width, 1);
        const need_h = @max(self.config.cell_px.height, 1);
        return self.ensureAtlasStorageSized(need_w, need_h);
    }

    fn ensureAtlasStorageForRasterOutputs(self: *Backend, outputs: []const render_core.TextStack.Rasterizer.RasterSpriteOutput) BackendError!void {
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
        if (self.atlas_texture != 0 and hasCurrentContext()) {
            c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
            self.atlas_texture = 0;
        }
        self.atlas_tex_width = 0;
        self.atlas_tex_height = 0;
    }

    fn ensureAtlasTexture(self: *Backend) BackendError!void {
        if (!hasCurrentContext()) return;
        const max_slots = self.capabilities().max_atlas_slots;
        const cols: usize = @min(max_slots, AtlasTexCols);
        const rows: usize = std.math.divCeil(usize, max_slots, cols) catch unreachable;
        const need_w: u16 = @intCast(@as(usize, self.atlas_cell_w) * cols);
        const need_h: u16 = @intCast(@as(usize, self.atlas_cell_h) * rows);
        if (self.atlas_texture != 0 and self.atlas_tex_width == need_w and self.atlas_tex_height == need_h) return;

        if (self.atlas_texture != 0) {
            c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
            self.atlas_texture = 0;
        }

        c.glGenTextures(1, @ptrCast(&self.atlas_texture));
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_ALPHA,
            @as(c_int, @intCast(need_w)),
            @as(c_int, @intCast(need_h)),
            0,
            c.GL_ALPHA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        self.atlas_tex_width = need_w;
        self.atlas_tex_height = need_h;
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

    fn ensureFont(self: *Backend) bool {
        if (self.ensurePrimaryFont()) {
            self.resolve_stage = .loaded_exact_match;
            return true;
        }
        if (!self.ensureFreeTypeLibrary()) return false;

        var face: FtFace = undefined;
        const lib = self.ft_lib.?;

        var i: usize = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            const font_path = self.fallback_font_paths[i] orelse continue;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) == 0) {
                _ = c.FT_Done_Face(face);
                self.resolve_stage = .discovery_fallback;
                return true;
            }
        }

        self.resolve_stage = .missing_glyph;
        self.resolve_counters.missing_glyphs += 1;
        return false;
    }

    fn resetLoadedFace(self: *Backend) void {
        if (self.ft_face != null) {
            if (self.hb_font != null and builtin.target.abi != .android) {
                c.hb_font_destroy(@ptrCast(self.hb_font.?));
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

    fn clearAtlasCache(self: *Backend) void {
        if (self.atlas_pixels.len > 0) @memset(self.atlas_pixels, 0);
        if (self.atlas_slot_codepoint.len > 0) @memset(self.atlas_slot_codepoint, 0);
        if (self.atlas_slot_face_id.len > 0) @memset(self.atlas_slot_face_id, 0);
        if (self.atlas_slot_glyph_id.len > 0) @memset(self.atlas_slot_glyph_id, 0);
        if (self.atlas_slot_width.len > 0) @memset(self.atlas_slot_width, 0);
        if (self.atlas_slot_height.len > 0) @memset(self.atlas_slot_height, 0);
        if (self.atlas_slot_has_alpha.len > 0) @memset(self.atlas_slot_has_alpha, false);
        self.atlas_next_slot = 0;
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
        return render_core.TextStack.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
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

        return render_core.TextStack.Metrics.defaultCellMetrics(self.config.font_size_px);
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
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    if (!backend.ensureFont()) return false;
    if (face_id.value == primary_face_id) {
        const face = backend.ft_face orelse return false;
        return c.FT_Get_Char_Index(face, codepoint) != 0;
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    if (fallback_index >= backend.fallback_font_paths_len) return false;
    const font_path = backend.fallback_font_paths[fallback_index] orelse return false;
    const lib = backend.ft_lib orelse return false;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return false;
    defer _ = c.FT_Done_Face(face);
    return c.FT_Get_Char_Index(face, codepoint) != 0;
}

fn providerHasCellText(ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
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
    text_cache: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
) anyerror!render_core.TextStack.ShapeRun.OwnedShapedRun {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const start = @as(usize, @intCast(run.run.cluster_start));
    const count = @as(usize, @intCast(run.run.cluster_count));
    const end = @min(start + count, clusters.len);
    if (end <= start) {
        return .{ .allocator = allocator, .run = run, .glyphs = try allocator.alloc(render_core.GlyphInstance, 0) };
    }

    if (builtin.target.abi == .android) {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    }

    const shaped_face = acquireShapingFace(backend, run.run.font.face_id) orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };
    defer releaseShapingFace(backend, shaped_face);
    const hb_font = shaped_face.hb_font orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };

    var run_codepoints = std.ArrayList(u32).empty;
    defer run_codepoints.deinit(allocator);
    var cluster_map = std.ArrayList(u32).empty;
    defer cluster_map.deinit(allocator);
    for (clusters[start..end], 0..) |cluster, local_idx| {
        const text = textForCluster(text_cache, cluster);
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        try run_codepoints.appendSlice(allocator, cps);
        for (cps) |_| try cluster_map.append(allocator, @intCast(start + local_idx));
    }
    if (run_codepoints.items.len == 0) {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    }

    const buffer = c.hb_buffer_create() orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };
    defer c.hb_buffer_destroy(buffer);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_buffer_add_utf32(buffer, run_codepoints.items.ptr, @intCast(run_codepoints.items.len), 0, @intCast(run_codepoints.items.len));
    c.hb_buffer_guess_segment_properties(buffer);
    c.hb_shape(@ptrCast(hb_font), buffer, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);
    if (infos == null or positions == null or glyph_count == 0) {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    }

    const glyphs = try allocator.alloc(render_core.GlyphInstance, glyph_count);
    errdefer allocator.free(glyphs);

    for (glyphs, 0..) |*glyph, idx| {
        const info = infos[idx];
        const pos = positions[idx];
        const cluster_cp_idx = @min(@as(usize, info.cluster), cluster_map.items.len - 1);
        glyph.* = .{
            .face_id = run.run.font.face_id,
            .glyph_id = info.codepoint,
            .cluster_index = cluster_map.items[cluster_cp_idx],
            .x_offset_px = @as(f32, @floatFromInt(@as(i32, @intCast(pos.x_offset)))) / 64.0,
            .y_offset_px = @as(f32, @floatFromInt(@as(i32, @intCast(pos.y_offset)))) / 64.0,
            .x_advance_px = render_core.TextStack.Metrics.advancePx(@intCast(pos.x_advance), cell_metrics.cell_w_px),
        };
    }

    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
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
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
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
    if (fallback_index >= self.fallback_font_paths_len) return null;
    const font_path = self.fallback_font_paths[fallback_index] orelse return null;
    const lib = self.ft_lib orelse return null;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return null;
    if (!setFacePixelHeight(self, face)) {
        _ = c.FT_Done_Face(face);
        return null;
    }
    var hb_font: ?HbFont = null;
    if (builtin.target.abi != .android) {
        hb_font = @ptrCast(c.hb_ft_font_create_referenced(face));
    }
    return .{ .face = face, .hb_font = hb_font, .owns_face = true };
}

fn releaseShapingFace(_: *Backend, shaped: ShapingFace) void {
    if (shaped.owns_face) {
        if (shaped.hb_font != null and builtin.target.abi != .android) {
            c.hb_font_destroy(@ptrCast(shaped.hb_font.?));
        }
        _ = c.FT_Done_Face(shaped.face);
    }
}

fn textForCluster(text_cache: render_core.LineTextCache, cluster: render_core.CellCluster) render_core.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache.texts.len) return text_cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn providerGlyphId(self: *Backend, face_id: render_core.FontFaceId, codepoint: u32) u32 {
    if (!self.ensureFont()) return 0;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return 0;
        return shapeGlyphId(self.hb_font, face, @intCast(codepoint));
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return 0;
    if (fallback_index >= self.fallback_font_paths_len) return 0;
    const font_path = self.fallback_font_paths[fallback_index] orelse return 0;
    const lib = self.ft_lib orelse return 0;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return 0;
    defer _ = c.FT_Done_Face(face);
    if (!setFacePixelHeight(self, face)) return 0;

    var fallback_hb: ?HbFont = null;
    defer if (fallback_hb != null and builtin.target.abi != .android) {
        c.hb_font_destroy(@ptrCast(fallback_hb.?));
    };
    if (builtin.target.abi != .android) {
        fallback_hb = @ptrCast(c.hb_ft_font_create_referenced(face));
    }
    return shapeGlyphId(fallback_hb, face, @intCast(codepoint));
}

fn providerGlyphAdvance(self: *Backend, face_id: render_core.FontFaceId, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    const fallback: f32 = @floatFromInt(cell_metrics.cell_w_px);
    if (glyph_id == 0) return fallback;
    if (!self.ensureFont()) return fallback;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return fallback;
        return glyphAdvanceFromFace(self, face, glyph_id, cell_metrics);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return fallback;
    if (fallback_index >= self.fallback_font_paths_len) return fallback;
    const font_path = self.fallback_font_paths[fallback_index] orelse return fallback;
    const lib = self.ft_lib orelse return fallback;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return fallback;
    defer _ = c.FT_Done_Face(face);
    return glyphAdvanceFromFace(self, face, glyph_id, cell_metrics);
}

fn providerRasterizeSprite(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render_core.SpriteRasterRequest,
) anyerror!render_core.TextStack.Rasterizer.RasterSpriteOutput {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const width = @max(req.width_px, 1);
    const height = @max(req.height_px, 1);
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

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
    if (!self.ensureFont()) return false;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return false;
        return rasterizeProviderGlyphFromFace(self, dst, width, height, baseline_px, face, glyph_id, x_origin_px, y_origin_px, glyph_index);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    if (fallback_index >= self.fallback_font_paths_len) return false;
    const font_path = self.fallback_font_paths[fallback_index] orelse return false;
    const lib = self.ft_lib orelse return false;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return false;
    defer _ = c.FT_Done_Face(face);
    if (!setFacePixelHeight(self, face)) return false;
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
    var max_advance: i32 = @intCast(metrics.max_advance);
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0 and face.*.glyph != null) {
        max_advance = @max(max_advance, @as(i32, @intCast(face.*.glyph.*.advance.x)));
    }
    return .{
        .ascender = @intCast(metrics.ascender),
        .descender = @intCast(metrics.descender),
        .height = @intCast(metrics.height),
        .max_advance = max_advance,
        .fallback_font_px = @max(font_size_px, 1),
    };
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
            .fills = report.background_draws + report.decoration_draws + report.cursor_draws,
            .glyphs = report.sprite_draws,
            .atlas_uploads = report.raster_uploads_committed,
            .has_cursor = report.cursor_draws > 0,
            .full_redraw = true,
        },
        .pass_index = report.pass_index,
        .atlas_uploads_committed = report.raster_uploads_committed,
    };
}

fn drawBatch(backend: *Backend, batch: render_core.RenderBatch) void {
    c.glViewport(0, 0, @as(c_int, @intCast(batch.surface_px.width)), @as(c_int, @intCast(batch.surface_px.height)));
    c.glDisable(c.GL_DEPTH_TEST);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glLoadIdentity();
    c.glOrtho(
        0.0,
        @as(f64, @floatFromInt(batch.surface_px.width)),
        @as(f64, @floatFromInt(batch.surface_px.height)),
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

    if (batch.full_redraw) {
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0.0, 0.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    } else if (batch.scroll_up_rows > 0) {
        applyScrollReuse(backend, batch);
    }

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    defer c.glDisable(c.GL_BLEND);

    drawFillRects(backend, batch.surface_px, batch.fills);
    if (backend.atlas_texture != 0) {
        c.glEnable(c.GL_TEXTURE_2D);
        c.glBindTexture(c.GL_TEXTURE_2D, backend.atlas_texture);
        c.glTexEnvi(c.GL_TEXTURE_ENV, c.GL_TEXTURE_ENV_MODE, c.GL_MODULATE);
    }
    drawGlyphs(backend, batch.surface_px, batch.glyphs);
    if (backend.atlas_texture != 0) {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glDisable(c.GL_TEXTURE_2D);
    }
    if (batch.cursor) |cursor| drawCursor(batch, cursor);
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
    var fallback_vertices = ensureVertexCapacity(&backend.fallback_fill_vertices, draws.len * 4) orelse {
        for (draws) |draw| drawSceneSprite(backend, surface, draw);
        return;
    };
    var sprite_count: usize = 0;
    var fallback_count: usize = 0;
    for (draws) |draw| {
        const textured = prepareTexturedSceneSprite(backend, surface, draw) orelse {
            _ = appendRectVertices(surface, fallback_vertices, &fallback_count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
            continue;
        };
        appendTexturedGlyphVertices(sprite_vertices, &sprite_count, textured);
    }
    drawTexturedVertices(sprite_vertices[0..sprite_count]);
    drawSolidVertices(fallback_vertices[0..fallback_count]);
}

fn drawSceneSprite(backend: *const Backend, surface: render_core.PixelSize, draw: render_core.TextSpriteDraw) void {
    const textured = prepareTexturedSceneSprite(backend, surface, draw) orelse {
        drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4ub(textured.color.r, textured.color.g, textured.color.b, textured.color.a);
    c.glBegin(c.GL_QUADS);
    emitTexturedGlyph(textured);
    c.glEnd();
}

fn applyScrollReuse(backend: *Backend, batch: render_core.RenderBatch) void {
    const scroll_px = @as(u32, batch.scroll_up_rows) * @as(u32, batch.cell_px.height);
    const width = @as(u32, batch.surface_px.width);
    const height = @as(u32, batch.surface_px.height);
    if (scroll_px == 0 or scroll_px >= height) return;
    ensureScrollScratchTexture(backend, batch.surface_px) catch return;
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

fn drawGlyph(backend: *const Backend, surface: render_core.PixelSize, glyph: render_core.GlyphQuad) void {
    const textured = prepareTexturedGlyph(backend, surface, glyph) orelse {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
        return;
    };
    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4ub(textured.color.r, textured.color.g, textured.color.b, textured.color.a);
    c.glBegin(c.GL_QUADS);
    emitTexturedGlyph(textured);
    c.glEnd();
}

fn drawGlyphs(backend: *Backend, surface: render_core.PixelSize, glyphs: []const render_core.GlyphQuad) void {
    if (glyphs.len == 0) return;
    const glyph_capacity = glyphs.len * 4;
    var glyph_vertices = ensureVertexCapacity(&backend.glyph_vertices, glyph_capacity) orelse {
        for (glyphs) |glyph| drawGlyph(backend, surface, glyph);
        return;
    };
    var fallback_vertices = ensureVertexCapacity(&backend.fallback_fill_vertices, glyph_capacity) orelse {
        for (glyphs) |glyph| drawGlyph(backend, surface, glyph);
        return;
    };
    var glyph_vertex_count: usize = 0;
    var fallback_vertex_count: usize = 0;

    for (glyphs) |glyph| {
        const textured = prepareTexturedGlyph(backend, surface, glyph) orelse {
            if (appendRectVertices(surface, fallback_vertices, &fallback_vertex_count, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg)) {}
            continue;
        };
        appendTexturedGlyphVertices(glyph_vertices, &glyph_vertex_count, textured);
    }
    drawTexturedVertices(glyph_vertices[0..glyph_vertex_count]);
    drawSolidVertices(fallback_vertices[0..fallback_vertex_count]);
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

fn prepareTexturedGlyph(backend: *const Backend, surface: render_core.PixelSize, glyph: render_core.GlyphQuad) ?TexturedGlyph {
    if (backend.atlas_texture == 0 or backend.atlas_pixels.len == 0) {
        return null;
    }
    const cached_slot = backend.findCachedSlotForDraw(glyph.codepoint, glyph.width, glyph.height) orelse return null;
    const slot = @as(usize, cached_slot);
    const slot_index = slot * backend.atlas_slot_stride;
    if (slot_index + backend.atlas_slot_stride > backend.atlas_pixels.len) {
        return null;
    }
    const gw = @min(glyph.width, backend.atlas_cell_w);
    const gh = @min(glyph.height, backend.atlas_cell_h);
    if (gw == 0 or gh == 0) {
        return null;
    }
    if (slot >= backend.atlas_slot_has_alpha.len or !backend.atlas_slot_has_alpha[slot]) {
        return null;
    }
    return prepareTexturedGlyphCoords(backend, surface, glyph, cached_slot, gw, gh);
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render_core.TextStack.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn drawCursor(batch: render_core.RenderBatch, cursor: render_core.CursorDraw) void {
    const base_x: i32 = @as(i32, @intCast(cursor.cell_col)) * @as(i32, @intCast(batch.cell_px.width));
    const base_y: i32 = @as(i32, @intCast(cursor.cell_row)) * @as(i32, @intCast(batch.cell_px.height));
    const cell_w: u16 = batch.cell_px.width;
    const cell_h: u16 = batch.cell_px.height;
    const cursor_geom = render_core.TextStack.Metrics.cursorGeometry(.{ .cell_w_px = cell_w, .cell_h_px = cell_h, .baseline_px = @intCast(@max(cell_h - @divFloor(cell_h, 5), 1)) });

    switch (cursor.shape) {
        .block => drawRect(batch.surface_px, base_x, base_y, cell_w, cell_h, cursor.color),
        .beam => drawRect(batch.surface_px, base_x, base_y, cursor_geom.beam_w_px, cell_h, cursor.color),
        .underline => drawRect(batch.surface_px, base_x, base_y + @as(i32, @intCast(cell_h - cursor_geom.underline_h_px)), cell_w, cursor_geom.underline_h_px, cursor.color),
        .hollow_block => {
            const stroke = cursor_geom.hollow_stroke_px;
            drawRect(batch.surface_px, base_x, base_y, cell_w, stroke, cursor.color);
            drawRect(batch.surface_px, base_x, base_y + @as(i32, @intCast(cell_h - stroke)), cell_w, stroke, cursor.color);
            drawRect(batch.surface_px, base_x, base_y, stroke, cell_h, cursor.color);
            drawRect(batch.surface_px, base_x + @as(i32, @intCast(cell_w - stroke)), base_y, stroke, cell_h, cursor.color);
        },
    }
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

fn drawFillRects(backend: *Backend, surface: render_core.PixelSize, fills: []const render_core.FillRect) void {
    if (fills.len == 0) return;
    var vertices = ensureVertexCapacity(&backend.fill_vertices, fills.len * 4) orelse {
        for (fills) |fill| drawRect(surface, fill.x, fill.y, fill.width, fill.height, fill.color);
        return;
    };
    var count: usize = 0;
    for (fills) |fill| {
        _ = appendRectVertices(surface, vertices, &count, fill.x, fill.y, fill.width, fill.height, fill.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn sameColor(a: render_core.Rgba8, b: render_core.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn drawTexturedGlyph(backend: *const Backend, surface: render_core.PixelSize, glyph: render_core.GlyphQuad, atlas_slot: u32, gw: u16, gh: u16) void {
    const textured = prepareTexturedGlyphCoords(backend, surface, glyph, atlas_slot, gw, gh) orelse return;
    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4ub(textured.color.r, textured.color.g, textured.color.b, textured.color.a);
    c.glBegin(c.GL_QUADS);
    emitTexturedGlyph(textured);
    c.glEnd();
}

fn prepareTexturedGlyphCoords(backend: *const Backend, surface: render_core.PixelSize, glyph: render_core.GlyphQuad, atlas_slot: u32, gw: u16, gh: u16) ?TexturedGlyph {
    const clipped = clip_rect.clipRectTopOrigin(surface, glyph.x, glyph.y, gw, gh) orelse return null;
    const cols = @min(backend.capabilities().max_atlas_slots, Backend.AtlasTexCols);
    const slot = @as(usize, atlas_slot);
    const slot_x = (slot % cols) * @as(usize, backend.atlas_cell_w);
    const slot_y = (slot / cols) * @as(usize, backend.atlas_cell_h);

    const clip_dx: usize = @intCast(@max(clipped.x - glyph.x, 0));
    const clip_dy: usize = @intCast(@max(clipped.y - glyph.y, 0));
    const tex_u0 = @as(f32, @floatFromInt(slot_x + clip_dx)) / @as(f32, @floatFromInt(backend.atlas_tex_width));
    const tex_v0 = @as(f32, @floatFromInt(slot_y + clip_dy)) / @as(f32, @floatFromInt(backend.atlas_tex_height));
    const tex_u1 = @as(f32, @floatFromInt(slot_x + clip_dx + @as(usize, @intCast(clipped.w)))) / @as(f32, @floatFromInt(backend.atlas_tex_width));
    const tex_v1 = @as(f32, @floatFromInt(slot_y + clip_dy + @as(usize, @intCast(clipped.h)))) / @as(f32, @floatFromInt(backend.atlas_tex_height));

    return .{
        .clipped = clipped,
        .color = glyph.fg,
        .tex_u0 = tex_u0,
        .tex_v0 = tex_v0,
        .tex_u1 = tex_u1,
        .tex_v1 = tex_v1,
    };
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

test "backend executes valid batch and increments pass index" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const batch = render_core.RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    const first = try backend.renderBatch(batch);
    const second = try backend.renderBatch(batch);
    try std.testing.expectEqual(@as(u64, 1), first.pass_index);
    try std.testing.expectEqual(@as(u64, 2), second.pass_index);
}

test "backend returns validation errors from render-core helpers" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 1280, .height = 720 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const wrong_surface = render_core.RenderBatch{
        .surface_px = .{ .width = 1024, .height = 768 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 128, .rows = 48 },
    };

    try std.testing.expectError(error.SurfaceMismatch, backend.renderBatch(wrong_surface));
}

test "backend rejects operations after deinit" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    backend.deinit();

    const batch = render_core.RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    try std.testing.expectError(error.BackendClosed, backend.renderBatch(batch));
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
    const text_cache = render_core.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{ 'A' } }} };
    var shaped = try provider.shaper.shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
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
    try std.testing.expectEqual(@as(usize, 1), committed_scene);
    try std.testing.expect(backend.atlas_pixels.len > 0);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expect(slot_idx < backend.atlas_slot_has_alpha.len);
    try std.testing.expect(backend.atlas_slot_width[slot_idx] == 8);
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
