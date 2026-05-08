//! Responsibility: extract terminal cell text clusters.
//! Ownership: render-core text engine.
//! Reason: preserve grapheme/cell-span semantics before shaping.

const std = @import("std");
const contract = @import("../text_contract.zig");
const render_types = @import("../render_types.zig");
const scene_mod = @import("scene.zig");

const VS15: u32 = 0xfe0e;
const VS16: u32 = 0xfe0f;

pub const CellTextInput = struct {
    codepoints: []const u32,
    fg: contract.Rgba8,
    bg: contract.Rgba8,
    underline_color: contract.Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    style: contract.FontStyle = .regular,
    presentation: contract.TextPresentation = .any,
    underline: bool = false,
    underline_style: contract.UnderlineStyle = .straight,
    strikethrough: bool = false,
    cell_span: u8 = 1,
    continuation: bool = false,
};

pub const OwnedLineTextCache = struct {
    allocator: std.mem.Allocator,
    texts: []contract.CellText,
    codepoints: []u32,

    pub fn view(self: OwnedLineTextCache) contract.LineTextCache {
        return .{ .texts = self.texts };
    }

    pub fn deinit(self: *OwnedLineTextCache) void {
        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.* = undefined;
    }
};

pub const OwnedRenderableCells = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,

    pub fn deinit(self: *OwnedRenderableCells) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedClusters = struct {
    allocator: std.mem.Allocator,
    clusters: []contract.CellCluster,

    pub fn deinit(self: *OwnedClusters) void {
        self.allocator.free(self.clusters);
        self.* = undefined;
    }
};

pub const OwnedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ResolvedRun,

    pub fn deinit(self: *OwnedRuns) void {
        self.allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const LegacySparseCells = struct {
    text_cache: OwnedLineTextCache,
    renderable: OwnedRenderableCells,

    pub fn deinit(self: *LegacySparseCells) void {
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

pub fn singleCodepointText(id: u32, cp: u32) contract.CellText {
    return .{
        .id = .{ .value = id },
        .first_cp = cp,
        .codepoints = &.{cp},
    };
}

pub fn clusterForCell(text: contract.CellText, first_cell: u32, span: u8, style: contract.FontStyle) contract.CellCluster {
    return .{
        .text_id = text.id,
        .first_cell = first_cell,
        .cell_span = span,
        .first_cp = text.first_cp,
        .style = style,
        .presentation = .any,
    };
}

pub fn buildLineTextCacheFromCells(allocator: std.mem.Allocator, cells: []const render_types.CellInput) !OwnedLineTextCache {
    const texts = try allocator.alloc(contract.CellText, cells.len);
    errdefer allocator.free(texts);
    const codepoints = try allocator.alloc(u32, cells.len);
    errdefer allocator.free(codepoints);

    for (cells, 0..) |cell, idx| {
        codepoints[idx] = cell.codepoint;
        texts[idx] = .{
            .id = .{ .value = @intCast(idx) },
            .first_cp = cell.codepoint,
            .codepoints = codepoints[idx .. idx + 1],
        };
    }

    return .{ .allocator = allocator, .texts = texts, .codepoints = codepoints };
}

pub fn buildSparseCellsWithDamage(
    allocator: std.mem.Allocator,
    cells: []const render_types.CellInput,
    grid_metrics: contract.GridMetrics,
    damage: scene_mod.DamageInput,
) !LegacySparseCells {
    var count: usize = 0;
    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        if (!includeSpan(damage, grid_metrics, @intCast(idx), inferredCellSpan(cells, idx))) continue;
        count += 1;
    }

    const renderable = try allocator.alloc(contract.RenderableCell, count);
    errdefer allocator.free(renderable);
    var unique_codepoints = std.AutoHashMap(u32, u32).init(allocator);
    defer unique_codepoints.deinit();
    var unique_count: usize = 0;

    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        if (!includeSpan(damage, grid_metrics, @intCast(idx), inferredCellSpan(cells, idx))) continue;
        const entry = try unique_codepoints.getOrPut(cell.codepoint);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(unique_count);
            unique_count += 1;
        }
    }

    const texts = try allocator.alloc(contract.CellText, unique_count);
    errdefer allocator.free(texts);
    const codepoints = try allocator.alloc(u32, unique_count);
    errdefer allocator.free(codepoints);

    var iterator = unique_codepoints.iterator();
    while (iterator.next()) |entry| {
        const text_idx = @as(usize, @intCast(entry.value_ptr.*));
        codepoints[text_idx] = entry.key_ptr.*;
        texts[text_idx] = .{
            .id = .{ .value = entry.value_ptr.* },
            .first_cp = entry.key_ptr.*,
            .codepoints = codepoints[text_idx .. text_idx + 1],
        };
    }

    var out_idx: usize = 0;
    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        const first_cell: u32 = @intCast(idx);
        const span = inferredCellSpan(cells, idx);
        if (!includeSpan(damage, grid_metrics, first_cell, span)) continue;
        const text_id = unique_codepoints.get(cell.codepoint).?;
        renderable[out_idx] = .{
            .text_id = .{ .value = text_id },
            .first_cell = first_cell,
            .cell_span = span,
            .style = .regular,
            .presentation = .any,
            .fg = cell.fg,
            .bg = cell.bg,
            .underline_color = cell.underline_color,
            .underline_style = switch (cell.underline_style) {
                .straight => .straight,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            },
            .underline = cell.underline,
            .strikethrough = cell.strikethrough,
            .continuation = false,
        };
        out_idx += 1;
    }

    return .{
        .text_cache = .{ .allocator = allocator, .texts = texts, .codepoints = codepoints },
        .renderable = .{ .allocator = allocator, .cells = renderable },
    };
}

