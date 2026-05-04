//! Responsibility: implement the OpenGL ES backend owner surface.
//! Ownership: unified renderer GLES backend owner module.
//! Reason: keep the package root boring while concrete rendering stays here.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../core_api.zig");
const clip_rect = @import("../shared/clip_rect.zig");
const c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("GLES2/gl2.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
const FtLibrary = c.FT_Library;
const FtFace = c.FT_Face;
const HbFont = *c.hb_font_t;

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

pub const FrameLayout = struct {
    cell_px: render_core.CellSize,
    grid: render_core.GridSize,
};

/// Primary export surface for the GLES renderer implementation.
pub const RenderGles = struct {
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

/// GLES backend implementation consuming render-core apis.
pub const Backend = struct {
    const MaxFallbackFonts = 24;

    config: render_core.BackendConfig,
    pass_count: u64 = 0,
    closed: bool = false,
    target_texture: ?u32 = null,
    owns_target_texture: bool = false,
    target_fbo: u32 = 0,
    fallback_font_paths: [MaxFallbackFonts]?[:0]const u8 = [_]?[:0]const u8{null} ** MaxFallbackFonts,
    fallback_font_paths_len: usize = 0,
    atlas_pixels: []u8 = &.{},
    atlas_cell_w: u16 = 0,
    atlas_cell_h: u16 = 0,
    atlas_slot_stride: usize = 0,
    atlas_slot_codepoint: []u21 = &.{},
    atlas_slot_width: []u16 = &.{},
    atlas_slot_height: []u16 = &.{},
    atlas_next_slot: u32 = 0,
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    resolve_counters: render_core.ResolveCounters = .{},
    resolve_stage: render_core.ResolveStage = .style_policy,

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
        if (self.atlas_slot_width.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_width);
            self.atlas_slot_width = &.{};
        }
        if (self.atlas_slot_height.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_height);
            self.atlas_slot_height = &.{};
        }
        if (self.ft_face != null) {
            if (self.hb_font != null) {
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
        if (self.owns_target_texture and self.target_texture != null and self.target_texture.? != texture and hasCurrentContext()) {
            var old_texture = self.target_texture.?;
            c.glDeleteTextures(1, @ptrCast(&old_texture));
        }
        self.target_texture = texture;
        self.owns_target_texture = false;
    }

    pub fn targetTexture(self: *const Backend) u32 {
        return self.target_texture orelse 0;
    }

    pub fn setFontPath(self: *Backend, font_path: ?[:0]const u8) void {
        self.config.font_path = font_path;
        self.resetLoadedFace();
    }

    pub fn setFallbackFontPaths(self: *Backend, paths: []const [:0]const u8) void {
        const n = @min(paths.len, MaxFallbackFonts);
        self.fallback_font_paths_len = n;
        var i: usize = 0;
        while (i < n) : (i += 1) self.fallback_font_paths[i] = paths[i];
        while (i < MaxFallbackFonts) : (i += 1) self.fallback_font_paths[i] = null;
        self.resetLoadedFace();
    }

    pub fn setFontSizePx(self: *Backend, font_size_px: u16) void {
        self.config.font_size_px = @max(font_size_px, 1);
        self.resetLoadedFace();
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
        self.config.surface_px = surface_px;
        self.config.cell_px = cell_px;
        if (surface_changed and self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
            self.resizeOwnedTargetTexture();
        }
    }

    /// Validate and render a batch against backend config/capability.
    pub fn renderBatch(self: *Backend, batch: render_core.RenderBatch) BackendError!RenderReport {
        if (self.closed) return error.BackendClosed;
        const rc = render_core.init(self.config, self.capabilities());
        try rc.validateRenderBatch(batch);
        const committed_uploads = try self.uploadAtlas(batch);
        if (hasCurrentContext()) {
            if (self.target_texture == null and self.config.target_texture != 0) {
                self.target_texture = self.config.target_texture;
            }
            try self.ensureOwnedTargetTexture();
            if (self.target_texture == null) return error.TargetTextureUnset;
            try self.beginTargetPass();
            defer self.endTargetPass();
            drawBatch(self, batch);
        } else if (!builtin.is_test) {
            return error.NoContext;
        }
        self.pass_count += 1;
        return .{
            .stats = rc.summarizeRenderBatch(batch),
            .pass_index = self.pass_count,
            .atlas_uploads_committed = committed_uploads,
        };
    }

    /// Build batch from VT state and render it.
    pub fn renderFrameState(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
    ) BackendError!RenderReport {
        try self.resize(surface_px, cell_px);
        const rc = render_core.init(self.config, self.capabilities());
        var owned = try rc.vtStateToRenderBatch(
            allocator,
            state,
            surface_px,
            cell_px,
        );
        defer owned.deinit();
        return self.renderBatch(owned.batch);
    }

    pub fn prepareFrameState(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
    ) BackendError!render_core.OwnedRenderBatch {
        try self.resize(surface_px, cell_px);
        const rc = render_core.init(self.config, self.capabilities());
        return rc.vtStateToRenderBatch(
            allocator,
            state,
            surface_px,
            cell_px,
        );
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

    fn deriveCellSize(self: *Backend) render_core.CellSize {
        const font_px = @max(self.config.font_size_px, 1);

        if (self.config.font_path) |font_path| {
            var lib: FtLibrary = undefined;
            if (c.FT_Init_FreeType(&lib) == 0) {
                defer _ = c.FT_Done_FreeType(lib);
                var face: FtFace = undefined;
                if (c.FT_New_Face(lib, font_path, 0, &face) == 0) {
                    defer _ = c.FT_Done_Face(face);
                    if (c.FT_Set_Pixel_Sizes(face, 0, font_px) == 0) {
                        return cellSizeFromFace(face, self.config.font_size_px);
                    }
                }
            }
        }

        var i: usize = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            const font_path = self.fallback_font_paths[i] orelse continue;
            var lib: FtLibrary = undefined;
            if (c.FT_Init_FreeType(&lib) != 0) continue;
            defer _ = c.FT_Done_FreeType(lib);
            var face: FtFace = undefined;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
            defer _ = c.FT_Done_Face(face);
            if (c.FT_Set_Pixel_Sizes(face, 0, font_px) != 0) continue;
            return cellSizeFromFace(face, self.config.font_size_px);
        }

        return .{
            .width = @max(@divFloor(font_px, 2), 1),
            .height = font_px,
        };
    }

    fn uploadAtlas(self: *Backend, batch: render_core.RenderBatch) BackendError!usize {
        if (batch.atlas_uploads.len == 0) return 0;
        try self.ensureAtlasStorage();
        var committed: usize = 0;
        for (batch.atlas_uploads) |upload| {
            if (self.findCachedSlot(upload.codepoint, upload.width, upload.height) != null) continue;
            const slot = self.allocateSlot() orelse continue;
            self.rasterizeSlot(slot, upload.codepoint, upload.width, upload.height);
            self.markSlotCached(slot, upload.codepoint, upload.width, upload.height);
            committed += 1;
        }
        return committed;
    }

    fn ensureAtlasStorage(self: *Backend) BackendError!void {
        const need_w = @max(self.config.cell_px.width, 1);
        const need_h = @max(self.config.cell_px.height, 1);
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
        if (self.atlas_slot_width.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_width);
            self.atlas_slot_width = &.{};
        }
        if (self.atlas_slot_height.len > 0) {
            std.heap.c_allocator.free(self.atlas_slot_height);
            self.atlas_slot_height = &.{};
        }
        const max_slots = self.capabilities().max_atlas_slots;
        self.atlas_pixels = try std.heap.c_allocator.alloc(u8, need_stride * @as(usize, max_slots));
        @memset(self.atlas_pixels, 0);
        self.atlas_slot_codepoint = try std.heap.c_allocator.alloc(u21, max_slots);
        @memset(self.atlas_slot_codepoint, 0);
        self.atlas_slot_width = try std.heap.c_allocator.alloc(u16, max_slots);
        @memset(self.atlas_slot_width, 0);
        self.atlas_slot_height = try std.heap.c_allocator.alloc(u16, max_slots);
        @memset(self.atlas_slot_height, 0);
        self.atlas_cell_w = need_w;
        self.atlas_cell_h = need_h;
        self.atlas_slot_stride = need_stride;
        self.atlas_next_slot = 0;
    }

    fn slotCached(self: *const Backend, slot: u32, codepoint: u21, width: u16, height: u16) bool {
        const idx = @as(usize, slot);
        if (idx >= self.atlas_slot_codepoint.len) return false;
        return self.atlas_slot_codepoint[idx] == codepoint and
            self.atlas_slot_width[idx] == width and
            self.atlas_slot_height[idx] == height;
    }

    fn findCachedSlot(self: *const Backend, codepoint: u21, width: u16, height: u16) ?u32 {
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

    fn markSlotCached(self: *Backend, slot: u32, codepoint: u21, width: u16, height: u16) void {
        const idx = @as(usize, slot);
        if (idx >= self.atlas_slot_codepoint.len) return;
        self.atlas_slot_codepoint[idx] = codepoint;
        self.atlas_slot_width[idx] = width;
        self.atlas_slot_height[idx] = height;
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
        if (self.ft_face != null) return true;
        var lib: FtLibrary = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return false;
        var face: FtFace = undefined;

        if (self.config.font_path) |font_path| {
            if (c.FT_New_Face(lib, font_path, 0, &face) == 0) {
                _ = c.FT_Set_Pixel_Sizes(face, self.atlas_cell_w, self.atlas_cell_h);
                self.ft_lib = lib;
                self.ft_face = face;
                self.hb_font = c.hb_ft_font_create(face, null);
                self.resolve_stage = .loaded_exact_match;
                return true;
            }
        }

        var loaded = false;
        var i: usize = 0;
        while (i < self.fallback_font_paths_len) : (i += 1) {
            const font_path = self.fallback_font_paths[i] orelse continue;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) == 0) {
                loaded = true;
                self.resolve_stage = .discovery_fallback;
                self.resolve_counters.fallback_hits += 1;
                break;
            }
        }

        if (!loaded) {
            _ = c.FT_Done_FreeType(lib);
            self.resolve_stage = .missing_glyph;
            self.resolve_counters.missing_glyphs += 1;
            return false;
        }

        _ = c.FT_Set_Pixel_Sizes(face, self.atlas_cell_w, self.atlas_cell_h);
        self.ft_lib = lib;
        self.ft_face = face;
        self.hb_font = c.hb_ft_font_create(face, null);
        return true;
    }

    fn resetLoadedFace(self: *Backend) void {
        if (self.ft_face != null) {
            if (self.hb_font != null) {
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

    fn rasterizeFromFont(self: *Backend, dst: []u8, codepoint: u21, gw: u16, gh: u16) bool {
        if (!self.ensureFont()) return false;
        const face = self.ft_face.?;
        if (c.FT_Set_Pixel_Sizes(face, self.atlas_cell_w, self.atlas_cell_h) != 0) return false;
        const glyph_id = shapeGlyphId(self.hb_font, face, codepoint);
        if (glyph_id == 0) {
            self.resolve_stage = .missing_glyph;
            self.resolve_counters.missing_glyphs += 1;
            return false;
        }
        if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_RENDER) != 0) {
            self.resolve_stage = .missing_glyph;
            self.resolve_counters.missing_glyphs += 1;
            return false;
        }
        const glyph = face.*.glyph;
        if (glyph == null) return false;
        const bitmap = glyph.*.bitmap;
        if (bitmap.buffer == null or bitmap.width <= 0 or bitmap.rows <= 0) return false;
        const bw: usize = @intCast(bitmap.width);
        const bh: usize = @intCast(bitmap.rows);
        const pitch_abs: usize = @intCast(@abs(bitmap.pitch));
        const pitch_is_negative = bitmap.pitch < 0;
        const advance_px: i32 = @intCast(@divTrunc(glyph.*.advance.x, 64));
        const ascender_px: i32 = @intCast(@divTrunc(face.*.size.*.metrics.ascender, 64));
        const baseline_y: i32 = std.math.clamp(ascender_px, 0, @as(i32, @intCast(gh)));
        const origin_x: i32 = @divTrunc(@as(i32, @intCast(gw)) - advance_px, 2);
        const bmp_left: i32 = glyph.*.bitmap_left;
        const bmp_top: i32 = glyph.*.bitmap_top;

        var wrote_any = false;
        for (0..bh) |yy| {
            for (0..bw) |xx| {
                const dx_i = origin_x + bmp_left + @as(i32, @intCast(xx));
                const dy_i = baseline_y - bmp_top + @as(i32, @intCast(yy));
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
        if (!wrote_any) {
            // Fallback placement: center bitmap box in cell when metric placement clips out.
            const off_x: i32 = @divTrunc(@as(i32, @intCast(gw)) - @as(i32, @intCast(@min(bw, gw))), 2);
            const off_y: i32 = @divTrunc(@as(i32, @intCast(gh)) - @as(i32, @intCast(@min(bh, gh))), 2);
            for (0..bh) |yy| {
                for (0..bw) |xx| {
                    const dx_i = off_x + @as(i32, @intCast(xx));
                    const dy_i = off_y + @as(i32, @intCast(yy));
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
        }
        self.resolve_counters.shaped_clusters += 1;
        return true;
    }
};

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

fn cellSizeFromFace(face: FtFace, font_size_px: u16) render_core.CellSize {
    const metrics = face.*.size.*.metrics;
    const height_px = metricCeilPx(metrics.height, font_size_px);

    var width_px = metricCeilPx(metrics.max_advance, 0);
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0 and face.*.glyph != null) {
        const advance_x = face.*.glyph.*.advance.x;
        width_px = @max(width_px, metricCeilPx(advance_x, 0));
    }

    return .{
        .width = @max(width_px, 1),
        .height = @max(height_px, 1),
    };
}

fn metricCeilPx(metric_26_6: anytype, fallback: u16) u16 {
    const raw: i32 = @intCast(metric_26_6);
    if (raw <= 0) return @max(fallback, 1);
    return @intCast(@max(@divTrunc(raw + 63, 64), 1));
}

fn hasCurrentContext() bool {
    return c.glGetString(c.GL_VERSION) != null;
}

fn drawBatch(backend: *const Backend, batch: render_core.RenderBatch) void {
    c.glViewport(0, 0, @as(c_int, @intCast(batch.surface_px.width)), @as(c_int, @intCast(batch.surface_px.height)));
    // Clear the full target so stale pixels do not survive grid width/height changes.
    c.glDisable(c.GL_SCISSOR_TEST);
    c.glClearColor(0.0, 0.0, 0.0, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glDisable(c.GL_DEPTH_TEST);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    defer c.glDisable(c.GL_BLEND);

    for (batch.fills) |fill| drawRect(batch.surface_px, fill.x, fill.y, fill.width, fill.height, fill.color);
    for (batch.glyphs) |glyph| drawGlyph(backend, batch.surface_px, glyph);
    if (batch.cursor) |cursor| drawCursor(batch, cursor);
}

fn drawGlyph(backend: *const Backend, surface: render_core.PixelSize, glyph: render_core.GlyphQuad) void {
    if (backend.atlas_pixels.len == 0) {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
        return;
    }
    const cached_slot = backend.findCachedSlot(glyph.codepoint, glyph.width, glyph.height) orelse {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
        return;
    };
    const slot = @as(usize, cached_slot);
    const slot_index = slot * backend.atlas_slot_stride;
    if (slot_index + backend.atlas_slot_stride > backend.atlas_pixels.len) {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
        return;
    }
    const src = backend.atlas_pixels[slot_index .. slot_index + backend.atlas_slot_stride];
    const gw = @min(glyph.width, backend.atlas_cell_w);
    const gh = @min(glyph.height, backend.atlas_cell_h);
    if (gw == 0 or gh == 0) {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
        return;
    }
    var drew_any = false;
    for (0..gh) |yy| {
        for (0..gw) |xx| {
            const idx = yy * @as(usize, backend.atlas_cell_w) + xx;
            const alpha = src[idx];
            if (alpha == 0) continue;
            drew_any = true;
            var color = glyph.fg;
            color.a = @intCast((@as(u16, color.a) * @as(u16, alpha)) / 255);
            drawRect(surface, glyph.x + @as(i32, @intCast(xx)), glyph.y + @as(i32, @intCast(yy)), 1, 1, color);
        }
    }
    if (!drew_any) {
        drawRect(surface, glyph.x, glyph.y, glyph.width, glyph.height, glyph.fg);
    }
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
    const beam_w: u16 = if (cell_w >= 2) 2 else 1;
    const underline_h: u16 = if (cell_h >= 2) 2 else 1;

    switch (cursor.shape) {
        .block => drawRect(batch.surface_px, base_x, base_y, cell_w, cell_h, cursor.color),
        .beam => drawRect(batch.surface_px, base_x, base_y, beam_w, cell_h, cursor.color),
        .underline => drawRect(batch.surface_px, base_x, base_y + @as(i32, @intCast(cell_h - underline_h)), cell_w, underline_h, cursor.color),
        .hollow_block => {
            drawRect(batch.surface_px, base_x, base_y, cell_w, 1, cursor.color);
            drawRect(batch.surface_px, base_x, base_y + @as(i32, @intCast(cell_h - 1)), cell_w, 1, cursor.color);
            drawRect(batch.surface_px, base_x, base_y, 1, cell_h, cursor.color);
            drawRect(batch.surface_px, base_x + @as(i32, @intCast(cell_w - 1)), base_y, 1, cell_h, cursor.color);
        },
    }
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

test "backend executes valid batch and reports stats" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 10, .height = 20 },
    });
    defer backend.deinit();

    const fills = [_]render_core.FillRect{
        .{
            .x = 0,
            .y = 0,
            .width = 10,
            .height = 20,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        },
    };
    const batch = render_core.RenderBatch{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 10, .height = 20 },
        .grid = .{ .cols = 80, .rows = 30 },
        .fills = &fills,
    };

    const report = try backend.renderBatch(batch);
    try std.testing.expectEqual(@as(usize, 1), report.stats.fills);
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
}

test "backend accepts backend-owned atlas uploads" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 10, .height = 20 },
    });
    defer backend.deinit();

    const uploads = [_]render_core.AtlasUpload{
        .{ .codepoint = 'A', .width = 10, .height = 20 },
    };
    const batch = render_core.RenderBatch{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 10, .height = 20 },
        .grid = .{ .cols = 80, .rows = 30 },
        .atlas_uploads = &uploads,
    };

    const report = try backend.renderBatch(batch);
    try std.testing.expectEqual(@as(usize, 1), report.stats.atlas_uploads);
}

test "backend resize updates config dimensions" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 320, .height = 240 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    try backend.resize(.{ .width = 1920, .height = 1080 }, .{ .width = 12, .height = 24 });
    try std.testing.expectEqual(@as(u16, 1920), backend.config.surface_px.width);
    try std.testing.expectEqual(@as(u16, 24), backend.config.cell_px.height);
}
