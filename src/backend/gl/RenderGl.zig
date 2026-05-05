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
    pub fn renderBatch(self: *Backend, batch: render_core.RenderBatch) BackendError!RenderReport {
        if (self.closed) return error.BackendClosed;
        const rc = render_core.init(self.config, self.capabilities());
        try rc.validateRenderBatch(batch);
        const committed_uploads = try self.uploadAtlas(batch);
        if (hasCurrentContext()) {
            if (self.target_texture == null and self.config.target_texture != 0) {
                self.target_texture = self.config.target_texture;
                self.surface_epoch +%= 1;
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

    pub fn prepareRetainedFrameState(
        self: *Backend,
        allocator: std.mem.Allocator,
        state: SurfaceFrameData,
        surface_px: render_core.PixelSize,
        cell_px: render_core.CellSize,
    ) BackendError!render_core.OwnedRenderBatch {
        try self.resize(surface_px, cell_px);
        return self.retained_frame.prepareBatch(
            std.heap.c_allocator,
            allocator,
            state,
            surface_px,
            cell_px,
            render_core.defaultTheme,
            self.capabilities(),
        );
    }

    fn uploadAtlas(self: *Backend, batch: render_core.RenderBatch) BackendError!usize {
        if (batch.atlas_uploads.len == 0) return 0;
        const start_ns = monotonicNs();
        try self.ensureAtlasStorage();
        if (hasCurrentContext()) try self.ensureAtlasTexture();
        var committed: usize = 0;
        var fast_hits: usize = 0;
        var resolved_hits: usize = 0;
        for (batch.atlas_uploads) |upload| {
            if (self.findCachedSlotForDraw(upload.codepoint, upload.width, upload.height) != null) {
                fast_hits += 1;
                continue;
            }
            const key = self.resolveGlyphKey(upload.codepoint) orelse missingGlyphKey(upload.codepoint);
            if (self.findCachedSlot(key, upload.width, upload.height) != null) {
                resolved_hits += 1;
                continue;
            }
            const slot = self.allocateSlot() orelse continue;
            self.rasterizeSlot(slot, upload.codepoint, upload.width, upload.height);
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

    fn rasterizeSlot(self: *Backend, slot: u32, codepoint: u21, width: u16, height: u16) void {
        if (self.atlas_pixels.len == 0) return;
        const slot_index = @as(usize, slot) * self.atlas_slot_stride;
        const dst = self.atlas_pixels[slot_index .. slot_index + self.atlas_slot_stride];
        @memset(dst, 0);
        const gw = @min(width, self.atlas_cell_w);
        const gh = @min(height, self.atlas_cell_h);
        if (self.rasterizeFromFont(dst, codepoint, gw, gh)) {
            self.markSlotAlpha(slot, dst, gw, gh);
            self.resolve_stage = .loaded_exact_match;
            return;
        }
        self.resolve_stage = .missing_glyph;
        rasterizeFallbackGlyph(dst, self.atlas_cell_w, self.atlas_cell_h, codepoint, gw, gh);
        self.markSlotAlpha(slot, dst, gw, gh);
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

    fn rasterizeFromFont(self: *Backend, dst: []u8, codepoint: u21, gw: u16, gh: u16) bool {
        if (!self.ensureFont()) return false;
        if (self.ft_face) |face| {
            if (self.rasterizeGlyphFromFace(dst, self.hb_font, face, codepoint, gw, gh)) {
                self.resolve_stage = .loaded_exact_match;
                return true;
            }
        }

        const lib = self.ft_lib orelse return false;
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

            if (self.rasterizeGlyphFromFace(dst, fallback_hb, face, codepoint, gw, gh)) {
                self.resolve_stage = .discovery_fallback;
                self.resolve_counters.fallback_hits += 1;
                return true;
            }
        }

        self.resolve_stage = .missing_glyph;
        self.resolve_counters.fallback_misses += 1;
        self.resolve_counters.missing_glyphs += 1;
        return false;
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

    fn rasterizeGlyphFromFace(self: *Backend, dst: []u8, hb_font: ?HbFont, face: FtFace, codepoint: u21, gw: u16, gh: u16) bool {
        if (!setFacePixelHeight(self, face)) return false;
        const glyph_id = shapeGlyphId(hb_font, face, codepoint);
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
        const baseline_y = computeBaselineFromFace(face, gh);
        const bmp_left: i32 = glyph.*.bitmap_left;
        const bmp_top: i32 = glyph.*.bitmap_top;

        for (0..bh) |yy| {
            for (0..bw) |xx| {
                const dx_i = @max(0, bmp_left) + @as(i32, @intCast(xx));
                const dy_i = baseline_y - bmp_top + @as(i32, @intCast(yy));
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
        return true;
    }

    fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
        const metrics = face.*.size.*.metrics;
        const ascender_raw = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const descent_raw = @abs(@as(f32, @floatFromInt(metrics.descender)) / 64.0);
        const line_height_raw = @max(@as(f32, @floatFromInt(metrics.height)) / 64.0, 1.0);
        const line_gap_raw = @max(0.0, line_height_raw - (ascender_raw + descent_raw));
        const baseline_from_top_raw = ascender_raw + line_gap_raw / 2.0;
        const scaled_baseline = baseline_from_top_raw * (@as(f32, @floatFromInt(cell_h)) / line_height_raw);
        const rounded = @as(i32, @intFromFloat(std.math.round(scaled_baseline)));
        return std.math.clamp(rounded, 1, @as(i32, @intCast(cell_h)));
    }

    fn deriveCellSize(self: *Backend) render_core.CellSize {
        if (self.ensurePrimaryFont()) {
            return cellSizeFromFace(self.ft_face.?, self.config.font_size_px);
        }
        if (self.ft_lib) |lib| {
            var i: usize = 0;
            while (i < self.fallback_font_paths_len) : (i += 1) {
                const font_path = self.fallback_font_paths[i] orelse continue;
                var face: FtFace = undefined;
                if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
                defer _ = c.FT_Done_Face(face);
                if (!setFacePixelHeight(self, face)) continue;
                return cellSizeFromFace(face, self.config.font_size_px);
            }
        }

        const font_px = @max(self.config.font_size_px, 1);
        return .{
            .width = @max(@divFloor(font_px, 2), 1),
            .height = font_px,
        };
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

fn setFacePixelHeight(self: *const Backend, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
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
