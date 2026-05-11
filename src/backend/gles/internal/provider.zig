//! Responsibility: implement OpenGL ES backend text provider callbacks.
//! Ownership: OpenGL ES backend internals own FreeType/HarfBuzz cache wiring.
//! Reason: keeps backend font access behind the render-core text provider boundary.

const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../../render_core.zig").RenderCore;
const text_cache = @import("../../shared/text_cache.zig");
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
    const key = text_cache.FaceTextKey{ .face_id = face_id.value, .text_hash = text_cache.hashCellText(text) };
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

    var shaped = if (builtin.target.abi == .android)
        try fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end)
    else if (try shapePlainAsciiRun(backend, allocator, run, text_cache_view, clusters, cell_metrics, start, end)) |ascii|
        ascii
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

    if (!ensureFont(backend)) {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    }

    const shaped_face = acquireShapingFace(backend, run.run.font.face_id) orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };
    defer releaseShapingFace(shaped_face);
    const hb_font = shaped_face.hb_font orelse {
        return fallbackProviderShapeRun(backend, allocator, run, clusters, cell_metrics, start, end);
    };
    c.hb_shape(hb_font, buffer, null, 0);

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

fn shapePlainAsciiRun(
    backend: anytype,
    allocator: std.mem.Allocator,
    run: render_core.ResolvedRun,
    text_cache_view: render_core.LineTextCache,
    clusters: []const render_core.CellCluster,
    cell_metrics: render_core.CellMetrics,
    start: usize,
    end: usize,
) anyerror!?render_core.Text.ShapeRun.OwnedShapedRun {
    if (run.features_id != 0) return null;
    if (run.run.font.presentation == .emoji) return null;

    for (clusters[start..end]) |cluster| {
        if (cluster.cell_span != 1) return null;
        if (cluster.presentation == .emoji) return null;
        const text = textForCluster(text_cache_view, cluster);
        if (text.codepoints.len != 1) return null;
        if (text.codepoints[0] != cluster.first_cp) return null;
        if (!isPlainAsciiCodepoint(cluster.first_cp)) return null;
    }

    if (!ensureFont(backend)) return null;

    const glyphs = try allocator.alloc(render_core.GlyphInstance, end - start);
    var keep_glyphs = false;
    defer if (!keep_glyphs) allocator.free(glyphs);

    const shaped_face = acquireShapingFace(backend, run.run.font.face_id) orelse return null;
    const face = shaped_face.face;

    for (clusters[start..end], 0..) |cluster, idx| {
        const glyph_id = c.FT_Get_Char_Index(face, cluster.first_cp);
        if (glyph_id == 0) return null;
        glyphs[idx] = .{
            .face_id = run.run.font.face_id,
            .glyph_id = glyph_id,
            .cluster_index = @intCast(start + idx),
            .x_offset_px = 0,
            .y_offset_px = 0,
            .x_advance_px = glyphAdvanceFromFace(face, glyph_id, cell_metrics),
        };
    }

    keep_glyphs = true;
    return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
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
        return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
    }

    if (req.group.kind == .box_fallback) {
        if (render_core.Text.Rasterizer.rasterizeGeneratedSpecialAlphaWithMetrics(pixels, width, height, req.group.first_cp, req.box_drawing)) {
            return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
        }
        rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
        return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
    }

    if (useDeterministicTestTextFallback(backend)) {
        rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
        return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
    }

    var pen_x: f32 = 0;
    for (req.group.glyphs, 0..) |glyph, glyph_idx| {
        const x_px = @as(i32, @intFromFloat(std.math.floor(pen_x + glyph.x_offset_px)));
        const y_px = @as(i32, @intFromFloat(std.math.floor(glyph.y_offset_px)));
        _ = rasterizeProviderGlyph(backend, pixels, width, height, req.baseline_px, glyph.face_id, glyph.glyph_id, x_px, y_px, @intCast(glyph_idx));
        pen_x += glyph.x_advance_px;
    }

    return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
}

fn providerGlyphId(self: anytype, face_id: render_core.FontFaceId, codepoint: u32) u32 {
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
    if (useDeterministicTestTextFallback(self)) return fallback;
    const face = if (face_id.value == primary_face_id)
        self.ft_face
    else
        ensureFallbackFace(self, if (face_id.value >= 2) face_id.value - 2 else return fallback);
    if (face == null) return fallback;
    return glyphAdvanceFromFace(face.?, glyph_id, cell_metrics);
}

