
const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../../render.zig").Render;
const special_sprite = @import("special_sprite.zig");
const shared_text_cache = @import("../../shared/text_cache.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

const FtLibrary = c_api.FtLibrary;
const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;

pub const primary_face_id: u32 = 1;

fn lockFt(self: anytype) void {
    self.ft_mutex.lock();
}

fn unlockFt(self: anytype) void {
    self.ft_mutex.unlock();
}

pub const ResolvedGlyphKey = struct {
    codepoint: u21,
    face_id: u32,
    glyph_id: u32,
};

const ClusterWindow = struct {
    start: u32,
    end: u32,

    fn init(run: render.ResolvedRun, clusters_len: usize) ClusterWindow {
        const start = run.run.cluster_start;
        const end = @min(start + run.run.cluster_count, @as(u32, @intCast(clusters_len)));
        return .{ .start = start, .end = end };
    }

    fn empty(self: ClusterWindow) bool {
        return self.end <= self.start;
    }

    fn len(self: ClusterWindow) u32 {
        return self.end - self.start;
    }

    fn startIndex(self: ClusterWindow) usize {
        return @intCast(self.start);
    }

    fn endIndex(self: ClusterWindow) usize {
        return @intCast(self.end);
    }

    fn slice(self: ClusterWindow, clusters: []const render.CellCluster) []const render.CellCluster {
        return clusters[self.startIndex()..self.endIndex()];
    }
};

const ShapeRunInput = struct {
    codepoints: std.ArrayList(u32),
    cluster_map: std.ArrayList(u32),

    fn deinit(self: *ShapeRunInput, allocator: std.mem.Allocator) void {
        self.cluster_map.deinit(allocator);
        self.codepoints.deinit(allocator);
        self.* = undefined;
    }
};

pub fn providerHasCodepoint(comptime Backend: type, ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32) bool {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    if (useDeterministicTestTextFallback(backend)) return codepoint != 0;
    if (!ensureFont(backend)) return false;
    lockFt(backend);
    defer unlockFt(backend);
    const shaped_face = acquireShapingFaceLocked(backend, face_id) orelse return false;
    return c.FT_Get_Char_Index(shaped_face.face, codepoint) != 0;
}

pub fn providerHasCellText(comptime Backend: type, ctx: *anyopaque, face_id: render.FontFaceId, text: render.CellText) bool {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const key = shared_text_cache.FaceTextKey{ .face_id = face_id.value, .text_hash = shared_text_cache.hashCellText(text) };
    const entry = backend.face_text_cache.map.getOrPut(key) catch return uncachedProviderHasCellText(Backend, ctx, face_id, text);
    if (entry.found_existing) {
        backend.resolve_counters.face_cache_hits += 1;
        if (backend.active_resolve) |obs| obs.counters.face_cache_hits += 1;
        return entry.value_ptr.*;
    }

    backend.resolve_counters.face_checks += 1;
    if (backend.active_resolve) |obs| obs.counters.face_checks += 1;
    const result = uncachedProviderHasCellText(Backend, ctx, face_id, text);
    entry.value_ptr.* = result;
    return result;
}

fn uncachedProviderHasCellText(comptime Backend: type, ctx: *anyopaque, face_id: render.FontFaceId, text: render.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp == 0xfe0e or cp == 0xfe0f) continue;
        if (!providerHasCodepoint(Backend, ctx, face_id, cp)) return false;
    }
    return true;
}

