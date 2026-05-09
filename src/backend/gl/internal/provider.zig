const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../../render_core.zig").RenderCore;
const shared_text_cache = @import("../../shared/text_cache.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

const FtLibrary = c_api.FtLibrary;
const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;

pub const primary_face_id: u32 = 1;

pub const ResolvedGlyphKey = struct {
    codepoint: u21,
    face_id: u32,
    glyph_id: u32,
};

pub fn providerHasCodepoint(comptime Backend: type, ctx: *anyopaque, face_id: render_core.FontFaceId, codepoint: u32) bool {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    if (useDeterministicTestTextFallback(backend)) return codepoint != 0;
    if (!ensureFont(backend)) return false;
    if (face_id.value == primary_face_id) {
        const face = backend.ft_face orelse return false;
        return c.FT_Get_Char_Index(face, codepoint) != 0;
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    const face = ensureFallbackFace(backend, fallback_index) orelse return false;
    return c.FT_Get_Char_Index(face, codepoint) != 0;
}

pub fn providerHasCellText(comptime Backend: type, ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const key = shared_text_cache.FaceTextKey{ .face_id = face_id.value, .text_hash = shared_text_cache.hashCellText(text) };
    const entry = backend.face_text_cache.map.getOrPut(key) catch return uncachedProviderHasCellText(Backend, ctx, face_id, text);
    if (entry.found_existing) {
        backend.resolve_counters.face_cache_hits += 1;
        return entry.value_ptr.*;
    }

    backend.resolve_counters.face_checks += 1;
    const result = uncachedProviderHasCellText(Backend, ctx, face_id, text);
    entry.value_ptr.* = result;
    return result;
}

fn uncachedProviderHasCellText(comptime Backend: type, ctx: *anyopaque, face_id: render_core.FontFaceId, text: render_core.CellText) bool {
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
    run: render_core.ResolvedRun,
    text_cache_view: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
) anyerror!render_core.Text.ShapeRun.OwnedShapedRun {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const start = @as(usize, @intCast(run.run.cluster_start));
    const count = @as(usize, @intCast(run.run.cluster_count));
    const end = @min(start + count, clusters.len);
    if (end <= start) {
        return .{ .allocator = allocator, .run = run, .glyphs = try allocator.alloc(render_core.GlyphInstance, 0) };
    }

    backend.resolve_counters.shape_requests += 1;
    const shape_key = shared_text_cache.ShapeRunKey{
        .face_id = run.run.font.face_id.value,
        .run_hash = shared_text_cache.hashRunText(text_cache_view, clusters[start..end]),
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    if (try backend.shape_run_cache.getOwnedRun(allocator, shape_key, run)) |cached| {
        backend.resolve_counters.shape_cache_hits += 1;
        return cached;
    }

    var shaped = if (builtin.target.abi == .android)
        try fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end)
    else
        try shapeRunViaProviderOrFallback(backend, allocator, run, text_cache_view, clusters, cell_metrics, start, end);
    errdefer shaped.deinit();
    try backend.shape_run_cache.putRun(shape_key, shaped);
    return shaped;
}

fn shapeRunViaProviderOrFallback(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    text_cache_view: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
    start: usize,
    end: usize,
) anyerror!render_core.Text.ShapeRun.OwnedShapedRun {
    const shaped_face = acquireShapingFace(backend, run.run.font.face_id) orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };
    defer releaseShapingFace(shaped_face);
    const hb_font = shaped_face.hb_font orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };

    var run_codepoints = std.ArrayList(u32).empty;
    defer run_codepoints.deinit(allocator);
    var cluster_map = std.ArrayList(u32).empty;
    defer cluster_map.deinit(allocator);
    for (clusters[start..end], 0..) |cluster, local_idx| {
        const text = textForCluster(text_cache_view, cluster);
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
        const cluster_idx = cluster_map.items[cluster_cp_idx];
        const shaped_advance = render_core.Text.Metrics.advancePx(@intCast(pos.x_advance), cell_metrics.cell_w_px);
        const advance_px = if (cluster_idx < clusters.len and isIconCodepoint(clusters[cluster_idx].first_cp))
            @max(shaped_advance, glyphVisualWidthPx(shaped_face.face, info.codepoint))
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

pub fn providerGlyphId(self: anytype, face_id: render_core.FontFaceId, codepoint: u32) u32 {
    if (useDeterministicTestTextFallback(self)) return codepoint;
    if (!ensureFont(self)) return 0;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return 0;
        return shapeGlyphId(self.hb_font, face, @intCast(codepoint));
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return 0;
    const face = ensureFallbackFace(self, fallback_index) orelse return 0;
    return shapeGlyphId(self.fallback_hb_fonts[fallback_index], face, @intCast(codepoint));
}

pub fn providerGlyphAdvance(self: anytype, face_id: render_core.FontFaceId, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    const fallback: f32 = @floatFromInt(cell_metrics.cell_w_px);
    if (glyph_id == 0) return fallback;
    if (!ensureFont(self)) return fallback;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return fallback;
        return glyphAdvanceFromFace(self, face, glyph_id, cell_metrics);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return fallback;
    const face = ensureFallbackFace(self, fallback_index) orelse return fallback;
    return glyphAdvanceFromFace(self, face, glyph_id, cell_metrics);
}

pub fn providerRasterizeSprite(
    comptime Backend: type,
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

    if (req.kind == .undercurl) {
        render_core.Text.Rasterizer.rasterizeUndercurlAlpha(pixels, width, height, req.decoration);
        return .{
            .allocator = allocator,
            .key = req.key,
            .width_px = width,
            .height_px = height,
            .color_mode = req.color_mode,
            .pixels = pixels,
        };
    }

    if (req.group.kind == .box_fallback) {
        if (render_core.Text.Rasterizer.rasterizeGeneratedSpecialAlpha(pixels, width, height, req.group.first_cp)) {
            return .{
                .allocator = allocator,
                .key = req.key,
                .width_px = width,
                .height_px = height,
                .color_mode = req.color_mode,
                .pixels = pixels,
            };
        }
        rasterizeSpecialSpriteAlpha(pixels, width, height, req.group.first_cp);
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

pub fn ensurePrimaryFont(self: anytype) bool {
    if (self.ft_face != null) return true;
    if (!ensureFreeTypeLibrary(self)) return false;
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

pub fn ensureFont(self: anytype) bool {
    if (ensurePrimaryFont(self)) {
        self.resolve_stage = .loaded_exact_match;
        return true;
    }
    if (!ensureFreeTypeLibrary(self)) return false;

    var i: usize = 0;
    while (i < self.fallback_font_paths_len) : (i += 1) {
        if (self.fallback_font_paths[i] == null) continue;
        if (ensureFallbackFace(self, i)) |_| {
            self.resolve_stage = .discovery_fallback;
            return true;
        }
    }

    self.resolve_stage = .missing_glyph;
    self.resolve_counters.missing_glyphs += 1;
    return false;
}

pub fn resetLoadedFace(self: anytype) void {
    resetFallbackFaces(self);
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

pub fn ensureFallbackFace(self: anytype, fallback_index: usize) ?FtFace {
    if (fallback_index >= self.fallback_font_paths_len) return null;
    if (self.fallback_faces[fallback_index]) |face| return face;
    if (!ensureFreeTypeLibrary(self)) return null;
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

pub fn resolveGlyphKey(self: anytype, codepoint: u21) ?ResolvedGlyphKey {
    _ = ensureFont(self);
    if (self.ft_face) |face| {
        if (setFacePixelHeight(self, face)) {
            const glyph_id = shapeGlyphId(self.hb_font, face, codepoint);
            if (glyph_id != 0) return .{ .codepoint = codepoint, .face_id = primary_face_id, .glyph_id = glyph_id };
        }
    }
    return null;
}

pub fn deriveCellMetrics(self: anytype) render_core.CellMetrics {
    if (ensurePrimaryFont(self)) {
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

pub fn configuredCellMetrics(self: anytype) render_core.CellMetrics {
    const cell_w = @max(self.config.cell_px.width, 1);
    const cell_h = @max(self.config.cell_px.height, 1);
    const baseline = if (ensurePrimaryFont(self))
        computeBaselineFromFace(self.ft_face.?, cell_h)
    else
        @as(i32, @intCast(@max(cell_h - @divFloor(cell_h, 5), 1)));
    return .{
        .cell_w_px = cell_w,
        .cell_h_px = cell_h,
        .baseline_px = @intCast(std.math.clamp(baseline, 1, @as(i32, @intCast(cell_h)))),
    };
}

pub fn deriveCellSize(self: anytype) render_core.CellSize {
    const cell = deriveCellMetrics(self);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

pub fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return render_core.Text.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
}

fn fallbackFaceId(index: usize) u32 {
    return @intCast(index + 2);
}

fn ensureFreeTypeLibrary(self: anytype) bool {
    if (self.ft_lib != null) return true;
    var lib: FtLibrary = undefined;
    if (c.FT_Init_FreeType(&lib) != 0) return false;
    self.ft_lib = lib;
    return true;
}

fn missingGlyphKey(codepoint: u21) ResolvedGlyphKey {
    return .{ .codepoint = codepoint, .face_id = 0, .glyph_id = codepoint };
}

fn fallbackProviderShapeRun(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
    start: usize,
    end: usize,
) anyerror!render_core.Text.ShapeRun.OwnedShapedRun {
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

fn providerGlyphVisualWidth(self: anytype, face_id: render_core.FontFaceId, glyph_id: u32) f32 {
    if (glyph_id == 0) return 0;
    if (!ensureFont(self)) return 0;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return 0;
        return glyphVisualWidthPx(face, glyph_id);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return 0;
    const face = ensureFallbackFace(self, fallback_index) orelse return 0;
    return glyphVisualWidthPx(face, glyph_id);
}

const ShapingFace = struct {
    face: FtFace,
    hb_font: ?HbFont,
    owns_face: bool,
};

fn acquireShapingFace(self: anytype, face_id: render_core.FontFaceId) ?ShapingFace {
    if (!ensureFont(self)) return null;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return null;
        return .{ .face = face, .hb_font = self.hb_font, .owns_face = false };
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return null;
    const face = ensureFallbackFace(self, fallback_index) orelse return null;
    return .{ .face = face, .hb_font = self.fallback_hb_fonts[fallback_index], .owns_face = false };
}

fn releaseShapingFace(shaped: ShapingFace) void {
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

fn rasterizeProviderGlyph(self: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render_core.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (!ensureFont(self)) return false;
    if (face_id.value == primary_face_id) {
        const face = self.ft_face orelse return false;
        return rasterizeProviderGlyphFromFace(dst, width, height, baseline_px, face, glyph_id, x_origin_px, y_origin_px, glyph_index);
    }

    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return false;
    const face = ensureFallbackFace(self, fallback_index) orelse return false;
    return rasterizeProviderGlyphFromFace(dst, width, height, baseline_px, face, glyph_id, x_origin_px, y_origin_px, glyph_index);
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

fn glyphAdvanceFromFace(self: anytype, face: FtFace, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
    if (!setFacePixelHeight(self, face)) return @floatFromInt(cell_metrics.cell_w_px);
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_DEFAULT) != 0) return @floatFromInt(cell_metrics.cell_w_px);
    if (face.*.glyph == null) return @floatFromInt(cell_metrics.cell_w_px);
    return render_core.Text.Metrics.advancePx(@intCast(face.*.glyph.*.advance.x), cell_metrics.cell_w_px);
}

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

fn setFacePixelHeight(self: anytype, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
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

fn resetFallbackFaces(self: anytype) void {
    var i: usize = 0;
    while (i < self.fallback_faces.len) : (i += 1) {
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

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render_core.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn useDeterministicTestTextFallback(backend: anytype) bool {
    return builtin.is_test and backend.config.font_path == null and backend.fallback_font_paths_len == 0;
}
