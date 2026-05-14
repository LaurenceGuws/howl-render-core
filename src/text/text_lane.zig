
const std = @import("std");
const contract = @import("../text_contract.zig");
const symbol_map = @import("symbol_map.zig");

pub const TextLane = enum(u1) {
    normal,
    complex,
};

pub const ComplexLaneReason = enum(u3) {
    multi_codepoint,
    emoji_presentation,
    special_sprite,
    icon_codepoint,
    curly_underline,
};

pub const LaneClass = struct {
    lane: TextLane,
    complex_reason: ?ComplexLaneReason = null,

    pub fn normal() LaneClass {
        return .{ .lane = .normal };
    }

    pub fn complex(reason: ComplexLaneReason) LaneClass {
        return .{ .lane = .complex, .complex_reason = reason };
    }

    pub fn assertValid(self: LaneClass) void {
        switch (self.lane) {
            .normal => std.debug.assert(self.complex_reason == null),
            .complex => std.debug.assert(self.complex_reason != null),
        }
    }
};

pub const LegacyStageCounts = struct {
    normal: usize = 0,
    complex: usize = 0,
};

pub const LegacyPathReport = struct {
    resolved_clusters: LegacyStageCounts = .{},
    shaped_clusters: LegacyStageCounts = .{},
    grouped_groups: LegacyStageCounts = .{},
    scene_sprite_draws: LegacyStageCounts = .{},
};

pub const LaneReport = struct {
    visible_cells: usize = 0,
    normal_cells: usize = 0,
    complex_cells: usize = 0,
    complex_multi_codepoint_cells: usize = 0,
    complex_emoji_cells: usize = 0,
    complex_special_sprite_cells: usize = 0,
    complex_icon_cells: usize = 0,
    complex_curly_underline_cells: usize = 0,
    normal_clusters: usize = 0,
    complex_clusters: usize = 0,
    direct_normal_draws: usize = 0,
    direct_normal_raster_misses: usize = 0,
    legacy: LegacyPathReport = .{},

    pub fn init(text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, clusters: []const contract.CellCluster) LaneReport {
        var report = LaneReport{};
        for (cells) |cell| report.recordRenderableCell(cell, textForRenderableCell(text_cache, cell));
        for (clusters) |cluster| report.recordCluster(cells, cluster, textForCluster(text_cache, cluster));
        report.assertValid();
        return report;
    }

    pub fn frameFullyNormalInput(self: LaneReport) bool {
        return self.complex_cells == 0;
    }

    pub fn frameStayedOutOfLegacyPath(self: LaneReport) bool {
        return self.frameFullyNormalInput() and
            self.legacy.resolved_clusters.normal == 0 and
            self.legacy.shaped_clusters.normal == 0 and
            self.legacy.grouped_groups.normal == 0 and
            self.legacy.scene_sprite_draws.normal == 0;
    }

    pub fn recordLegacyResolvedRun(self: *LaneReport, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.resolved_clusters, text_cache, &.{}, clusters, run);
    }

    pub fn recordLegacyShapedRun(self: *LaneReport, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.shaped_clusters, text_cache, &.{}, clusters, run);
    }

    pub fn recordLegacyResolvedRunWithCells(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.resolved_clusters, text_cache, cells, clusters, run);
    }

    pub fn recordLegacyShapedRunWithCells(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
        recordLegacyRunClusters(&self.legacy.shaped_clusters, text_cache, cells, clusters, run);
    }

    pub fn recordLegacyGroup(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, group: contract.GlyphGroup) void {
        const choice = classifyRenderableCell(cellForFirstCell(cells, group.first_cell), textForFirstCell(text_cache, cells, group.first_cell));
        recordLegacyChoice(&self.legacy.grouped_groups, choice);
    }

    pub fn recordLegacySceneSpriteDraw(self: *LaneReport, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, draw: contract.TextSpriteDraw) void {
        const choice = classifyRenderableCell(cellForFirstCell(cells, draw.first_cell), textForFirstCell(text_cache, cells, draw.first_cell));
        recordLegacyChoice(&self.legacy.scene_sprite_draws, choice);
    }

    pub fn assertValid(self: LaneReport) void {
        std.debug.assert(self.visible_cells == self.normal_cells + self.complex_cells);
        std.debug.assert(self.complex_cells == self.complex_multi_codepoint_cells + self.complex_emoji_cells + self.complex_special_sprite_cells + self.complex_icon_cells + self.complex_curly_underline_cells);
        std.debug.assert(self.normal_clusters + self.complex_clusters <= self.visible_cells);
    }

    fn recordRenderableCell(self: *LaneReport, cell: contract.RenderableCell, text: contract.CellText) void {
        const choice = classifyRenderableCell(cell, text);
        self.visible_cells += 1;
        switch (choice.lane) {
            .normal => self.normal_cells += 1,
            .complex => {
                self.complex_cells += 1;
                self.recordComplexReason(choice.complex_reason.?);
            },
        }
    }

    fn recordCluster(self: *LaneReport, cells: []const contract.RenderableCell, cluster: contract.CellCluster, text: contract.CellText) void {
        const choice = classifyClusterInCells(cells, cluster, text);
        switch (choice.lane) {
            .normal => self.normal_clusters += 1,
            .complex => self.complex_clusters += 1,
        }
    }

    fn recordComplexReason(self: *LaneReport, reason: ComplexLaneReason) void {
        switch (reason) {
            .multi_codepoint => self.complex_multi_codepoint_cells += 1,
            .emoji_presentation => self.complex_emoji_cells += 1,
            .special_sprite => self.complex_special_sprite_cells += 1,
            .icon_codepoint => self.complex_icon_cells += 1,
            .curly_underline => self.complex_curly_underline_cells += 1,
        }
    }
};