pub fn providerShapeRun(
    comptime Backend: type,
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const window = ClusterWindow.init(run, clusters.len);
    if (window.empty()) {
        return .{ .allocator = allocator, .run = run, .glyphs = try allocator.alloc(render.GlyphInstance, 0) };
    }

    backend.resolve_counters.shape_requests += 1;
    if (backend.active_resolve) |obs| obs.counters.shape_requests += 1;
    const shape_key = shared_text_cache.ShapeRunKey{
        .face_id = run.run.font.face_id.value,
        .run_hash = shared_text_cache.hashRunText(text_cache_view, window.slice(clusters)),
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    if (try backend.shape_run_cache.getOwnedRun(allocator, shape_key, run)) |cached| {
        backend.resolve_counters.shape_cache_hits += 1;
        if (backend.active_resolve) |obs| obs.counters.shape_cache_hits += 1;
        return cached;
    }

    var shaped = if (!c_api.supports_complex_shaping)
        try fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, window)
    else if (try shapePlainAsciiRun(backend, allocator, run, text_cache_view, clusters, cell_metrics, window)) |ascii|
        ascii
    else
        try shapeRunViaProviderOrFallback(backend, allocator, run, text_cache_view, clusters, cell_metrics, window);
    errdefer shaped.deinit();
    try backend.shape_run_cache.putRun(shape_key, shaped);
    return shaped;
}

fn shapeRunViaProviderOrFallback(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    window: ClusterWindow,
) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    var input = try gatherShapeRunInput(allocator, text_cache_view, clusters, window);
    defer input.deinit(allocator);
    if (input.codepoints.items.len == 0) return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, window);

    const buffer = c.hb_buffer_create() orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, window);
    };
    defer c.hb_buffer_destroy(buffer);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_buffer_add_utf32(buffer, input.codepoints.items.ptr, @intCast(input.codepoints.items.len), 0, @intCast(input.codepoints.items.len));
    c.hb_buffer_guess_segment_properties(buffer);

    if (!ensureFont(backend)) {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, window);
    }

    return try shapeRunViaProvider(
        backend,
        allocator,
        run,
        clusters,
        cell_metrics,
        buffer,
        input.cluster_map.items,
    ) orelse fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, window);
}

fn shapeRunViaProvider(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    buffer: ?*c.hb_buffer_t,
    cluster_map: []const u32,
) anyerror!?render.Text.ShapeRun.OwnedShapedRun {
    lockFt(backend);
    defer unlockFt(backend);
    const shaped_face = acquireShapingFaceLocked(backend, run.run.font.face_id) orelse return null;
    const hb_font = shaped_face.hb_font orelse return null;
    c.hb_shape(hb_font, buffer, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);
    if (infos == null or positions == null or glyph_count == 0) return null;

    return buildProviderShapedRun(allocator, run, clusters, cell_metrics, shaped_face.face, infos, positions, glyph_count, cluster_map);
}

fn shapePlainAsciiRun(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    window: ClusterWindow,
) anyerror!?render.Text.ShapeRun.OwnedShapedRun {
    if (run.features_id != 0) return null;
    if (run.run.font.presentation == .emoji) return null;

    for (window.slice(clusters)) |cluster| {
        if (cluster.cell_span != 1) return null;
        if (cluster.presentation == .emoji) return null;
        const text = textForCluster(text_cache_view, cluster);
        if (text.codepoints.len != 1) return null;
        if (text.codepoints[0] != cluster.first_cp) return null;
        if (!isPlainAsciiCodepoint(cluster.first_cp)) return null;
    }

    if (!ensureFont(backend)) return null;

    const glyphs = try allocator.alloc(render.GlyphInstance, window.len());
    var keep_glyphs = false;
    defer if (!keep_glyphs) allocator.free(glyphs);

    lockFt(backend);
    defer unlockFt(backend);
    const shaped_face = acquireShapingFaceLocked(backend, run.run.font.face_id) orelse return null;
    const face = shaped_face.face;

    for (window.slice(clusters), 0..) |cluster, idx| {
        const glyph_id = c.FT_Get_Char_Index(face, cluster.first_cp);
        if (glyph_id == 0) return null;
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = glyph_id,
            .cluster_index = window.start + @as(u32, @intCast(idx)),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = glyphAdvanceFromFace(backend, face, glyph_id, cell_metrics),
        };
    }

    keep_glyphs = true;
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
}

