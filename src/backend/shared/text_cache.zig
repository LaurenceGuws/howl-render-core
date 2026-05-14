
const std = @import("std");
const render = @import("../../render.zig").Render;

pub const FaceTextKey = struct {
    face_id: u32,
    text_hash: u64,
};

pub const ShapeRunKey = struct {
    face_id: u32,
    run_hash: u64,
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
};

pub const GlyphCellKey = struct {
    face_id: u32,
    codepoint: u32,
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
};

pub const GlyphCellValue = struct {
    glyph_id: u32,
    advance_px: f32,
};

pub const CachedGlyph = struct {
    glyph_id: u32,
    cluster_offset: u32,
    x_offset_px: f32,
    y_offset_px: f32,
    x_advance_px: f32,
};

pub const FaceTextCache = struct {
    map: std.AutoHashMap(FaceTextKey, bool),

    pub fn init(allocator: std.mem.Allocator) FaceTextCache {
        return .{ .map = std.AutoHashMap(FaceTextKey, bool).init(allocator) };
    }

    pub fn deinit(self: *FaceTextCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *FaceTextCache) void {
        self.map.clearRetainingCapacity();
    }
};

pub const ShapeRunCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(ShapeRunKey, []CachedGlyph),

    pub fn init(allocator: std.mem.Allocator) ShapeRunCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(ShapeRunKey, []CachedGlyph).init(allocator),
        };
    }

    pub fn deinit(self: *ShapeRunCache) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *ShapeRunCache) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.map.clearRetainingCapacity();
    }

    pub fn getOwnedRun(
        self: *const ShapeRunCache,
        allocator: std.mem.Allocator,
        key: ShapeRunKey,
        run: render.ResolvedRun,
    ) !?render.Text.ShapeRun.OwnedShapedRun {
        const cached = self.map.get(key) orelse return null;
        const glyphs = try allocator.alloc(render.GlyphInstance, cached.len);
        for (cached, 0..) |glyph, idx| {
            glyphs[idx] = .{
                .face_id = run.run.font.face_id,
                .glyph_id = glyph.glyph_id,
                .cluster_index = run.run.cluster_start + glyph.cluster_offset,
                .x_offset_px = glyph.x_offset_px,
                .y_offset_px = glyph.y_offset_px,
                .x_advance_px = glyph.x_advance_px,
            };
        }
        return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
    }

    pub fn putRun(self: *ShapeRunCache, key: ShapeRunKey, run: render.Text.ShapeRun.OwnedShapedRun) !void {
        const templates = try self.allocator.alloc(CachedGlyph, run.glyphs.len);
        errdefer self.allocator.free(templates);
        for (run.glyphs, 0..) |glyph, idx| {
            templates[idx] = .{
                .glyph_id = glyph.glyph_id,
                .cluster_offset = glyph.cluster_index - run.run.run.cluster_start,
                .x_offset_px = glyph.x_offset_px,
                .y_offset_px = glyph.y_offset_px,
                .x_advance_px = glyph.x_advance_px,
            };
        }
        const entry = try self.map.getOrPut(key);
        if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = templates;
    }
};

pub const GlyphCellCache = struct {
    map: std.AutoHashMap(GlyphCellKey, GlyphCellValue),

    pub fn init(allocator: std.mem.Allocator) GlyphCellCache {
        return .{ .map = std.AutoHashMap(GlyphCellKey, GlyphCellValue).init(allocator) };
    }

    pub fn deinit(self: *GlyphCellCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *GlyphCellCache) void {
        self.map.clearRetainingCapacity();
    }
};

pub fn hashCellText(text: render.CellText) u64 {
    var hasher = std.hash.Wyhash.init(0x54455854);
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    const len: u32 = @intCast(cps.len);
    hasher.update(std.mem.asBytes(&len));
    for (cps) |cp| hasher.update(std.mem.asBytes(&cp));
    return hasher.final();
}

pub fn hashRunText(text_cache: render.LineTextCache, clusters: []const render.CellCluster) u64 {
    var hasher = std.hash.Wyhash.init(0x52554e54);
    const len: u32 = @intCast(clusters.len);
    hasher.update(std.mem.asBytes(&len));
    for (clusters) |cluster| {
        const text = textForCluster(text_cache, cluster);
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        const cp_len: u32 = @intCast(cps.len);
        hasher.update(std.mem.asBytes(&cp_len));
        for (cps) |cp| hasher.update(std.mem.asBytes(&cp));
        hasher.update(std.mem.asBytes(&cluster.cell_span));
    }
    return hasher.final();
}

fn textForCluster(text_cache: render.LineTextCache, cluster: render.CellCluster) render.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache.texts.len) return text_cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}
