const builtin = @import("builtin");
const std = @import("std");
const render = @import("../howl_render.zig");
const contract = @import("contract.zig");
const surface = @import("../frame/surface.zig");
const text_cache = @import("text_cache.zig");
const c_api = @import("ft_hb_c_api.zig");

pub const c = c_api.c;
pub const FtLibrary = c_api.FtLibrary;
pub const FtFace = c_api.FtFace;
pub const HbFont = c_api.HbFont;
pub const primary_face_id: u32 = 1;
pub const max_fallback_fonts: usize = 24;

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub const State = struct {
    ft_lib: ?FtLibrary = null,
    ft_face: ?FtFace = null,
    hb_font: ?HbFont = null,
    ft_mutex: ThreadMutex = .{},
    font_analysis_mutex: ThreadMutex = .{},
    fallback_faces: [max_fallback_fonts]?FtFace = [_]?FtFace{null} ** max_fallback_fonts,
    fallback_hb_fonts: [max_fallback_fonts]?HbFont = [_]?HbFont{null} ** max_fallback_fonts,
    resolve_counters: render.ResolveCounters = .{},
    resolve_stage: render.ResolveStage = .style_policy,
    active_resolve: ?*render.ResolveObservability = null,
    face_text_cache: text_cache.FaceTextCache,
    shape_run_cache: text_cache.ShapeRunCache,
    glyph_cell_cache: text_cache.GlyphCellCache,
    fallback_font_paths: [max_fallback_fonts]?[:0]const u8 = [_]?[:0]const u8{null} ** max_fallback_fonts,
    fallback_font_paths_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .face_text_cache = text_cache.FaceTextCache.init(allocator),
            .shape_run_cache = text_cache.ShapeRunCache.init(allocator),
            .glyph_cell_cache = text_cache.GlyphCellCache.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.shape_run_cache.deinit();
        self.face_text_cache.deinit();
        self.glyph_cell_cache.deinit();
        self.* = undefined;
    }
};

fn textState(self: anytype) *State {
    const T = @TypeOf(self.*);
    if (@hasField(T, "text_state")) return &self.text_state;
    if (@hasField(T, "session")) return &self.session.text_state;
    @compileError("text state owner missing text_state field");
}

fn configView(self: anytype) render.SurfaceTextConfig {
    const T = @TypeOf(self.*);
    if (@hasField(T, "config")) return self.config;
    if (@hasField(T, "session_config")) return self.session_config;
    @compileError("text config owner missing session config");
}

fn lockFt(self: anytype) void {
    textState(self).ft_mutex.lock();
}

fn unlockFt(self: anytype) void {
    textState(self).ft_mutex.unlock();
}

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

pub fn providerHasCodepoint(comptime ContextType: type, ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32) bool {
    const context: *ContextType = @ptrCast(@alignCast(ctx));
    if (useDeterministicTestTextFallback(context)) return codepoint != 0;
    if (!ensureFont(context)) return false;
    lockFt(context);
    defer unlockFt(context);
    const shaped_face = acquireShapingFaceLocked(context, face_id) orelse return false;
    return c.FT_Get_Char_Index(shaped_face.face, codepoint) != 0;
}

pub fn providerHasCellText(comptime ContextType: type, ctx: *anyopaque, face_id: render.FontFaceId, text: render.CellText) bool {
    const context: *ContextType = @ptrCast(@alignCast(ctx));
    const state = textState(context);
    const key = text_cache.FaceTextKey{ .face_id = face_id.value, .text_hash = text_cache.hashCellText(text) };
    const entry = state.face_text_cache.map.getOrPut(key) catch return uncachedProviderHasCellText(ContextType, ctx, face_id, text);
    if (entry.found_existing) {
        state.resolve_counters.face_cache_hits += 1;
        if (state.active_resolve) |obs| obs.counters.face_cache_hits += 1;
        return entry.value_ptr.*;
    }
    state.resolve_counters.face_checks += 1;
    if (state.active_resolve) |obs| obs.counters.face_checks += 1;
    const result = uncachedProviderHasCellText(ContextType, ctx, face_id, text);
    entry.value_ptr.* = result;
    return result;
}

fn uncachedProviderHasCellText(comptime ContextType: type, ctx: *anyopaque, face_id: render.FontFaceId, text: render.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp == 0xfe0e or cp == 0xfe0f) continue;
        if (!providerHasCodepoint(ContextType, ctx, face_id, cp)) return false;
    }
    return true;
}

