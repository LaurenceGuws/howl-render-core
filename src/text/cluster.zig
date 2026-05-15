
const std = @import("std");
const contract = @import("contract.zig");
const scene = @import("scene.zig");
const lane = @import("lane.zig");

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
    owned: bool = true,

    pub fn view(self: OwnedLineTextCache) contract.LineTextCache {
        return .{ .texts = self.texts };
    }

    pub fn deinit(self: *OwnedLineTextCache) void {
        if (self.owned) {
            self.allocator.free(self.texts);
            self.allocator.free(self.codepoints);
        }
        self.* = undefined;
    }
};

pub const OwnedRenderableCells = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    owned: bool = true,

    pub fn deinit(self: *OwnedRenderableCells) void {
        if (self.owned) self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedClusters = struct {
    allocator: std.mem.Allocator,
    clusters: []contract.CellCluster,
    owned: bool = true,

    pub fn deinit(self: *OwnedClusters) void {
        if (self.owned) self.allocator.free(self.clusters);
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

pub const ComplexSelection = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    clusters: []contract.CellCluster,

    pub fn deinit(self: *ComplexSelection) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.clusters);
        self.* = undefined;
    }
};

pub const SparseCells = struct {
    text_cache: OwnedLineTextCache,
    renderable: OwnedRenderableCells,

    pub fn deinit(self: *SparseCells) void {
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

const ClusterExtractionAssembly = struct {
    allocator: std.mem.Allocator,
    clusters: std.ArrayList(contract.CellCluster) = .empty,

    fn deinit(self: *ClusterExtractionAssembly) void {
        self.clusters.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *ClusterExtractionAssembly, cluster_value: contract.CellCluster) !void {
        try self.clusters.append(self.allocator, cluster_value);
    }

    fn toOwnedClusters(self: *ClusterExtractionAssembly) !OwnedClusters {
        return .{ .allocator = self.allocator, .clusters = try self.clusters.toOwnedSlice(self.allocator) };
    }
};

const InputLineTextCacheAssembly = struct {
    allocator: std.mem.Allocator,
    texts: []contract.CellText,
    codepoints: []u32,
    text_count: u32 = 0,
    codepoint_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, input_count: u32, total_codepoints: u32) !InputLineTextCacheAssembly {
        const texts = try allocator.alloc(contract.CellText, @intCast(input_count));
        errdefer allocator.free(texts);
        const codepoints = try allocator.alloc(u32, @intCast(total_codepoints));
        errdefer allocator.free(codepoints);
        return .{
            .allocator = allocator,
            .texts = texts,
            .codepoints = codepoints,
        };
    }

    fn deinit(self: *InputLineTextCacheAssembly) void {
        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.* = undefined;
    }

    fn knownTexts(self: InputLineTextCacheAssembly) []const contract.CellText {
        return self.texts[0..@intCast(self.text_count)];
    }

    fn appendText(self: *InputLineTextCacheAssembly, cps: []const u32) void {
        const cp_start: u32 = self.codepoint_count;
        const cp_len: u32 = @intCast(cps.len);
        @memcpy(self.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)], cps);
        self.texts[@intCast(self.text_count)] = .{
            .id = .{ .value = self.text_count },
            .first_cp = cps[0],
            .codepoints = self.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)],
        };
        self.text_count += 1;
        self.codepoint_count += cp_len;
    }

    fn toOwnedLineTextCache(self: *InputLineTextCacheAssembly) !OwnedLineTextCache {
        const final_texts = try self.allocator.realloc(self.texts, @intCast(self.text_count));
        self.texts = &.{};
        const final_codepoints = self.codepoints;
        self.codepoints = &.{};

        return .{ .allocator = self.allocator, .texts = final_texts, .codepoints = final_codepoints };
    }
};

const InputRenderableAssembly = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    cell_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, input_count: u32) !InputRenderableAssembly {
        return .{ .allocator = allocator, .cells = try allocator.alloc(contract.RenderableCell, @intCast(input_count)) };
    }

    fn deinit(self: *InputRenderableAssembly) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn append(self: *InputRenderableAssembly, cell: contract.RenderableCell) void {
        self.cells[@intCast(self.cell_count)] = cell;
        self.cell_count += 1;
    }

    fn toOwnedRenderableCells(self: *InputRenderableAssembly) OwnedRenderableCells {
        std.debug.assert(self.cell_count == self.cells.len);
        return .{ .allocator = self.allocator, .cells = self.cells };
    }
};