pub fn buildLineTextCacheFromInputs(allocator: std.mem.Allocator, inputs: []const CellTextInput) !OwnedLineTextCache {
    var total_codepoints: usize = 0;
    for (inputs) |input| total_codepoints += @max(input.codepoints.len, 1);

    const texts = try allocator.alloc(contract.CellText, inputs.len);
    errdefer allocator.free(texts);
    const codepoints = try allocator.alloc(u32, total_codepoints);
    errdefer allocator.free(codepoints);

    var text_count: usize = 0;
    var cp_offset: usize = 0;
    for (inputs, 0..) |input, idx| {
        const cps = normalizedCodepoints(input.codepoints);
        if (findText(texts[0..text_count], cps)) |existing| {
            texts[idx] = texts[existing];
            continue;
        }

        const len = cps.len;
        @memcpy(codepoints[cp_offset .. cp_offset + len], cps);
        const text = contract.CellText{
            .id = .{ .value = @intCast(text_count) },
            .first_cp = cps[0],
            .codepoints = codepoints[cp_offset .. cp_offset + len],
        };
        texts[text_count] = text;
        texts[idx] = text;
        text_count += 1;
        cp_offset += len;
    }

    return .{
        .allocator = allocator,
        .texts = try allocator.realloc(texts, text_count),
        .codepoints = codepoints,
    };
}

fn normalizedCodepoints(cps: []const u32) []const u32 {
    return if (cps.len == 0) &.{0} else cps;
}

fn findText(texts: []const contract.CellText, cps: []const u32) ?usize {
    for (texts, 0..) |text, idx| {
        if (std.mem.eql(u32, text.codepoints, cps)) return idx;
    }
    return null;
}

pub fn buildRenderableCellsFromCells(
    allocator: std.mem.Allocator,
    cells: []const render_types.CellInput,
    cache: contract.LineTextCache,
) !OwnedRenderableCells {
    const out = try allocator.alloc(contract.RenderableCell, cells.len);
    errdefer allocator.free(out);

    for (cells, 0..) |cell, idx| {
        const text = cache.texts[idx];
        out[idx] = .{
            .text_id = text.id,
            .first_cell = @intCast(idx),
            .cell_span = inferredCellSpan(cells, idx),
            .style = .regular,
            .presentation = .any,
            .fg = cell.fg,
            .bg = cell.bg,
            .underline_color = cell.underline_color,
            .underline_style = switch (cell.underline_style) {
                .straight => .straight,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            },
            .underline = cell.underline,
            .strikethrough = cell.strikethrough,
            .continuation = cell.continuation,
        };
    }

    return .{ .allocator = allocator, .cells = out };
}