pub fn providerShapeRun(comptime ContextType: type, ctx: *anyopaque, allocator: std.mem.Allocator, run: render.ResolvedRun, text_cache_view: render.LineTextCache, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    const context: *ContextType = @ptrCast(@alignCast(ctx));
    const state = textState(context);
    const window = ClusterWindow.init(run, clusters.len);
    if (window.empty()) return .{ .allocator = allocator, .run = run, .glyphs = try allocator.alloc(render.GlyphInstance, 0) };
    state.resolve_counters.shape_requests += 1;
    if (state.active_resolve) |obs| obs.counters.shape_requests += 1;
    const shape_key = text_cache.ShapeRunKey{
        .face_id = run.run.font.face_id.value,
        .run_hash = text_cache.hashRunText(text_cache_view, window.slice(clusters)),
        .cell_w_px = cell_metrics.cell_w_px,
        .cell_h_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
    };
    if (try state.shape_run_cache.getOwnedRun(allocator, shape_key, run)) |cached| {
        state.resolve_counters.shape_cache_hits += 1;
        if (state.active_resolve) |obs| obs.counters.shape_cache_hits += 1;
        return cached;
    }
    var shaped = if (try shapePlainAsciiRun(context, allocator, run, text_cache_view, clusters, cell_metrics, window)) |ascii|
        ascii
    else
        try shapeRunViaProviderOrFallback(context, allocator, run, text_cache_view, clusters, cell_metrics, window);
    errdefer shaped.deinit();
    try state.shape_run_cache.putRun(shape_key, shaped);
    return shaped;
}

fn shapeRunViaProviderOrFallback(context: anytype, allocator: std.mem.Allocator, run: render.ResolvedRun, text_cache_view: render.LineTextCache, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics, window: ClusterWindow) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    var input = try gatherShapeRunInput(allocator, text_cache_view, clusters, window);
    defer input.deinit(allocator);
    if (input.codepoints.items.len == 0) return fallbackProviderShapeRun(context, allocator, run, clusters, cell_metrics, window);
    const buffer = c.hb_buffer_create() orelse return fallbackProviderShapeRun(context, allocator, run, clusters, cell_metrics, window);
    defer c.hb_buffer_destroy(buffer);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_buffer_add_utf32(buffer, input.codepoints.items.ptr, @intCast(input.codepoints.items.len), 0, @intCast(input.codepoints.items.len));
    c.hb_buffer_guess_segment_properties(buffer);
    if (!ensureFont(context)) return fallbackProviderShapeRun(context, allocator, run, clusters, cell_metrics, window);
    return try shapeRunViaProvider(context, allocator, run, clusters, cell_metrics, buffer, input.cluster_map.items) orelse fallbackProviderShapeRun(context, allocator, run, clusters, cell_metrics, window);
}

fn shapeRunViaProvider(context: anytype, allocator: std.mem.Allocator, run: render.ResolvedRun, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics, buffer: ?*c.hb_buffer_t, cluster_map: []const u32) anyerror!?render.Text.ShapeRun.OwnedShapedRun {
    lockFt(context);
    defer unlockFt(context);
    const shaped_face = acquireShapingFaceLocked(context, run.run.font.face_id) orelse return null;
    const hb_font = shaped_face.hb_font orelse return null;
    c.hb_shape(hb_font, buffer, null, 0);
    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);
    if (infos == null or positions == null or glyph_count == 0) return null;
    return try buildProviderShapedRun(allocator, run, clusters, cell_metrics, shaped_face.face, infos, positions, glyph_count, cluster_map);
}

