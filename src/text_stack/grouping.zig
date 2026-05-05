//! Responsibility: map shaped glyphs back to terminal cell groups.
//! Ownership: render-core text engine.
//! Reason: ligatures, combining marks, and wide glyphs are terminal text semantics.

const std = @import("std");
const contract = @import("../text_contract.zig");
const font_resolver = @import("font_resolver.zig");
const metrics = @import("metrics.zig");
const shape_run = @import("shape_run.zig");
const sprite_key = @import("sprite_key.zig");

pub const OwnedGlyphGroups = struct {
    allocator: std.mem.Allocator,
    groups: []contract.GlyphGroup,

    pub fn deinit(self: *OwnedGlyphGroups) void {
        self.allocator.free(self.groups);
        self.* = undefined;
    }
};

pub const GroupingPolicy = struct {
    cursor_cell: ?u32 = null,
    suppress_ligature_at_cursor: bool = false,
};

pub fn singleCellGroup(first_cell: u32, glyphs: []const contract.GlyphInstance, key: contract.SpriteKey) contract.GlyphGroup {
    return .{
        .first_cell = first_cell,
        .cell_span = 1,
        .glyphs = glyphs,
        .sprite_key = key,
        .kind = .normal,
    };
}

pub fn groupShapedRuns(
    allocator: std.mem.Allocator,
    shaped_runs: []const shape_run.OwnedShapedRun,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
) !OwnedGlyphGroups {
    return groupShapedRunsWithPolicy(allocator, shaped_runs, clusters, cell_metrics, .{});
}

pub fn groupShapedRunsWithPolicy(
    allocator: std.mem.Allocator,
    shaped_runs: []const shape_run.OwnedShapedRun,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
    policy: GroupingPolicy,
) !OwnedGlyphGroups {
    var count: usize = 0;
    for (shaped_runs) |run| {
        var idx: usize = 0;
        while (idx < run.glyphs.len) {
            count += 1;
            const cluster_index = run.glyphs[idx].cluster_index;
            idx += 1;
            while (idx < run.glyphs.len and run.glyphs[idx].cluster_index == cluster_index) : (idx += 1) {}
        }
    }

    const groups = try allocator.alloc(contract.GlyphGroup, count);
    errdefer allocator.free(groups);
    var out_idx: usize = 0;

    for (shaped_runs) |run| {
        var idx: usize = 0;
        while (idx < run.glyphs.len) {
            const cluster_index = run.glyphs[idx].cluster_index;
            const cluster_idx = @as(usize, @intCast(cluster_index));
            std.debug.assert(cluster_idx < clusters.len);
            const cluster = clusters[cluster_idx];
            const start = idx;
            idx += 1;
            while (idx < run.glyphs.len and run.glyphs[idx].cluster_index == cluster_index) : (idx += 1) {}
            const glyph_slice = run.glyphs[start..idx];
            const next_cluster_exclusive = if (idx < run.glyphs.len)
                @as(usize, @intCast(run.glyphs[idx].cluster_index))
            else
                @as(usize, @intCast(run.run.run.cluster_start + run.run.run.cluster_count));
            const inferred_cell_span = applyGroupingPolicy(cellSpanForClusterRange(clusters, cluster_idx, next_cluster_exclusive), cluster.first_cell, policy);
            groups[out_idx] = .{
                .first_cell = cluster.first_cell,
                .cell_span = inferred_cell_span,
                .glyphs = glyph_slice,
                .placement = metrics.groupPlacement(glyph_slice, cell_metrics, inferred_cell_span),
                .sprite_key = sprite_key.hashGlyphSequence(run.run.run.font.face_id, glyph_slice, inferred_cell_span),
                .kind = classifyFontGroup(cluster, glyph_slice, inferred_cell_span),
            };
            out_idx += 1;
        }
    }

    std.debug.assert(out_idx == groups.len);
    return .{ .allocator = allocator, .groups = groups };
}

fn applyGroupingPolicy(cell_span: u8, first_cell: u32, policy: GroupingPolicy) u8 {
    if (!policy.suppress_ligature_at_cursor) return cell_span;
    const cursor_cell = policy.cursor_cell orelse return cell_span;
    if (cursor_cell <= first_cell) return cell_span;
    const end_cell = first_cell + @as(u32, @max(cell_span, 1));
    if (cursor_cell >= end_cell) return cell_span;
    return @intCast(@max(cursor_cell - first_cell, 1));
}

pub fn groupSpriteRoutes(
    allocator: std.mem.Allocator,
    routes: []const font_resolver.SpriteRouteHit,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
) !OwnedGlyphGroups {
    const groups = try allocator.alloc(contract.GlyphGroup, routes.len);
    errdefer allocator.free(groups);
    for (routes, 0..) |route, idx| {
        const cluster_idx = @as(usize, @intCast(route.cluster_index));
        std.debug.assert(cluster_idx < clusters.len);
        const cluster = clusters[cluster_idx];
        const cell_span = spriteRouteCellSpan(route.route, clusters, cluster_idx);
        groups[idx] = .{
            .first_cell = cluster.first_cell,
            .cell_span = cell_span,
            .glyphs = &.{},
            .placement = metrics.groupPlacement(&.{}, cell_metrics, cell_span),
            .sprite_key = routeSpriteKey(route.route, cluster, cell_span),
            .kind = classifySpriteRoute(route.route),
        };
    }
    return .{ .allocator = allocator, .groups = groups };
}