pub fn buildRenderableCellsFromInputs(
    allocator: std.mem.Allocator,
    inputs: []const CellTextInput,
    cache: contract.LineTextCache,
) !OwnedRenderableCells {
    const out = try allocator.alloc(contract.RenderableCell, inputs.len);
    errdefer allocator.free(out);

    for (inputs, 0..) |input, idx| {
        const cps = normalizedCodepoints(input.codepoints);
        const text_id = findText(cache.texts, cps) orelse 0;
        out[idx] = .{
            .text_id = .{ .value = @intCast(text_id) },
            .first_cell = @intCast(idx),
            .cell_span = @max(@max(input.cell_span, 1), inferredInputCellSpan(inputs, idx)),
            .style = input.style,
            .presentation = detectPresentation(cps, input.presentation),
            .fg = input.fg,
            .bg = input.bg,
            .underline_color = input.underline_color,
            .underline_style = input.underline_style,
            .underline = input.underline,
            .strikethrough = input.strikethrough,
            .continuation = input.continuation,
        };
    }

    return .{ .allocator = allocator, .cells = out };
}

pub fn detectPresentation(cps: []const u32, fallback: contract.TextPresentation) contract.TextPresentation {
    for (cps) |cp| {
        if (cp == VS16) return .emoji;
        if (cp == VS15) return .text;
    }
    return fallback;
}

pub fn extractClusters(allocator: std.mem.Allocator, cells: []const contract.RenderableCell, cache: contract.LineTextCache) !OwnedClusters {
    return extractClustersWithDamage(allocator, cells, cache, .{ .cols = @intCast(@max(cells.len, 1)), .rows = 1 }, .{});
}

pub fn extractClustersWithDamage(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
    damage: scene_mod.DamageInput,
) !OwnedClusters {
    var count: usize = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const text = textForCell(cell, cache);
        if (isBlankText(text)) continue;
        count += 1;
    }

    const clusters = try allocator.alloc(contract.CellCluster, count);
    errdefer allocator.free(clusters);
    var out_idx: usize = 0;
    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const text = textForCell(cell, cache);
        if (isBlankText(text)) continue;
        clusters[out_idx] = .{
            .text_id = cell.text_id,
            .first_cell = cell.first_cell,
            .cell_span = @max(cell.cell_span, inferredRenderableCellSpan(cells, idx)),
            .first_cp = text.first_cp,
            .style = cell.style,
            .presentation = cell.presentation,
        };
        out_idx += 1;
    }

    return .{ .allocator = allocator, .clusters = clusters };
}

fn includeSpan(damage: scene_mod.DamageInput, grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) bool {
    if (damage.full) return true;
    const row_count = @as(usize, grid_metrics.rows);
    const valid = damage.dirty_rows.len == row_count and
        damage.dirty_cols_start.len == row_count and
        damage.dirty_cols_end.len == row_count;
    if (!valid) return true;

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row = @as(usize, @intCast(first_cell / cols));
    if (row >= damage.dirty_rows.len or !damage.dirty_rows[row]) return false;
    const start_col = @as(u16, @intCast(first_cell % cols));
    const end_col = start_col +| (@max(cell_span, 1) - 1);
    const dirty_start = damage.dirty_cols_start[row];
    const dirty_end = damage.dirty_cols_end[row];
    return !(end_col < dirty_start or start_col > dirty_end);
}