fn shapePlainAsciiRun(context: anytype, allocator: std.mem.Allocator, run: render.ResolvedRun, text_cache_view: render.LineTextCache, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics, window: ClusterWindow) anyerror!?render.Text.ShapeRun.OwnedShapedRun {
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
    if (!ensureFont(context)) return null;
    const glyphs = try allocator.alloc(render.GlyphInstance, window.len());
    var keep_glyphs = false;
    defer if (!keep_glyphs) allocator.free(glyphs);
    lockFt(context);
    defer unlockFt(context);
    const shaped_face = acquireShapingFaceLocked(context, run.run.font.face_id) orelse return null;
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
            .x_advance_px = glyphAdvanceFromFace(context, face, glyph_id, cell_metrics),
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

pub fn providerLookupGlyph(comptime ContextType: type, ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
    const context: *ContextType = @ptrCast(@alignCast(ctx));
    const state = textState(context);
    const key = text_cache.GlyphCellKey{ .face_id = face_id.value, .codepoint = codepoint, .cell_w_px = cell_metrics.cell_w_px, .cell_h_px = cell_metrics.cell_h_px, .baseline_px = cell_metrics.baseline_px };
    const entry = state.glyph_cell_cache.map.getOrPut(key) catch return uncachedProviderLookupGlyph(context, face_id, codepoint, cell_metrics);
    if (!entry.found_existing) entry.value_ptr.* = glyphCellValue(uncachedProviderLookupGlyph(context, face_id, codepoint, cell_metrics));
    return .{ .glyph_id = entry.value_ptr.glyph_id, .advance_px = entry.value_ptr.advance_px };
}

fn uncachedProviderLookupGlyph(context: anytype, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) render.Text.Provider.LookupGlyphResult {
    const glyph_id = providerGlyphId(context, face_id, codepoint);
    return .{ .glyph_id = glyph_id, .advance_px = providerGlyphAdvance(context, face_id, glyph_id, cell_metrics) };
}

fn glyphCellValue(result: render.Text.Provider.LookupGlyphResult) text_cache.GlyphCellValue {
    return .{ .glyph_id = result.glyph_id, .advance_px = result.advance_px };
}

pub fn ensurePrimaryFont(self: anytype) bool {
    const state = textState(self);
    lockFt(self);
    defer unlockFt(self);
    if (state.ft_face != null) return true;
    if (!ensureFreeTypeLibraryLocked(self)) return false;
    const config = configView(self);
    if (config.font_path == null) return false;
    var face: FtFace = undefined;
    const lib = state.ft_lib.?;
    const font_path = config.font_path.?;
    if (c.FT_New_Face(lib, font_path, 0, &face) != 0) return false;
    if (!setFacePixelHeight(self, face)) {
        _ = c.FT_Done_Face(face);
        return false;
    }
    state.ft_face = face;
    state.hb_font = c_api.createHbFont(face);
    return true;
}

pub fn ensureFont(self: anytype) bool {
    const state = textState(self);
    if (ensurePrimaryFont(self)) {
        state.resolve_stage = .loaded_exact_match;
        if (state.active_resolve) |obs| obs.stage = .loaded_exact_match;
        return true;
    }
    for (0..state.fallback_font_paths_len) |i| {
        if (state.fallback_font_paths[i] == null) continue;
        if (ensureFallbackFace(self, @intCast(i))) |_| {
            state.resolve_stage = .discovery_fallback;
            if (state.active_resolve) |obs| obs.stage = .discovery_fallback;
            return true;
        }
    }
    state.resolve_stage = .missing_glyph;
    state.resolve_counters.missing_glyphs += 1;
    if (state.active_resolve) |obs| {
        obs.stage = .missing_glyph;
        obs.counters.missing_glyphs += 1;
    }
    return false;
}

pub fn resetLoadedFace(self: anytype) void {
    const state = textState(self);
    lockFt(self);
    defer unlockFt(self);
    resetFallbackFaces(self);
    if (state.ft_face != null) {
        c_api.destroyHbFont(state.hb_font);
        state.hb_font = null;
        _ = c.FT_Done_Face(state.ft_face.?);
        state.ft_face = null;
    }
    if (state.ft_lib != null) {
        _ = c.FT_Done_FreeType(state.ft_lib.?);
        state.ft_lib = null;
    }
}

pub fn resizeLoadedFaces(self: anytype) void {
    const state = textState(self);
    lockFt(self);
    defer unlockFt(self);
    if (state.ft_face) |face| _ = setFacePixelHeight(self, face);
    for (state.fallback_faces) |face_opt| {
        if (face_opt) |face| _ = setFacePixelHeight(self, face);
    }
}

pub fn ensureFallbackFace(self: anytype, fallback_index: u32) ?FtFace {
    const state = textState(self);
    lockFt(self);
    defer unlockFt(self);
    const slot = fallbackSlot(self, fallback_index) orelse return null;
    if (state.fallback_faces[slot]) |face| return face;
    if (!ensureFreeTypeLibraryLocked(self)) return null;
    const font_path = state.fallback_font_paths[slot] orelse return null;
    const lib = state.ft_lib orelse return null;
    var face: FtFace = undefined;
    if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return null;
    if (!setFacePixelHeight(self, face)) {
        _ = c.FT_Done_Face(face);
        return null;
    }
    state.fallback_faces[slot] = face;
    state.fallback_hb_fonts[slot] = c_api.createHbFont(face);
    return face;
}

pub fn deriveCellMetrics(self: anytype) render.CellMetrics {
    const state = textState(self);
    if (ensurePrimaryFont(self)) {
        lockFt(self);
        defer unlockFt(self);
        return cellMetricsFromFace(state.ft_face.?, configView(self).font_size_px);
    }
    lockFt(self);
    defer unlockFt(self);
    if (ensureFreeTypeLibraryLocked(self)) {
        const lib = state.ft_lib.?;
        var i: usize = 0;
        while (i < state.fallback_font_paths_len) : (i += 1) {
            const font_path = state.fallback_font_paths[i] orelse continue;
            var face: FtFace = undefined;
            if (c.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) continue;
            defer _ = c.FT_Done_Face(face);
            if (!setFacePixelHeight(self, face)) continue;
            return cellMetricsFromFace(face, configView(self).font_size_px);
        }
    }
    return defaultCellMetrics(configView(self).font_size_px);
}

pub fn configuredCellMetrics(self: anytype) render.CellMetrics {
    return deriveCellMetrics(self);
}

pub fn deriveCellSize(self: anytype) surface.CellSize {
    const cell = deriveCellMetrics(self);
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

pub fn computeBaselineFromFace(face: FtFace, cell_h: u16) i32 {
    return baselineFromFaceMetrics(faceMetricsInput(face, 1), cell_h);
}

pub const ShapingFace = struct {
    face: FtFace,
    hb_font: ?HbFont,
    owns_face: bool,
};

pub fn acquireShapingFaceLocked(self: anytype, face_id: render.FontFaceId) ?ShapingFace {
    const state = textState(self);
    if (face_id.value == primary_face_id) {
        const face = state.ft_face orelse return null;
        return .{ .face = face, .hb_font = state.hb_font, .owns_face = false };
    }
    const fallback_index = if (face_id.value >= 2) face_id.value - 2 else return null;
    const slot = fallbackSlot(self, fallback_index) orelse return null;
    const face = state.fallback_faces[slot] orelse return null;
    return .{ .face = face, .hb_font = state.fallback_hb_fonts[slot], .owns_face = false };
}

pub fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    return c_api.shapeGlyphId(hb_font, face, codepoint);
}

fn ensureFreeTypeLibraryLocked(self: anytype) bool {
    const state = textState(self);
    if (state.ft_lib != null) return true;
    var lib: FtLibrary = undefined;
    if (c.FT_Init_FreeType(&lib) != 0) return false;
    state.ft_lib = lib;
    return true;
}

fn fallbackProviderShapeRun(context: anytype, allocator: std.mem.Allocator, run: render.ResolvedRun, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics, window: ClusterWindow) anyerror!render.Text.ShapeRun.OwnedShapedRun {
    const glyphs = try allocator.alloc(render.GlyphInstance, window.len());
    errdefer allocator.free(glyphs);
    for (window.slice(clusters), 0..) |cluster, idx| {
        const glyph_id = providerGlyphId(context, run.run.font.face_id, cluster.first_cp);
        const shaped_advance = providerGlyphAdvance(context, run.run.font.face_id, glyph_id, cell_metrics);
        const advance_px = if (isIconCodepoint(cluster.first_cp)) @max(shaped_advance, providerGlyphVisualWidth(context, run.run.font.face_id, glyph_id)) else shaped_advance;
        glyphs[idx] = .{ .face_id = run.run.font.face_id, .glyph_id = glyph_id, .cluster_index = window.start + @as(u32, @intCast(idx)), .x_offset_px = 0, .y_offset_px = 0, .x_advance_px = advance_px };
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

fn textForCluster(text_cache_view: render.LineTextCache, cluster: render.CellCluster) render.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache_view.texts.len) return text_cache_view.texts[idx];
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

fn glyphAdvanceFromFace(self: anytype, face: FtFace, glyph_id: u32, cell_metrics: render.CellMetrics) f32 {
    if (!setFacePixelHeight(self, face)) return @floatFromInt(cell_metrics.cell_w_px);
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_DEFAULT) != 0) return @floatFromInt(cell_metrics.cell_w_px);
    if (face.*.glyph == null) return @floatFromInt(cell_metrics.cell_w_px);
    return advancePx(@intCast(face.*.glyph.*.advance.x), cell_metrics.cell_w_px);
}