pub fn concatGroups(allocator: std.mem.Allocator, font_groups: []const contract.GlyphGroup, sprite_groups: []const contract.GlyphGroup) !OwnedGlyphGroups {
    const groups = try allocator.alloc(contract.GlyphGroup, font_groups.len + sprite_groups.len);
    errdefer allocator.free(groups);
    @memcpy(groups[0..font_groups.len], font_groups);
    @memcpy(groups[font_groups.len..], sprite_groups);
    std.sort.block(contract.GlyphGroup, groups, {}, lessByCell);

    var out_len: usize = 0;
    var covered_until: u32 = 0;
    for (groups) |group| {
        if (out_len > 0 and group.first_cell < covered_until) continue;
        groups[out_len] = group;
        out_len += 1;
        covered_until = group.first_cell + @as(u32, @max(group.cell_span, 1));
    }
    return .{ .allocator = allocator, .groups = try allocator.realloc(groups, out_len) };
}

fn lessByCell(_: void, a: contract.GlyphGroup, b: contract.GlyphGroup) bool {
    return a.first_cell < b.first_cell;
}

fn classifyFontGroup(cluster: contract.CellCluster, glyphs: []const contract.GlyphInstance, cell_span: u8) contract.GlyphGroupKind {
    if (cluster.presentation == .emoji) return .emoji;
    if (cell_span > 1) return .ligature;
    if (glyphs.len > 1) return .ligature;
    if (isIconCodepoint(cluster.first_cp)) return .icon;
    return .normal;
}

fn cellSpanForClusterRange(clusters: []const contract.CellCluster, start_idx: usize, end_exclusive: usize) u8 {
    std.debug.assert(start_idx < clusters.len);
    const clamped_end = std.math.clamp(end_exclusive, start_idx + 1, clusters.len);
    const first = clusters[start_idx];
    const last = clusters[clamped_end - 1];
    const end_cell = last.first_cell + @as(u32, last.cell_span);
    return @intCast(@max(end_cell - first.first_cell, 1));
}

fn classifySpriteRoute(route: contract.SpecialSpriteRoute) contract.GlyphGroupKind {
    return switch (route) {
        .blank => .normal,
        .box, .block, .braille, .powerline, .legacy_computing => .box_fallback,
    };
}

fn routeSpriteKey(route: contract.SpecialSpriteRoute, cluster: contract.CellCluster, cell_span: u8) contract.SpriteKey {
    var h = std.hash.Wyhash.init(0x484f574c);
    const route_int: u8 = @intFromEnum(route);
    h.update(std.mem.asBytes(&route_int));
    h.update(std.mem.asBytes(&cluster.first_cp));
    h.update(std.mem.asBytes(&cell_span));
    return .{ .value = h.final() };
}

fn spriteRouteCellSpan(route: contract.SpecialSpriteRoute, clusters: []const contract.CellCluster, cluster_idx: usize) u8 {
    const cluster = clusters[cluster_idx];
    if (route != .powerline) return cluster.cell_span;
    var end_cell = cluster.first_cell + @as(u32, cluster.cell_span);
    var idx = cluster_idx + 1;
    while (idx < clusters.len) : (idx += 1) {
        const next = clusters[idx];
        if (next.first_cell != end_cell) break;
        if (!isPowerlineFollower(next)) break;
        end_cell += @as(u32, next.cell_span);
    }
    const span = @max(end_cell - cluster.first_cell, 1);
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn isPowerlineFollower(cluster: contract.CellCluster) bool {
    return cluster.first_cp == ' ' or cluster.first_cp == 0;
}

fn isIconCodepoint(cp: u32) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x1f100 and cp <= 0x1f1ff) or
        (cp >= 0xf0000 and cp <= 0xffffd) or
        (cp >= 0x100000 and cp <= 0x10fffd);
}

test "group shaped run creates one group per glyph cluster" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 4, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const text_cache = contract.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x' } }} };
    var shaped = try shape_run.shapeRun(std.testing.allocator, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 5 }, .style = .regular, .presentation = .any },
    } }, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    var groups = try groupShapedRuns(std.testing.allocator, &.{shaped}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    try std.testing.expectEqual(@as(u32, 4), groups.groups[0].first_cell);
    try std.testing.expect(groups.groups[0].sprite_key.value != 0);
}