pub fn providerGlyphId(self: anytype, face_id: render.FontFaceId, codepoint: u32) u32 {
    if (useDeterministicTestTextFallback(self)) return codepoint;
    if (!ensureFont(self)) return 0;
    lockFt(self);
    defer unlockFt(self);
    const shaped_face = acquireShapingFaceLocked(self, face_id) orelse return 0;
    return shapeGlyphId(shaped_face.hb_font, shaped_face.face, @intCast(codepoint));
}

pub fn providerGlyphAdvance(self: anytype, face_id: render.FontFaceId, glyph_id: u32, cell_metrics: render.CellMetrics) f32 {
    const fallback: f32 = @floatFromInt(cell_metrics.cell_w_px);
    if (glyph_id == 0) return fallback;
    if (!ensureFont(self)) return fallback;
    lockFt(self);
    defer unlockFt(self);
    const shaped_face = acquireShapingFaceLocked(self, face_id) orelse return fallback;
    return glyphAdvanceFromFace(self, shaped_face.face, glyph_id, cell_metrics);
}

pub fn providerLookupGlyph(comptime Backend: type, ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const key = shared_text_cache.GlyphCellKey{
        .face_id = face_id.value,
        .codepoint = codepoint,
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    const entry = backend.glyph_cell_cache.map.getOrPut(key) catch return uncachedProviderLookupGlyph(backend, face_id, codepoint, cell_metrics);
    if (!entry.found_existing) entry.value_ptr.* = uncachedProviderLookupGlyph(backend, face_id, codepoint, cell_metrics);
    return entry.value_ptr.*;
}

fn uncachedProviderLookupGlyph(backend: anytype, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
    const glyph_id = providerGlyphId(backend, face_id, codepoint);
    return .{
        .glyph_id = glyph_id,
        .advance_px = providerGlyphAdvance(backend, face_id, glyph_id, cell_metrics),
    };
}

pub fn providerRasterizeSprite(
    comptime Backend: type,
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render.SpriteRasterRequest,
) anyerror!render.Text.Rasterizer.RasterSpriteOutput {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const width = @max(req.width_px, 1);
    const height = @max(req.height_px, 1);
    const pixels = try allocator.alloc(u8, rasterPixelCount(width, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    if (tryRasterizeProviderSpecialCase(backend, pixels, width, height, req)) {
        return providerSpriteOutput(allocator, req, width, height, pixels);
    }

    var pen_x: f32 = 0;
    for (req.group.glyphs, 0..) |glyph, glyph_idx| {
        const x_px = @as(i32, @intFromFloat(std.math.floor(pen_x + glyph.x_offset_px)));
        const y_px = @as(i32, @intFromFloat(std.math.floor(glyph.y_offset_px)));
        _ = rasterizeProviderGlyph(backend, pixels, width, height, req.baseline_px, glyph.face_id, glyph.glyph_id, x_px, y_px, @intCast(glyph_idx));
        pen_x += glyph.x_advance_px;
    }
    return providerSpriteOutput(allocator, req, width, height, pixels);
}

pub fn ensurePrimaryFont(self: anytype) bool {
    lockFt(self);
    defer unlockFt(self);
    if (self.ft_face != null) return true;
    if (!ensureFreeTypeLibraryLocked(self)) return false;
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
    self.hb_font = c_api.createHbFont(face);
    return true;
}

pub fn ensureFont(self: anytype) bool {
    if (ensurePrimaryFont(self)) {
        self.resolve_stage = .loaded_exact_match;
        if (self.active_resolve) |obs| obs.stage = .loaded_exact_match;
        return true;
    }

    for (0..self.fallback_font_paths_len) |i| {
        if (self.fallback_font_paths[i] == null) continue;
        if (ensureFallbackFace(self, @intCast(i))) |_| {
            self.resolve_stage = .discovery_fallback;
            if (self.active_resolve) |obs| obs.stage = .discovery_fallback;
            return true;
        }
    }

    self.resolve_stage = .missing_glyph;
    self.resolve_counters.missing_glyphs += 1;
    if (self.active_resolve) |obs| {
        obs.stage = .missing_glyph;
        obs.counters.missing_glyphs += 1;
    }
    return false;
}

pub fn resetLoadedFace(self: anytype) void {
    lockFt(self);
    defer unlockFt(self);
    resetFallbackFaces(self);
    if (self.ft_face != null) {
        c_api.destroyHbFont(self.hb_font);
        self.hb_font = null;
        _ = c.FT_Done_Face(self.ft_face.?);
        self.ft_face = null;
    }
    if (self.ft_lib != null) {
        _ = c.FT_Done_FreeType(self.ft_lib.?);
        self.ft_lib = null;
    }
}

pub fn resizeLoadedFaces(self: anytype) void {
    lockFt(self);
    defer unlockFt(self);
    if (self.ft_face) |face| _ = setFacePixelHeight(self, face);
    for (self.fallback_faces) |face_opt| {
        if (face_opt) |face| _ = setFacePixelHeight(self, face);
    }
}

pub fn ensureFallbackFace(self: anytype, fallback_index: u32) ?FtFace {
    lockFt(self);
    defer unlockFt(self);
    const slot = fallbackSlot(self, fallback_index) orelse return null;
    if (self.fallback_faces[slot]) |face| return face;
    if (!ensureFreeTypeLibraryLocked(self)) return null;
    const font_path = self.fallback_font_paths[slot] orelse return null;
    const lib = self.ft_lib orelse return null;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return null;
    if (!setFacePixelHeight(self, face)) {
        _ = c.FT_Done_Face(face);
        return null;
    }
    self.fallback_faces[slot] = face;
    self.fallback_hb_fonts[slot] = c_api.createHbFont(face);
    return face;
}

pub fn deriveCellMetrics(self: anytype) render.CellMetrics {
    if (ensurePrimaryFont(self)) {
        lockFt(self);
        defer unlockFt(self);
        return cellMetricsFromFace(self.ft_face.?, self.config.font_size_px);
    }
    lockFt(self);
    defer unlockFt(self);
    if (ensureFreeTypeLibraryLocked(self)) {
        const lib = self.ft_lib.?;
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
    return render.Text.Metrics.defaultCellMetrics(self.config.font_size_px);
}

pub fn configuredCellMetrics(self: anytype) render.CellMetrics {
    const cell_w = @max(self.config.cell_px.width, 1);
    const cell_h = @max(self.config.cell_px.height, 1);
    var baseline = @as(i32, @intCast(@max(cell_h - @divFloor(cell_h, 5), 1)));
    if (ensurePrimaryFont(self)) {
        lockFt(self);
        defer unlockFt(self);
        baseline = computeBaselineFromFace(self.ft_face.?, cell_h);
    }
    return .{
        .cell_w_px = cell_w,
        .cell_h_px = cell_h,
        .baseline_px = @intCast(std.math.clamp(baseline, 1, @as(i32, @intCast(cell_h)))),
        .box_thickness_px = render.Text.Metrics.defaultBoxThickness(cell_h),
    };
}

pub fn deriveCellSize(self: anytype) render.CellSize {
    const cell = deriveCellMetrics(self);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

pub fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return render.Text.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
}

fn fallbackFaceId(index: u32) u32 {
    return index + 2;
}

fn ensureFreeTypeLibraryLocked(self: anytype) bool {
    if (self.ft_lib != null) return true;
    var lib: FtLibrary = undefined;
    if (c.FT_Init_FreeType(&lib) != 0) return false;
    self.ft_lib = lib;
    return true;
}

fn fallbackProviderShapeRun(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    window: ClusterWindow,
) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    const glyphs = try allocator.alloc(render.GlyphInstance, window.len());
    errdefer allocator.free(glyphs);
    for (window.slice(clusters), 0..) |cluster, idx| {
        const glyph_id = providerGlyphId(backend, run.run.font.face_id, cluster.first_cp);
        const shaped_advance = providerGlyphAdvance(backend, run.run.font.face_id, glyph_id, cell_metrics);
        const advance_px = if (isIconCodepoint(cluster.first_cp)) @max(shaped_advance, providerGlyphVisualWidth(backend, run.run.font.face_id, glyph_id)) else shaped_advance;
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = glyph_id,
            .cluster_index = window.start + @as(u32, @intCast(idx)),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = advance_px,
        };
    }
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
}

fn providerGlyphVisualWidth(self: anytype, face_id: render.FontFaceId, glyph_id: u32) f32 {
    if (glyph_id == 0) return 0;
    if (!ensureFont(self)) return 0;
    lockFt(self);
    defer unlockFt(self);
    const shaped_face = acquireShapingFaceLocked(self, face_id) orelse return 0;
    return glyphVisualWidthPxLocked(shaped_face.face, glyph_id);
}

const ShapingFace = struct {
    face: FtFace,
    hb_font: ?HbFont,
    owns_face: bool,
};

fn acquireShapingFaceLocked(self: anytype, face_id: render.FontFaceId) ?ShapingFace {
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return null;
        return .{ .face = face, .hb_font = self.hb_font, .owns_face = false };
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return null;
    const slot = fallbackSlot(self, fallback_index) orelse return null;
    const face = self.fallback_faces[slot] orelse return null;
    return .{ .face = face, .hb_font = self.fallback_hb_fonts[slot], .owns_face = false };
}

fn textForCluster(text_cache: render.LineTextCache, cluster: render.CellCluster) render.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache.texts.len) return text_cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn glyphVisualWidthPxLocked(face: FtFace, glyph_id: u32) f32 {
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

fn isPlainAsciiCodepoint(cp: u32) bool {
    return cp >= 0x20 and cp < 0x7f;
}

pub fn rasterizeProviderGlyph(self: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (!ensureFont(self)) return false;
    lockFt(self);
    defer unlockFt(self);
    const shaped_face = acquireShapingFaceLocked(self, face_id) orelse return false;
    return rasterizeProviderGlyphFromFace(self, dst, width, height, baseline_px, shaped_face.face, glyph_id, x_origin_px, y_origin_px, glyph_index);
}

fn rasterizeProviderGlyphFromFace(_: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face: FtFace, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (glyph_id == 0) return false;
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_RENDER) != 0) return false;
    const glyph = face.*.glyph;
    if (glyph == null) return false;
    const bitmap = glyph.*.bitmap;
    if (bitmap.buffer == null or bitmap.width <= 0 or bitmap.rows <= 0) return false;
    const bw: usize = @intCast(bitmap.width);
    const bh: usize = @intCast(bitmap.rows);
    const visual_w = bitmapVisualWidth(bitmap.pixel_mode, bw);
    const visual_h = bitmapVisualHeight(bitmap.pixel_mode, bh);
    const pitch_abs: usize = @intCast(@abs(bitmap.pitch));
    const pitch_is_negative = bitmap.pitch < 0;
    const baseline: i32 = if (baseline_px > 0) baseline_px else computeBaselineFromFace(face, height);
    const origin = cellBitmapOrigin(width, baseline, glyph.*.bitmap_left, glyph.*.bitmap_top, @intCast(visual_w), x_origin_px, y_origin_px, glyph_index);

    for (0..visual_h) |yy| {
        for (0..visual_w) |xx| {
            const dx_i = origin.x_px + @as(i32, @intCast(xx));
            const dy_i = origin.y_px + @as(i32, @intCast(yy));
            if (dx_i < 0 or dy_i < 0) continue;
            const dx: u16 = @intCast(dx_i);
            const dy: u16 = @intCast(dy_i);
            if (dx >= width or dy >= height) continue;
            dst[rasterPixelOffset(width, dx, dy)] = bitmapAlpha(bitmap.buffer[0 .. pitch_abs * bh], bitmap.pixel_mode, pitch_abs, pitch_is_negative, bw, bh, xx, yy);
        }
    }
    return true;
}