const CellLineTextCacheAssembly = struct {
    allocator: std.mem.Allocator,
    texts: []contract.CellText,
    codepoints: []u32,
    count: u32 = 0,

    fn init(allocator: std.mem.Allocator, cell_count: u32) !CellLineTextCacheAssembly {
        const texts = try allocator.alloc(contract.CellText, @intCast(cell_count));
        errdefer allocator.free(texts);
        const codepoints = try allocator.alloc(u32, @intCast(cell_count));
        errdefer allocator.free(codepoints);
        return .{ .allocator = allocator, .texts = texts, .codepoints = codepoints };
    }

    fn deinit(self: *CellLineTextCacheAssembly) void {
        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.* = undefined;
    }

    fn appendCell(self: *CellLineTextCacheAssembly, cell: contract.CellInput) void {
        const idx = self.count;
        self.codepoints[@intCast(idx)] = cell.codepoint;
        self.texts[@intCast(idx)] = .{
            .id = .{ .value = idx },
            .first_cp = cell.codepoint,
            .codepoints = self.codepoints[@intCast(idx)..@intCast(idx + 1)],
        };
        self.count += 1;
    }

    fn toOwnedLineTextCache(self: *CellLineTextCacheAssembly) OwnedLineTextCache {
        std.debug.assert(self.count == self.texts.len);
        std.debug.assert(self.count == self.codepoints.len);
        const texts = self.texts;
        const codepoints = self.codepoints;
        self.texts = &.{};
        self.codepoints = &.{};
        return .{ .allocator = self.allocator, .texts = texts, .codepoints = codepoints };
    }
};

const RunAssembly = struct {
    allocator: std.mem.Allocator,
    runs: std.ArrayList(contract.ResolvedRun) = .empty,

    fn deinit(self: *RunAssembly) void {
        self.runs.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *RunAssembly, run: contract.ResolvedRun) !void {
        try self.runs.append(self.allocator, run);
    }

    fn toOwnedRuns(self: *RunAssembly) !OwnedRuns {
        return .{ .allocator = self.allocator, .runs = try self.runs.toOwnedSlice(self.allocator) };
    }
};