fn setFacePixelHeight(self: anytype, face: FtFace) bool {
    return c.FT_Set_Pixel_Sizes(face, 0, @max(configView(self).font_size_px, 1)) == 0;
}

fn cellMetricsFromFace(face: FtFace, font_size_px: u16) render.CellMetrics {
    return cellMetricsFromFaceMetrics(faceMetricsInput(face, font_size_px));
}

fn faceMetricsInput(face: FtFace, font_size_px: u16) contract.FaceMetrics26Dot6 {
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
    const state = textState(self);
    for (state.fallback_faces, 0..) |face_opt, i| {
        c_api.destroyHbFont(state.fallback_hb_fonts[i]);
        state.fallback_hb_fonts[i] = null;
        if (face_opt != null) {
            _ = c.FT_Done_Face(face_opt.?);
            state.fallback_faces[i] = null;
        }
    }
}

fn gatherShapeRunInput(allocator: std.mem.Allocator, text_cache_view: render.LineTextCache, clusters: []const render.CellCluster, window: ClusterWindow) !ShapeRunInput {
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

fn buildProviderShapedRun(allocator: std.mem.Allocator, run: render.ResolvedRun, clusters: []const render.CellCluster, cell_metrics: render.CellMetrics, face: FtFace, infos: [*c]c.hb_glyph_info_t, positions: [*c]c.hb_glyph_position_t, glyph_count: c_uint, cluster_map: []const u32) !render.Text.ShapeRun.OwnedShapedRun {
    const glyphs = try allocator.alloc(render.GlyphInstance, glyph_count);
    errdefer allocator.free(glyphs);
    for (glyphs, 0..) |*glyph, idx| {
        const info = infos[idx];
        const pos = positions[idx];
        const cluster_cp_idx = @min(@as(u32, info.cluster), @as(u32, @intCast(cluster_map.len - 1)));
        const cluster_idx = cluster_map[@intCast(cluster_cp_idx)];
        const shaped_advance = advancePx(@intCast(pos.x_advance), cell_metrics.cell_w_px);
        const advance_px = if (cluster_idx < clusters.len and isIconCodepoint(clusters[@intCast(cluster_idx)].first_cp)) @max(shaped_advance, glyphVisualWidthPxLocked(face, info.codepoint)) else shaped_advance;
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

fn fallbackSlot(self: anytype, fallback_index: u32) ?usize {
    const state = textState(self);
    if (fallback_index >= state.fallback_font_paths_len) return null;
    return @intCast(fallback_index);
}

fn useDeterministicTestTextFallback(self: anytype) bool {
    return builtin.is_test and configView(self).font_path == null and textState(self).fallback_font_paths_len == 0;
}

fn defaultCellMetrics(font_px: u16) render.CellMetrics {
    const h = @max(font_px, 1);
    return .{
        .cell_w_px = @max(@divFloor(h, 2), 1),
        .cell_h_px = h,
        .baseline_px = @intCast(@max(h - @divFloor(h, 5), 1)),
        .box_thickness_px = defaultBoxThickness(h),
    };
}

fn defaultBoxThickness(_: u16) u16 {
    return 2;
}

fn baselineFromFaceMetrics(input: contract.FaceMetrics26Dot6, cell_h: u16) i32 {
    const raw = @divTrunc(input.ascender, 64);
    return std.math.clamp(raw, 1, @as(i32, @intCast(@max(cell_h, 1))));
}

fn advancePx(value_26_6: i32, fallback_cell_w: u16) f32 {
    if (value_26_6 <= 0) return @floatFromInt(@max(fallback_cell_w, 1));
    return @as(f32, @floatFromInt(value_26_6)) / 64.0;
}

fn cellMetricsFromFaceMetrics(input: contract.FaceMetrics26Dot6) render.CellMetrics {
    const cell_h: u16 = @intCast(@max(@divTrunc(input.height + 63, 64), @as(i32, input.fallback_font_px)));
    const fallback_w = @max(@divFloor(input.fallback_font_px, 2), 1);
    const cell_w: u16 = @intCast(@max(@divTrunc(input.max_advance + 63, 64), @as(i32, fallback_w)));
    return .{
        .cell_w_px = cell_w,
        .cell_h_px = cell_h,
        .baseline_px = @intCast(baselineFromFaceMetrics(input, cell_h)),
        .box_thickness_px = defaultBoxThickness(cell_h),
    };
}