fn bitmapVisualWidth(pixel_mode: anytype, bitmap_width: usize) usize {
    return switch (pixelModeValue(pixel_mode)) {
        5 => @max(bitmap_width / 3, 1),
        else => bitmap_width,
    };
}

fn bitmapVisualHeight(pixel_mode: anytype, bitmap_height: usize) usize {
    return switch (pixelModeValue(pixel_mode)) {
        6 => @max(bitmap_height / 3, 1),
        else => bitmap_height,
    };
}

fn bitmapAlpha(buffer: []const u8, pixel_mode: anytype, pitch_abs: usize, pitch_is_negative: bool, bitmap_width: usize, bitmap_height: usize, x: usize, y: usize) u8 {
    _ = bitmap_width;
    const src_y = switch (pixelModeValue(pixel_mode)) {
        6 => @min(y * 3, bitmap_height - 1),
        else => y,
    };
    const row_y = if (pitch_is_negative) bitmap_height - 1 - src_y else src_y;
    const row = buffer[row_y * pitch_abs ..][0..pitch_abs];
    return switch (pixelModeValue(pixel_mode)) {
        1 => if ((row[x / 8] & (@as(u8, 0x80) >> @intCast(x & 7))) != 0) 255 else 0,
        2 => row[x],
        3 => unpackPackedGray(row, x, 2),
        4 => unpackPackedGray(row, x, 4),
        5 => average3(row, x * 3),
        6 => average3(row, x),
        7 => row[x * 4 + 3],
        else => row[x],
    };
}