const ComplexSelectionAssembly = struct {
    allocator: std.mem.Allocator,
    cells: std.ArrayList(contract.RenderableCell) = .empty,
    clusters: std.ArrayList(contract.CellCluster) = .empty,

    fn deinit(self: *ComplexSelectionAssembly) void {
        self.cells.deinit(self.allocator);
        self.clusters.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendCell(self: *ComplexSelectionAssembly, cell: contract.RenderableCell) !void {
        try self.cells.append(self.allocator, cell);
    }

    fn appendCluster(self: *ComplexSelectionAssembly, cluster_value: contract.CellCluster) !void {
        try self.clusters.append(self.allocator, cluster_value);
    }

    fn toOwnedSelection(self: *ComplexSelectionAssembly) !ComplexSelection {
        return .{
            .allocator = self.allocator,
            .cells = try self.cells.toOwnedSlice(self.allocator),
            .clusters = try self.clusters.toOwnedSlice(self.allocator),
        };
    }
};

const SparseCellAssembly = struct {
    allocator: std.mem.Allocator,
    renderable: []contract.RenderableCell,
    texts: []contract.CellText,
    codepoints: []u32,
    unique_count: u32 = 0,
    renderable_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, cell_count: usize) !SparseCellAssembly {
        const renderable = try allocator.alloc(contract.RenderableCell, cell_count);
        errdefer allocator.free(renderable);
        const texts = try allocator.alloc(contract.CellText, cell_count);
        errdefer allocator.free(texts);
        const codepoints = try allocator.alloc(u32, cell_count);
        errdefer allocator.free(codepoints);
        return .{
            .allocator = allocator,
            .renderable = renderable,
            .texts = texts,
            .codepoints = codepoints,
        };
    }

    fn deinit(self: *SparseCellAssembly) void {
        self.allocator.free(self.renderable);
        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.* = undefined;
    }

    fn appendUniqueText(self: *SparseCellAssembly, text_id: u32, cp: u32) void {
        writeSingleCodepointText(self.texts, self.codepoints, @intCast(self.unique_count), text_id, cp);
        self.unique_count += 1;
    }

    fn appendRenderable(self: *SparseCellAssembly, cell: contract.RenderableCell) void {
        self.renderable[@intCast(self.renderable_count)] = cell;
        self.renderable_count += 1;
    }

    fn toSparseCells(self: *SparseCellAssembly) !SparseCells {
        const final_renderable = try self.allocator.realloc(self.renderable, @intCast(self.renderable_count));
        self.renderable = &.{};
        errdefer self.allocator.free(final_renderable);

        const final_codepoints = try self.allocator.alloc(u32, @intCast(self.unique_count));
        errdefer self.allocator.free(final_codepoints);
        @memcpy(final_codepoints, self.codepoints[0..@intCast(self.unique_count)]);

        const final_texts = try self.allocator.alloc(contract.CellText, @intCast(self.unique_count));
        errdefer self.allocator.free(final_texts);
        for (0..@as(u32, self.unique_count)) |idx| {
            writeSingleCodepointText(final_texts, final_codepoints, idx, @intCast(idx), final_codepoints[idx]);
        }

        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.texts = &.{};
        self.codepoints = &.{};

        return .{
            .text_cache = .{ .allocator = self.allocator, .texts = final_texts, .codepoints = final_codepoints },
            .renderable = .{ .allocator = self.allocator, .cells = final_renderable },
        };
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

pub fn buildLineTextCacheFromCells(allocator: std.mem.Allocator, cells: []const contract.CellInput) !OwnedLineTextCache {
    var assembly = try CellLineTextCacheAssembly.init(allocator, @intCast(cells.len));
    errdefer assembly.deinit();

    for (cells) |cell| assembly.appendCell(cell);

    return assembly.toOwnedLineTextCache();
}

pub fn buildSparseCellsWithDamage(
    allocator: std.mem.Allocator,
    cells: []const contract.CellInput,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !SparseCells {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    var assembly = try SparseCellAssembly.init(allocator, cells.len);
    errdefer assembly.deinit();

    var unique_codepoints = std.AutoHashMap(u32, u32).init(allocator);
    defer unique_codepoints.deinit();

    var cell_idx: usize = 0;
    while (cell_idx < cells.len) {
        if (damage_filter.cleanRowSkip(cell_idx, cells.len)) |next_idx| {
            cell_idx = next_idx;
            continue;
        }
        const idx = cell_idx;
        cell_idx += 1;
        const cell = cells[idx];
        if (cell.continuation) continue;
        if (cell.empty) continue;
        const first_cell: u32 = @intCast(idx);
        const span = inferredCellSpan(cells, idx);
        if (!damage_filter.includeSpan(first_cell, span)) continue;
        const entry = try unique_codepoints.getOrPut(cell.codepoint);
        const text_id: u32 = if (entry.found_existing)
            entry.value_ptr.*
        else blk: {
            const next_id: u32 = @intCast(assembly.unique_count);
            entry.value_ptr.* = next_id;
            assembly.appendUniqueText(next_id, cell.codepoint);
            break :blk next_id;
        };
        assembly.appendRenderable(renderableFromCellInput(.{ .value = text_id }, first_cell, span, cell, false));
    }

    return assembly.toSparseCells();
}

pub fn buildLineTextCacheFromInputs(allocator: std.mem.Allocator, inputs: []const CellTextInput) !OwnedLineTextCache {
    var total_codepoints: u32 = 0;
    for (inputs) |input| total_codepoints += @intCast(@max(input.codepoints.len, 1));

    var assembly = try InputLineTextCacheAssembly.init(allocator, @intCast(inputs.len), total_codepoints);
    errdefer assembly.deinit();

    for (inputs) |input| {
        const cps = normalizedCodepoints(input.codepoints);
        if (findText(assembly.knownTexts(), cps) != null) continue;
        assembly.appendText(cps);
    }

    return assembly.toOwnedLineTextCache();
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
    cells: []const contract.CellInput,
    cache: contract.LineTextCache,
) !OwnedRenderableCells {
    var assembly = try InputRenderableAssembly.init(allocator, @intCast(cells.len));
    errdefer assembly.deinit();

    for (cells, 0..) |cell, idx| {
        const text = cache.texts[idx];
        assembly.append(renderableFromCellInput(text.id, @intCast(idx), inferredCellSpan(cells, idx), cell, cell.continuation));
    }

    return assembly.toOwnedRenderableCells();
}

pub fn buildRenderableCellsFromInputs(
    allocator: std.mem.Allocator,
    inputs: []const CellTextInput,
    cache: contract.LineTextCache,
) !OwnedRenderableCells {
    var assembly = try InputRenderableAssembly.init(allocator, @intCast(inputs.len));
    errdefer assembly.deinit();

    for (inputs, 0..) |input, idx| {
        const cps = normalizedCodepoints(input.codepoints);
        const text_id = findText(cache.texts, cps) orelse 0;
        assembly.append(renderableFromInput(.{ .value = @intCast(text_id) }, @intCast(idx), @max(@max(input.cell_span, 1), inferredInputCellSpan(inputs, idx)), detectPresentation(cps, input.presentation), input));
    }

    return assembly.toOwnedRenderableCells();
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
    damage: scene.DamageInput,
) !OwnedClusters {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    var extraction = ClusterExtractionAssembly{ .allocator = allocator };
    errdefer extraction.deinit();
    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        if (!damage_filter.includeSpan(cell.first_cell, cell.cell_span)) continue;
        const text = textForCell(cell, cache);
        if (isBlankText(text)) continue;
        try extraction.append(renderableCluster(cell, text, inferredRenderableCellSpan(cells, idx)));
    }

    return extraction.toOwnedClusters();
}

pub fn selectComplexWithDamage(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !ComplexSelection {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    var selection = ComplexSelectionAssembly{ .allocator = allocator };
    errdefer selection.deinit();
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!damage_filter.includeSpan(cell.first_cell, cell.cell_span)) continue;
        if (!classifyComplexCell(cell, cache)) continue;
        try selection.appendCell(cell);
    }

    for (clusters) |cluster_value| {
        if (!classifyComplexCluster(cells, cluster_value, cache)) continue;
        try selection.appendCluster(cluster_value);
    }

    return selection.toOwnedSelection();
}

fn textForCell(cell: contract.RenderableCell, cache: contract.LineTextCache) contract.CellText {
    const text_idx = @as(usize, @intCast(cell.text_id.value));
    if (text_idx < cache.texts.len) return cache.texts[text_idx];
    return .{ .id = cell.text_id, .first_cp = 0, .codepoints = &.{} };
}

fn textForCluster(cluster: contract.CellCluster, cache: contract.LineTextCache) contract.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < cache.texts.len) return cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn isBlankText(text: contract.CellText) bool {
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    for (cps) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

const DamageFilter = struct {
    cols: u32,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    valid: bool,

    fn init(damage: scene.DamageInput, grid_metrics: contract.GridMetrics) DamageFilter {
        const row_count = @as(usize, grid_metrics.rows);
        const valid = !damage.full and
            damage.dirty_rows.len == row_count and
            damage.dirty_cols_start.len == row_count and
            damage.dirty_cols_end.len == row_count;
        return .{
            .cols = @max(@as(u32, grid_metrics.cols), 1),
            .dirty_rows = damage.dirty_rows,
            .dirty_cols_start = damage.dirty_cols_start,
            .dirty_cols_end = damage.dirty_cols_end,
            .valid = valid,
        };
    }

    fn cleanRowSkip(self: DamageFilter, idx: usize, cells_len: usize) ?usize {
        if (!self.valid) return null;
        const row = idx / self.cols;
        if (row >= self.dirty_rows.len) return cells_len;
        if (self.dirty_rows[row]) return null;
        return @min((row + 1) * self.cols, cells_len);
    }

    fn includeSpan(self: DamageFilter, first_cell: u32, cell_span: u8) bool {
        if (!self.valid) return true;
        const row = @as(usize, @intCast(first_cell / self.cols));
        if (row >= self.dirty_rows.len or !self.dirty_rows[row]) return false;
        const start_col = @as(u16, @intCast(first_cell % self.cols));
        const end_col = start_col +| (@max(cell_span, 1) - 1);
        return !(end_col < self.dirty_cols_start[row] or start_col > self.dirty_cols_end[row]);
    }
};

fn writeSingleCodepointText(texts: []contract.CellText, codepoints: []u32, idx: usize, text_id: u32, cp: u32) void {
    codepoints[idx] = cp;
    texts[idx] = .{
        .id = .{ .value = text_id },
        .first_cp = cp,
        .codepoints = codepoints[idx .. idx + 1],
    };
}

fn renderableFromCellInput(text_id: contract.CellTextId, first_cell: u32, cell_span: u8, cell: contract.CellInput, continuation: bool) contract.RenderableCell {
    return .{
        .text_id = text_id,
        .first_cell = first_cell,
        .cell_span = cell_span,
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
        .continuation = continuation,
    };
}

fn renderableFromInput(text_id: contract.CellTextId, first_cell: u32, cell_span: u8, presentation: contract.TextPresentation, input: CellTextInput) contract.RenderableCell {
    return .{
        .text_id = text_id,
        .first_cell = first_cell,
        .cell_span = cell_span,
        .style = input.style,
        .presentation = presentation,
        .fg = input.fg,
        .bg = input.bg,
        .underline_color = input.underline_color,
        .underline_style = input.underline_style,
        .underline = input.underline,
        .strikethrough = input.strikethrough,
        .continuation = input.continuation,
    };
}

fn renderableCluster(cell: contract.RenderableCell, text: contract.CellText, cell_span: u8) contract.CellCluster {
    return .{
        .text_id = cell.text_id,
        .first_cell = cell.first_cell,
        .cell_span = @max(cell.cell_span, cell_span),
        .first_cp = text.first_cp,
        .style = cell.style,
        .presentation = cell.presentation,
    };
}

fn classifyComplexCell(cell: contract.RenderableCell, cache: contract.LineTextCache) bool {
    return lane.classifyRenderableCell(cell, textForCell(cell, cache)).lane == .complex;
}

fn classifyComplexCluster(cells: []const contract.RenderableCell, cluster_value: contract.CellCluster, cache: contract.LineTextCache) bool {
    return lane.classifyClusterInCells(cells, cluster_value, textForCluster(cluster_value, cache)).lane == .complex;
}

fn inferredCellSpan(cells: []const contract.CellInput, idx: usize) u8 {
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

    var assembly = RunAssembly{ .allocator = allocator };
    errdefer assembly.deinit();

    var prev = clusters[0];
    var start: u32 = 0;
    prev = clusters[0];
    for (clusters[1..], 1..) |cluster, idx| {
        if (cluster.style != prev.style or cluster.presentation != prev.presentation) {
            try assembly.append(resolvedRun(start, @intCast(idx - start), face_id, prev.style, prev.presentation));
            start = @intCast(idx);
        }
        prev = cluster;
    }
    try assembly.append(resolvedRun(start, @intCast(clusters.len - start), face_id, prev.style, prev.presentation));

    return assembly.toOwnedRuns();
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black, .continuation = true },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = ' ', .fg = white, .bg = black },
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(usize, 1), clusters.clusters.len);
    try std.testing.expectEqual(@as(u32, 'A'), clusters.clusters[0].first_cp);
    try std.testing.expectEqual(@as(u32, 1), clusters.clusters[0].first_cell);
}

test "continuation cells expand base cell spans" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'x', .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
        .{ .codepoint = 'D', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 0, 0 };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ true, false };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 1, 0 };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 2, .rows = 2 }, .{
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Y', .fg = white, .bg = black },
    };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 3, .rows = 1 }, .{ .full = true });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(usize, 2), sparse.text_cache.texts.len);
    try std.testing.expectEqual(sparse.renderable.cells[0].text_id.value, sparse.renderable.cells[1].text_id.value);
    try std.testing.expect(sparse.renderable.cells[2].text_id.value != sparse.renderable.cells[0].text_id.value);
}

test "sparse cells skip Alacritty-empty cells" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = ' ', .fg = white, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .empty = true },
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = '\t', .fg = white, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .empty = true },
    };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 3, .rows = 1 }, .{ .full = true });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(usize, 1), sparse.renderable.cells.len);
    try std.testing.expectEqual(@as(u32, 1), sparse.renderable.cells[0].first_cell);
    try std.testing.expectEqual(@as(u32, 'A'), sparse.text_cache.texts[0].first_cp);
}

test "rich cell text interning deduplicates codepoint sequences" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
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
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
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