pub fn providerLookupGlyph(comptime Backend: type, ctx: *anyopaque, face_id: render_core.FontFaceId, codepoint: u32, cell_metrics: render_core.CellMetrics) render_core.Text.Provider.LookupGlyphResult {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const key = text_cache.GlyphCellKey{
        .face_id = face_id.value,
        .codepoint = codepoint,
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    const entry = backend.glyph_cell_cache.map.getOrPut(key) catch return .{
        .glyph_id = providerGlyphId(backend, face_id, codepoint),
        .advance_px = providerGlyphAdvance(backend, face_id, providerGlyphId(backend, face_id, codepoint), cell_metrics),
    };
    if (!entry.found_existing) {
        const glyph_id = providerGlyphId(backend, face_id, codepoint);
        entry.value_ptr.* = .{
            .glyph_id = glyph_id,
            .advance_px = providerGlyphAdvance(backend, face_id, glyph_id, cell_metrics),
        };
    }
    return .{
        .glyph_id = entry.value_ptr.glyph_id,
        .advance_px = entry.value_ptr.advance_px,
    };
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
    if (fallback_index >= self.fallback_font_paths_len) return null;
    const face = self.fallback_faces[fallback_index] orelse return null;
    return .{ .face = face, .hb_font = self.fallback_hb_fonts[fallback_index], .owns_face = false };
}

fn releaseShapingFace(shaped: ShapingFace) void {
    if (shaped.owns_face) {
        if (shaped.hb_font != null and builtin.target.abi != .android) {
            c.hb_font_destroy(shaped.hb_font.?);
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

pub fn rasterizeProviderGlyph(self: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render_core.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (useDeterministicTestTextFallback(self)) {
        rasterizeFallbackGlyph(dst, width, height, @intCast(glyph_id), width, height);
        return true;
    }
    if (!ensureFont(self)) return false;
    const face = if (face_id.value == primary_face_id)
        self.ft_face
    else
        ensureFallbackFace(self, if (face_id.value >= 2) face_id.value - 2 else return false);
    if (face == null) return false;
    return rasterizeProviderGlyphFromFace(dst, width, height, baseline_px, face.?, glyph_id, x_origin_px, y_origin_px, glyph_index);
}

fn ensureFont(self: anytype) bool {
    if (ensurePrimaryFont(self)) {
        self.resolve_stage = .loaded_exact_match;
        return true;
    }
    if (!ensureFreeTypeLibrary(self)) return false;

    var i: usize = 0;
    while (i < self.fallback_font_paths_len) : (i += 1) {
        if (self.fallback_font_paths[i] == null) continue;
        if (ensureFallbackFace(self, i) != null) {
            self.resolve_stage = .discovery_fallback;
            return true;
        }
    }

    self.resolve_stage = .missing_glyph;
    self.resolve_counters.missing_glyphs += 1;
    return false;
}

fn ensurePrimaryFont(self: anytype) bool {
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

fn ensureFallbackFace(self: anytype, fallback_index: usize) ?FtFace {
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

fn ensureFreeTypeLibrary(self: anytype) bool {
    if (self.ft_lib != null) return true;
    var lib: FtLibrary = undefined;
    if (c.FT_Init_FreeType(&lib) != 0) return false;
    self.ft_lib = lib;
    return true;
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
            const dx: usize = @intCast(dx_i);
            const dy: usize = @intCast(dy_i);
            if (dx >= width or dy >= height) continue;
            dst[dy * @as(usize, width) + dx] = bitmapAlpha(bitmap.buffer[0 .. pitch_abs * bh], bitmap.pixel_mode, pitch_abs, pitch_is_negative, bw, bh, xx, yy);
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

test "gles provider decodes packed monochrome bitmap alpha" {
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

fn glyphAdvanceFromFace(face: FtFace, glyph_id: u32, cell_metrics: render_core.CellMetrics) f32 {
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

fn setFacePixelHeight(self: anytype, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(self.config.font_size_px, 1)) == 0;
}

fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return render_core.Text.Metrics.baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
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

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render_core.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn useDeterministicTestTextFallback(self: anytype) bool {
    return builtin.is_test and self.config.font_path == null;
}