fn unpackPackedGray(row: []const u8, x: usize, bits: u3) u8 {
    const per_byte = 8 / @as(usize, bits);
    const shift: u3 = @intCast(8 - @as(usize, bits) - (x % per_byte) * @as(usize, bits));
    const mask: u8 = (@as(u8, 1) << bits) - 1;
    const value = (row[x / per_byte] >> shift) & mask;
    return @intCast((@as(u16, value) * 255) / @as(u16, mask));
}

fn average3(row: []const u8, off: usize) u8 {
    if (off + 2 >= row.len) return 0;
    return @intCast((@as(u16, row[off]) + @as(u16, row[off + 1]) + @as(u16, row[off + 2])) / 3);
}

fn pixelModeValue(pixel_mode: anytype) u32 {
    const T = @TypeOf(pixel_mode);
    return switch (@typeInfo(T)) {
        .@"enum" => @intFromEnum(pixel_mode),
        else => @intCast(pixel_mode),
    };
}

test "provider decodes packed monochrome bitmap alpha" {
    const row = [_]u8{0b1010_0000};
    try std.testing.expectEqual(@as(u8, 255), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 1, 0));
    try std.testing.expectEqual(@as(u8, 255), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 2, 0));
    try std.testing.expectEqual(@as(u8, 0), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 3, 0));
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