pub fn normalRenderableCell(cell: contract.RenderableCell, text: contract.CellText) bool {
    assertTextInvariants(text);
    return complexRenderableCellReason(cell, text) == null;
}

pub fn complexRenderableCellReason(cell: contract.RenderableCell, text: contract.CellText) ?ComplexLaneReason {
    assertTextInvariants(text);
    return complexCellReason(cell, text);
}

pub fn classifyRenderableCell(cell: contract.RenderableCell, text: contract.CellText) LaneClass {
    const normal = normalRenderableCell(cell, text);
    const complex_reason = complexRenderableCellReason(cell, text);
    std.debug.assert(normal != (complex_reason != null));
    const choice = if (normal) LaneClass.normal() else LaneClass.complex(complex_reason.?);
    choice.assertValid();
    return choice;
}

pub fn normalCluster(cluster: contract.CellCluster, text: contract.CellText) bool {
    assertTextInvariants(text);
    return complexClusterReason(cluster, text) == null;
}

pub fn complexClusterReason(cluster: contract.CellCluster, text: contract.CellText) ?ComplexLaneReason {
    assertTextInvariants(text);
    return complexTextReason(text, cluster.presentation);
}

pub fn classifyCluster(cluster: contract.CellCluster, text: contract.CellText) LaneClass {
    const normal = normalCluster(cluster, text);
    const complex_reason = complexClusterReason(cluster, text);
    std.debug.assert(normal != (complex_reason != null));
    const choice = if (normal) LaneClass.normal() else LaneClass.complex(complex_reason.?);
    choice.assertValid();
    return choice;
}

pub fn classifyClusterInCells(cells: []const contract.RenderableCell, cluster: contract.CellCluster, text: contract.CellText) LaneClass {
    if (renderableCellForFirstCell(cells, cluster.first_cell)) |cell| {
        std.debug.assert(cell.text_id.value == cluster.text_id.value);
        const choice = classifyRenderableCell(cell, text);
        choice.assertValid();
        return choice;
    }
    return classifyCluster(cluster, text);
}

fn normalText(text: contract.CellText, presentation: contract.TextPresentation) bool {
    const route = symbol_map.builtinRoute(text.first_cp);
    return text.codepoints.len == 1 and
        presentation != .emoji and
        (route == null or route.? == .blank);
}

fn complexCellReason(cell: contract.RenderableCell, text: contract.CellText) ?ComplexLaneReason {
    if (complexTextReason(text, cell.presentation)) |reason| return reason;
    if (cell.underline and cell.underline_style == .curly) return .curly_underline;
    return null;
}

fn complexTextReason(text: contract.CellText, presentation: contract.TextPresentation) ?ComplexLaneReason {
    if (presentation == .emoji) return .emoji_presentation;
    if (symbol_map.builtinRoute(text.first_cp)) |route| {
        if (route != .blank) return .special_sprite;
    }
    if (symbol_map.isIconCodepoint(text.first_cp)) return .icon_codepoint;
    if (text.codepoints.len != 1) return .multi_codepoint;
    return null;
}

fn assertTextInvariants(text: contract.CellText) void {
    std.debug.assert(text.codepoints.len > 0);
    std.debug.assert(text.codepoints[0] == text.first_cp);
}

fn recordLegacyRunClusters(counts: *LegacyStageCounts, text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, clusters: []const contract.CellCluster, run: contract.ResolvedRun) void {
    const start = @as(usize, @intCast(run.run.cluster_start));
    const end = @min(start + @as(usize, @intCast(run.run.cluster_count)), clusters.len);
    for (clusters[start..end]) |cluster| {
        const choice = classifyClusterInCells(cells, cluster, textForCluster(text_cache, cluster));
        recordLegacyChoice(counts, choice);
    }
}

fn recordLegacyChoice(counts: *LegacyStageCounts, choice: LaneClass) void {
    switch (choice.lane) {
        .normal => counts.normal += 1,
        .complex => counts.complex += 1,
    }
}

fn textForRenderableCell(text_cache: contract.LineTextCache, cell: contract.RenderableCell) contract.CellText {
    const idx = @as(usize, @intCast(cell.text_id.value));
    std.debug.assert(idx < text_cache.texts.len);
    return text_cache.texts[idx];
}