fn textForCell(cell: contract.RenderableCell, cache: contract.LineTextCache) contract.CellText {
    const text_idx = @as(usize, @intCast(cell.text_id.value));
    if (text_idx < cache.texts.len) return cache.texts[text_idx];
    return .{ .id = cell.text_id, .first_cp = 0, .codepoints = &.{} };
}

fn isBlankText(text: contract.CellText) bool {
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    for (cps) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

fn inferredCellSpan(cells: []const render_types.CellInput, idx: usize) u8 {
    var span: usize = 1;
    while (idx + span < cells.len and cells[idx + span].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn inferredInputCellSpan(inputs: []const CellTextInput, idx: usize) u8 {
    var span: usize = 1;
    while (idx + span < inputs.len and inputs[idx + span].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn inferredRenderableCellSpan(cells: []const contract.RenderableCell, idx: usize) u8 {
    var span: usize = 1;
    while (idx + span < cells.len and cells[idx + span].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

pub fn buildProvisionalRuns(allocator: std.mem.Allocator, clusters: []const contract.CellCluster, face_id: contract.FontFaceId) !OwnedRuns {
    if (clusters.len == 0) {
        return .{ .allocator = allocator, .runs = try allocator.alloc(contract.ResolvedRun, 0) };
    }

    var run_count: usize = 1;
    var prev = clusters[0];
    for (clusters[1..]) |cluster| {
        if (cluster.style != prev.style or cluster.presentation != prev.presentation) run_count += 1;
        prev = cluster;
    }

    const runs = try allocator.alloc(contract.ResolvedRun, run_count);
    errdefer allocator.free(runs);
    var run_idx: usize = 0;
    var start: usize = 0;
    prev = clusters[0];
    for (clusters[1..], 1..) |cluster, idx| {
        if (cluster.style != prev.style or cluster.presentation != prev.presentation) {
            runs[run_idx] = resolvedRun(@intCast(start), @intCast(idx - start), face_id, prev.style, prev.presentation);
            run_idx += 1;
            start = idx;
        }
        prev = cluster;
    }
    runs[run_idx] = resolvedRun(@intCast(start), @intCast(clusters.len - start), face_id, prev.style, prev.presentation);

    return .{ .allocator = allocator, .runs = runs };
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: contract.FontFaceId, style: contract.FontStyle, presentation: contract.TextPresentation) contract.ResolvedRun {
    return .{ .run = .{
        .cluster_start = cluster_start,
        .cluster_count = cluster_count,
        .font = .{
            .face_id = face_id,
            .style = style,
            .presentation = presentation,
        },
    } };
}

test "single codepoint text preserves first codepoint" {
    const text = singleCodepointText(7, 'A');
    try @import("std").testing.expectEqual(@as(u32, 'A'), text.first_cp);
}

test "cell inputs build text cache renderable cells clusters and runs" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black, .continuation = true },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &legacy);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &legacy, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();
    var runs = try buildProvisionalRuns(allocator, clusters.clusters, .{ .value = 1 });
    defer runs.deinit();

    try std.testing.expectEqual(@as(usize, 3), cache.texts.len);
    try std.testing.expectEqual(@as(usize, 2), clusters.clusters.len);
    try std.testing.expectEqual(@as(usize, 1), runs.runs.len);
    try std.testing.expectEqual(@as(u32, 2), runs.runs[0].run.cluster_count);
}

test "blank cells do not produce text clusters" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = ' ', .fg = white, .bg = black },
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &legacy);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &legacy, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(usize, 1), clusters.clusters.len);
    try std.testing.expectEqual(@as(u32, 'A'), clusters.clusters[0].first_cp);
    try std.testing.expectEqual(@as(u32, 1), clusters.clusters[0].first_cell);
}

test "continuation cells expand base cell spans" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'x', .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &legacy);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &legacy, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(u8, 2), renderable.cells[0].cell_span);
    try std.testing.expectEqual(@as(usize, 2), clusters.clusters.len);
    try std.testing.expectEqual(@as(u32, 0), clusters.clusters[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), clusters.clusters[0].cell_span);
    try std.testing.expectEqual(@as(u32, 2), clusters.clusters[1].first_cell);
}