fn glyphAdvanceFromFace(self: anytype, face: FtFace, glyph_id: u32, cell_metrics: render.CellMetrics) f32 {
    if (!setFacePixelHeight(self, face)) return @floatFromInt(cell_metrics.cell_w_px);
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_DEFAULT) != 0) return @floatFromInt(cell_metrics.cell_w_px);
    if (face.*.glyph == null) return @floatFromInt(cell_metrics.cell_w_px);
    return render.Text.Metrics.advancePx(@intCast(face.*.glyph.*.advance.x), cell_metrics.cell_w_px);
}

fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    return c_api.shapeGlyphId(hb_font, face, codepoint);
}

fn setFacePixelHeight(self: anytype, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
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

fn resetFallbackFaces(self: anytype) void {
    for (self.fallback_faces, 0..) |face_opt, i| {
        c_api.destroyHbFont(self.fallback_hb_fonts[i]);
        self.fallback_hb_fonts[i] = null;
        if (face_opt != null) {
            _ = c.FT_Done_Face(face_opt.?);
            self.fallback_faces[i] = null;
        }
    }
}

fn gatherShapeRunInput(
    allocator: std.mem.Allocator,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    window: ClusterWindow,
) !ShapeRunInput {
    var input = ShapeRunInput{ .codepoints = .empty, .cluster_map = .empty };
    errdefer input.deinit(allocator);
    for (window.slice(clusters), 0..) |cluster, local_idx| {
        const text = textForCluster(text_cache_view, cluster);
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        try input.codepoints.appendSlice(allocator, cps);
        for (cps) |_| try input.cluster_map.append(allocator, window.start + @as(u32, @intCast(local_idx)));
    }
    return input;
}

fn buildProviderShapedRun(
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    clusters: []const render.CellCluster,
    cell_metrics: render.CellMetrics,
    face: FtFace,
    infos: [*c]c.hb_glyph_info_t,
    positions: [*c]c.hb_glyph_position_t,
    glyph_count: c_uint,
    cluster_map: []const u32,
) !render.Text.ShapeRun.OwnedShapedRun {
    const glyphs = try allocator.alloc(render.GlyphInstance, glyph_count);
    errdefer allocator.free(glyphs);
    for (glyphs, 0..) |*glyph, idx| {
        const info = infos[idx];
        const pos = positions[idx];
        const cluster_cp_idx = @min(@as(u32, info.cluster), @as(u32, @intCast(cluster_map.len - 1)));
        const cluster_idx = cluster_map[@intCast(cluster_cp_idx)];
        const shaped_advance = render.Text.Metrics.advancePx(@intCast(pos.x_advance), cell_metrics.cell_w_px);
        const advance_px = if (cluster_idx < clusters.len and isIconCodepoint(clusters[@intCast(cluster_idx)].first_cp))
            @max(shaped_advance, glyphVisualWidthPxLocked(face, info.codepoint))
        else
            shaped_advance;
        glyph.* = .{
            .face_id = run.run.font.face_id,
            .glyph_id = info.codepoint,
            .cluster_index = cluster_idx,
            .x_offset_px = @as(f32, @floatFromInt(@as(i32, @intCast(pos.x_offset)))) / 64.0,
            .y_offset_px = @as(f32, @floatFromInt(@as(i32, @intCast(pos.y_offset)))) / 64.0,
            .x_advance_px = advance_px,
        };
    }
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
}

fn tryRasterizeProviderSpecialCase(backend: anytype, pixels: []u8, width: u16, height: u16, req: render.SpriteRasterRequest) bool {
    if (req.kind == .undercurl) {
        render.Text.Rasterizer.rasterizeUndercurlAlpha(pixels, width, height, req.decoration);
        return true;
    }
    if (req.group.kind == .box_fallback) {
        if (!render.Text.Rasterizer.rasterizeGeneratedSpecialAlphaWithMetrics(pixels, width, height, req.group.first_cp, req.box_drawing)) {
            special_sprite.rasterizeSpecialSpriteAlpha(pixels, width, height, req.group.first_cp);
        }
        return true;
    }
    if (!useDeterministicTestTextFallback(backend)) return false;
    special_sprite.rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
    return true;
}

fn providerSpriteOutput(
    allocator: std.mem.Allocator,
    req: render.SpriteRasterRequest,
    width: u16,
    height: u16,
    pixels: []u8,
) render.Text.Rasterizer.RasterSpriteOutput {
    return .{
        .allocator = allocator,
        .key = req.key,
        .width_px = width,
        .height_px = height,
        .color_mode = req.color_mode,
        .pixels = pixels,
    };
}

fn fallbackSlot(self: anytype, fallback_index: u32) ?usize {
    if (fallback_index >= self.fallback_font_paths_len) return null;
    return @intCast(fallback_index);
}

fn rasterPixelCount(width: u16, height: u16) usize {
    return @as(usize, width) * @as(usize, height);
}

fn rasterPixelOffset(width: u16, x: u16, y: u16) usize {
    return @as(usize, y) * @as(usize, width) + x;
}

fn useDeterministicTestTextFallback(backend: anytype) bool {
    return builtin.is_test and backend.config.font_path == null and backend.fallback_font_paths_len == 0;
}