test "grouping merges multiple glyphs for one cluster" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 1, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(contract.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 10, .cluster_index = 0, .x_advance_px = 5 },
            .{ .face_id = .{ .value = 1 }, .glyph_id = 11, .cluster_index = 0, .x_offset_px = 1, .x_advance_px = 0 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRuns(std.testing.allocator, &.{shaped_run}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups.groups[0].glyphs.len);
    try std.testing.expectEqual(contract.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping classifies emoji icon and sprite route groups" {
    const emoji_cluster = contract.CellCluster{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 2, .first_cp = 0x1f601, .style = .regular, .presentation = .emoji };
    const icon_cluster = contract.CellCluster{ .text_id = .{ .value = 1 }, .first_cell = 2, .cell_span = 1, .first_cp = 0xe0b0, .style = .regular, .presentation = .any };
    const glyphs = [_]contract.GlyphInstance{.{ .face_id = .{ .value = 1 }, .glyph_id = 1, .cluster_index = 0 }};
    try std.testing.expectEqual(contract.GlyphGroupKind.emoji, classifyFontGroup(emoji_cluster, &glyphs, emoji_cluster.cell_span));
    try std.testing.expectEqual(contract.GlyphGroupKind.icon, classifyFontGroup(icon_cluster, &glyphs, icon_cluster.cell_span));

    var sprite_groups = try groupSpriteRoutes(std.testing.allocator, &.{.{ .cluster_index = 1, .route = .box }}, &.{ emoji_cluster, icon_cluster }, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer sprite_groups.deinit();
    try std.testing.expectEqual(contract.GlyphGroupKind.box_fallback, sprite_groups.groups[0].kind);
    try std.testing.expect(sprite_groups.groups[0].sprite_key.value != 0);
}

test "powerline sprite route absorbs adjacent spacer cells" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 0xe0b0, .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = ' ', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    var sprite_groups = try groupSpriteRoutes(std.testing.allocator, &.{.{ .cluster_index = 0, .route = .powerline }}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer sprite_groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), sprite_groups.groups.len);
    try std.testing.expectEqual(@as(u8, 2), sprite_groups.groups[0].cell_span);
    try std.testing.expectEqual(@as(f32, 16), sprite_groups.groups[0].placement.advance_px);
}

test "powerline spacer absorption lets concat drop covered space group" {
    const powerline = contract.GlyphGroup{ .first_cell = 0, .cell_span = 2, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .box_fallback };
    const space = contract.GlyphGroup{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal };
    var merged = try concatGroups(std.testing.allocator, &.{space}, &.{powerline});
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 1), merged.groups.len);
    try std.testing.expectEqual(@as(u32, 0), merged.groups[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), merged.groups[0].cell_span);
}

test "grouping preserves multicell span as ligature-shaped group" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 2, .cell_span = 2, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const text_cache = contract.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x' } }} };
    var shaped = try shape_run.shapeRun(std.testing.allocator, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 5 }, .style = .regular, .presentation = .any },
    } }, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    var groups = try groupShapedRuns(std.testing.allocator, &.{shaped}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer groups.deinit();
    try std.testing.expectEqual(@as(u8, 2), groups.groups[0].cell_span);
    try std.testing.expectEqual(contract.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping classifies multiple glyphs in one cell as ligature group" {
    const cluster = contract.CellCluster{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any };
    const glyphs = [_]contract.GlyphInstance{
        .{ .face_id = .{ .value = 1 }, .glyph_id = 10, .cluster_index = 0 },
        .{ .face_id = .{ .value = 1 }, .glyph_id = 11, .cluster_index = 0 },
    };
    try std.testing.expectEqual(contract.GlyphGroupKind.ligature, classifyFontGroup(cluster, &glyphs, cluster.cell_span));
}

test "concat drops groups covered by previous multicell group" {
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 2, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .ligature },
        .{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal },
        .{ .first_cell = 2, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 3 }, .kind = .normal },
    };
    var merged = try concatGroups(std.testing.allocator, &groups, &.{});
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.groups.len);
    try std.testing.expectEqual(@as(u32, 0), merged.groups[0].first_cell);
    try std.testing.expectEqual(@as(u32, 2), merged.groups[1].first_cell);
}

test "grouping infers multicell span from next cluster boundary" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'f', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 2, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(contract.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 20, .cluster_index = 0, .x_advance_px = 10 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRuns(std.testing.allocator, &.{shaped_run}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    try std.testing.expectEqual(@as(u8, 2), groups.groups[0].cell_span);
    try std.testing.expectEqual(contract.GlyphGroupKind.ligature, groups.groups[0].kind);
}

test "grouping policy can suppress ligature span across cursor" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'f', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any },
    };
    const shaped_run = shape_run.OwnedShapedRun{
        .allocator = std.testing.allocator,
        .run = .{ .run = .{ .cluster_start = 0, .cluster_count = 2, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } },
        .glyphs = try std.testing.allocator.dupe(contract.GlyphInstance, &.{
            .{ .face_id = .{ .value = 1 }, .glyph_id = 20, .cluster_index = 0, .x_advance_px = 10 },
        }),
    };
    defer {
        var owned = shaped_run;
        owned.deinit();
    }
    var groups = try groupShapedRunsWithPolicy(std.testing.allocator, &.{shaped_run}, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cursor_cell = 1, .suppress_ligature_at_cursor = true });
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    try std.testing.expectEqual(@as(u8, 1), groups.groups[0].cell_span);
}
