//! Responsibility: define backend-shared text cache payloads.
//! Ownership: render-core backend shared layer owns common text cache data.
//! Reason: avoids duplicating cache keys and entries across GL backend variants.

const std = @import("std");
const render_core = @import("../../render_core.zig").RenderCore;

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
        run: render_core.ResolvedRun,
    ) !?render_core.Text.ShapeRun.OwnedShapedRun {
        const cached = self.map.get(key) orelse return null;
        const glyphs = try allocator.alloc(render_core.GlyphInstance, cached.len);
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

    pub fn putRun(self: *ShapeRunCache, key: ShapeRunKey, run: render_core.Text.ShapeRun.OwnedShapedRun) !void {
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

pub fn hashCellText(text: render_core.CellText) u64 {
    var hasher = std.hash.Wyhash.init(0x54455854);
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    const len: u32 = @intCast(cps.len);
    hasher.update(std.mem.asBytes(&len));
    for (cps) |cp| hasher.update(std.mem.asBytes(&cp));
    return hasher.final();
}

pub fn hashRunText(text_cache: render_core.LineTextCache, clusters: []const render_core.CellCluster) u64 {
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

fn textForCluster(text_cache: render_core.LineTextCache, cluster: render_core.CellCluster) render_core.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < text_cache.texts.len) return text_cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}