fn textForCluster(text_cache: contract.LineTextCache, cluster: contract.CellCluster) contract.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    std.debug.assert(idx < text_cache.texts.len);
    return text_cache.texts[idx];
}

fn cellForFirstCell(cells: []const contract.RenderableCell, first_cell: u32) contract.RenderableCell {
    return renderableCellForFirstCell(cells, first_cell) orelse unreachable;
}

fn renderableCellForFirstCell(cells: []const contract.RenderableCell, first_cell: u32) ?contract.RenderableCell {
    var lo: usize = 0;
    var hi: usize = cells.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cell = cells[mid];
        if (cell.first_cell < first_cell) {
            lo = mid + 1;
            continue;
        }
        if (cell.first_cell > first_cell) {
            hi = mid;
            continue;
        }
        return cell;
    }
    return null;
}

fn textForFirstCell(text_cache: contract.LineTextCache, cells: []const contract.RenderableCell, first_cell: u32) contract.CellText {
    return textForRenderableCell(text_cache, cellForFirstCell(cells, first_cell));
}

test "lane classifies single-codepoint text as normal" {
    const text = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 'A', .codepoints = &.{'A'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .bold,
        .presentation = .text,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
    try std.testing.expectEqual(@as(?ComplexLaneReason, null), choice.complex_reason);
}

test "lane keeps wide single-codepoint text in normal lane" {
    const text = contract.CellText{ .id = .{ .value = 2 }, .first_cp = 0x4f60, .codepoints = &.{0x4f60} };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 4,
        .cell_span = 2,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
}

test "lane marks multi-codepoint text as complex" {
    const text = contract.CellText{ .id = .{ .value = 3 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.multi_codepoint, choice.complex_reason.?);
}

test "lane marks emoji presentation as complex" {
    const text = contract.CellText{ .id = .{ .value = 4 }, .first_cp = 0x1f642, .codepoints = &.{0x1f642} };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .emoji,
    };
    const choice = classifyCluster(cluster, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.emoji_presentation, choice.complex_reason.?);
}

test "lane marks generated sprite routes as complex" {
    const text = contract.CellText{ .id = .{ .value = 5 }, .first_cp = 0x2500, .codepoints = &.{0x2500} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.special_sprite, choice.complex_reason.?);
}

test "lane marks icon codepoints as complex" {
    const text = contract.CellText{ .id = .{ .value = 9 }, .first_cp = 0xf101, .codepoints = &.{0xf101} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.icon_codepoint, choice.complex_reason.?);
}

test "lane marks curly underline cells as complex" {
    const text = contract.CellText{ .id = .{ .value = 7 }, .first_cp = 'u', .codepoints = &.{'u'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .underline = true,
        .underline_style = .curly,
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.complex, choice.lane);
    try std.testing.expectEqual(ComplexLaneReason.curly_underline, choice.complex_reason.?);
}

test "lane keeps blank route in normal lane" {
    const text = contract.CellText{ .id = .{ .value = 6 }, .first_cp = 0, .codepoints = &.{0} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const choice = classifyRenderableCell(cell, text);
    try std.testing.expectEqual(TextLane.normal, choice.lane);
}

test "lane report allows visible blank cells without clusters" {
    const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 0, .codepoints = &.{0} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const report = LaneReport.init(.{ .texts = &.{text} }, &.{cell}, &.{});
    try std.testing.expectEqual(@as(usize, 1), report.visible_cells);
    try std.testing.expectEqual(@as(usize, 1), report.normal_cells);
    try std.testing.expectEqual(@as(usize, 0), report.normal_clusters);
}

test "lane report flags legacy leakage for normal runs" {
    const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} };
    const cell = contract.RenderableCell{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const cluster = contract.CellCluster{
        .text_id = text.id,
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = text.first_cp,
        .style = .regular,
        .presentation = .any,
    };
    var report = LaneReport.init(.{ .texts = &.{text} }, &.{cell}, &.{cluster});
    report.recordLegacyResolvedRun(.{ .texts = &.{text} }, &.{cluster}, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any },
    } });
    report.recordLegacyShapedRun(.{ .texts = &.{text} }, &.{cluster}, .{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any },
    } });
    report.recordLegacyGroup(.{ .texts = &.{text} }, &.{cell}, .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .normal });
    report.recordLegacySceneSpriteDraw(.{ .texts = &.{text} }, &.{cell}, .{ .sprite = .{ .slot = 0, .key = .{ .value = 1 } }, .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .color = cell.fg, .first_cell = 0, .cell_span = 1 });
    try std.testing.expect(report.frameFullyNormalInput());
    try std.testing.expectEqual(@as(usize, 1), report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 1), report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 1), report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 1), report.legacy.scene_sprite_draws.normal);
    try std.testing.expect(!report.frameStayedOutOfLegacyPath());
}