test "partial damage filters clean clusters before shaping" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
        .{ .codepoint = 'D', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 0, 0 };

    var cache = try buildLineTextCacheFromCells(allocator, &legacy);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &legacy, cache.view());
    defer renderable.deinit();
    var clusters = try extractClustersWithDamage(allocator, renderable.cells, cache.view(), .{ .cols = 2, .rows = 2 }, .{
        .full = false,
        .dirty_rows = &dirty_rows,
        .dirty_cols_start = &dirty_starts,
        .dirty_cols_end = &dirty_ends,
    });
    defer clusters.deinit();

    try std.testing.expectEqual(@as(usize, 1), clusters.clusters.len);
    try std.testing.expectEqual(@as(u32, 2), clusters.clusters[0].first_cell);
    try std.testing.expectEqual(@as(u32, 'C'), clusters.clusters[0].first_cp);
}

test "sparse cells keep only damaged base cells" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ true, false };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 1, 0 };

    var sparse = try buildSparseCellsWithDamage(allocator, &legacy, .{ .cols = 2, .rows = 2 }, .{
        .full = false,
        .dirty_rows = &dirty_rows,
        .dirty_cols_start = &dirty_starts,
        .dirty_cols_end = &dirty_ends,
    });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(usize, 1), sparse.renderable.cells.len);
    try std.testing.expectEqual(@as(usize, 1), sparse.text_cache.texts.len);
    try std.testing.expectEqual(@as(u32, 0), sparse.renderable.cells[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), sparse.renderable.cells[0].cell_span);
    try std.testing.expectEqual(@as(u32, 'A'), sparse.text_cache.texts[0].first_cp);
}

test "sparse cells intern repeated codepoints" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const legacy = [_]render_types.CellInput{
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Y', .fg = white, .bg = black },
    };

    var sparse = try buildSparseCellsWithDamage(allocator, &legacy, .{ .cols = 3, .rows = 1 }, .{ .full = true });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(usize, 2), sparse.text_cache.texts.len);
    try std.testing.expectEqual(sparse.renderable.cells[0].text_id.value, sparse.renderable.cells[1].text_id.value);
    try std.testing.expect(sparse.renderable.cells[2].text_id.value != sparse.renderable.cells[0].text_id.value);
}

test "rich cell text interning deduplicates codepoint sequences" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const underline_i = [_]u32{ 'i', 0x0332, 0x0308 };
    const inputs = [_]CellTextInput{
        .{ .codepoints = &underline_i, .fg = white, .bg = black },
        .{ .codepoints = &underline_i, .fg = white, .bg = black },
    };
    var cache = try buildLineTextCacheFromInputs(allocator, &inputs);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromInputs(allocator, &inputs, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(usize, 1), cache.texts.len);
    try std.testing.expectEqual(@as(usize, 6), cache.codepoints.len);
    try std.testing.expectEqual(cache.texts[0].id.value, renderable.cells[1].text_id.value);
    try std.testing.expectEqual(@as(u32, 'i'), clusters.clusters[0].first_cp);
}

test "rich cell text detects emoji and text presentation selectors" {
    const allocator = std.testing.allocator;
    const white = render_types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const text_x = [_]u32{ 0x2716, VS15 };
    const emoji_x = [_]u32{ 0x2716, VS16 };
    const inputs = [_]CellTextInput{
        .{ .codepoints = &text_x, .fg = white, .bg = black },
        .{ .codepoints = &emoji_x, .fg = white, .bg = black },
    };
    var cache = try buildLineTextCacheFromInputs(allocator, &inputs);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromInputs(allocator, &inputs, cache.view());
    defer renderable.deinit();
    try std.testing.expectEqual(contract.TextPresentation.text, renderable.cells[0].presentation);
    try std.testing.expectEqual(contract.TextPresentation.emoji, renderable.cells[1].presentation);
}
