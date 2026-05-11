//! Responsibility: run deterministic render-core text-scene measurements.
//! Ownership: render-core benchmark surface for synthetic frame workloads.
//! Reason: isolate active text analysis cost before host and backend noise.

const std = @import("std");
const render = @import("howl_render");

const OutputFormat = enum { ndjson, text };
const LaneReport = render.Core.TextLaneReport;

const WorkloadInput = union(enum) {
    cells: []render.Core.TextCellInput,
    cell_texts: []const render.Core.CellTextInput,
};

const Options = struct {
    runs: usize = 10,
    format: OutputFormat = .ndjson,
};

const RunObservation = struct {
    ns: u64,
    alloc_count: usize,
    alloc_bytes: usize,
    peak_live_bytes: usize,
};

const WorkloadResult = struct {
    name: []const u8,
    grid_cols: u16,
    grid_rows: u16,
    visible_cells: usize,
    normal_cells: usize,
    complex_cells: usize,
    complex_multi_codepoint_cells: usize,
    complex_emoji_cells: usize,
    complex_special_sprite_cells: usize,
    normal_clusters: usize,
    complex_clusters: usize,
    direct_normal_draws: usize,
    direct_normal_raster_misses: usize,
    legacy_resolved_normal_clusters: usize,
    legacy_resolved_complex_clusters: usize,
    legacy_shaped_normal_clusters: usize,
    legacy_shaped_complex_clusters: usize,
    legacy_grouped_normal_groups: usize,
    legacy_grouped_complex_groups: usize,
    legacy_scene_normal_sprite_draws: usize,
    legacy_scene_complex_sprite_draws: usize,
    frame_fully_normal_input: bool,
    frame_stayed_out_of_legacy_path: bool,
    dirty_cells_per_run: usize,
    runs: usize,
    median_ns: u64,
    p95_ns: u64,
    median_alloc_count: usize,
    median_alloc_bytes: usize,
    median_peak_live_bytes: usize,
    median_fills: usize,
    median_glyphs: usize,
    median_uploads: usize,

    fn dirtyCellsPerSecond(self: WorkloadResult) f64 {
        const median_seconds = @as(f64, @floatFromInt(self.median_ns)) / 1_000_000_000.0;
        if (median_seconds <= 0) return 0;
        return @as(f64, @floatFromInt(self.dirty_cells_per_run)) / median_seconds;
    }
};

const Workload = struct {
    name: []const u8,
    input: WorkloadInput,
    grid: render.Core.GridMetrics,
    damage: struct {
        full: bool,
        scroll_up_rows: u16 = 0,
        dirty_rows: []const bool,
        dirty_cols_start: []const u16,
        dirty_cols_end: []const u16,
    },
    cell_px: render.Core.CellSize,
    dirty_cells_per_run: usize,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    alloc_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    window_alloc_count: usize = 0,
    window_alloc_bytes: usize = 0,
    window_peak_live_bytes: usize = 0,
    window_live_baseline: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn resetWindow(self: *CountingAllocator) void {
        self.window_alloc_count = 0;
        self.window_alloc_bytes = 0;
        self.window_peak_live_bytes = 0;
        self.window_live_baseline = self.live_bytes;
    }

    fn updateWindowPeak(self: *CountingAllocator) void {
        if (self.live_bytes >= self.window_live_baseline) {
            const delta = self.live_bytes - self.window_live_baseline;
            if (delta > self.window_peak_live_bytes) self.window_peak_live_bytes = delta;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.alloc_bytes += len;
        self.live_bytes += len;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
        self.window_alloc_count += 1;
        self.window_alloc_bytes += len;
        self.updateWindowPeak();
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            self.alloc_bytes += delta;
            self.window_alloc_bytes += delta;
            self.live_bytes += delta;
        } else {
            const delta = memory.len - new_len;
            self.live_bytes -|= delta;
        }
        self.updateWindowPeak();
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            self.alloc_bytes += delta;
            self.window_alloc_bytes += delta;
            self.live_bytes += delta;
        } else {
            const delta = memory.len - new_len;
            self.live_bytes -|= delta;
        }
        self.updateWindowPeak();
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.live_bytes -|= memory.len;
        self.updateWindowPeak();
    }
};

fn lessU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn lessUsize(_: void, lhs: usize, rhs: usize) bool {
    return lhs < rhs;
}

fn medianU64(scratch: []u64) u64 {
    std.sort.heap(u64, scratch, {}, lessU64);
    return scratch[scratch.len / 2];
}

fn p95U64(scratch: []u64) u64 {
    std.sort.heap(u64, scratch, {}, lessU64);
    const n = scratch.len;
    const idx = ((95 * n) + 99) / 100 - 1;
    return scratch[@min(idx, n - 1)];
}

fn medianUsize(scratch: []usize) usize {
    std.sort.heap(usize, scratch, {}, lessUsize);
    return scratch[scratch.len / 2];
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

fn rgba(r: u8, g: u8, b: u8) render.Core.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn defaultCellMetrics(cell_px: render.Core.CellSize) render.Core.CellMetrics {
    const h = @max(cell_px.height, 1);
    return .{
        .cell_w_px = @max(cell_px.width, 1),
        .cell_h_px = h,
        .baseline_px = @intCast(@max(h - @divFloor(h, 5), 1)),
    };
}

fn initCells(allocator: std.mem.Allocator, rows: u16, cols: u16, bg: render.Core.Rgba8) ![]render.Core.TextCellInput {
    const len = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(render.Core.TextCellInput, len);
    for (cells) |*cell| {
        cell.* = .{ .codepoint = ' ', .fg = rgba(240, 240, 240), .bg = bg };
    }
    return cells;
}

fn initDirtyAll(allocator: std.mem.Allocator, rows: u16, cols: u16) !struct {
    rows: []bool,
    starts: []u16,
    ends: []u16,
} {
    const dirty_rows = try allocator.alloc(bool, rows);
    const dirty_starts = try allocator.alloc(u16, rows);
    const dirty_ends = try allocator.alloc(u16, rows);
    @memset(dirty_rows, true);
    @memset(dirty_starts, 0);
    @memset(dirty_ends, cols -| 1);
    return .{ .rows = dirty_rows, .starts = dirty_starts, .ends = dirty_ends };
}

fn initDirtySparse(allocator: std.mem.Allocator, rows: u16, active_rows: []const u16, start_col: u16, end_col: u16) !struct {
    rows: []bool,
    starts: []u16,
    ends: []u16,
} {
    const dirty_rows = try allocator.alloc(bool, rows);
    const dirty_starts = try allocator.alloc(u16, rows);
    const dirty_ends = try allocator.alloc(u16, rows);
    @memset(dirty_rows, false);
    @memset(dirty_starts, 0);
    @memset(dirty_ends, 0);
    for (active_rows) |row| {
        dirty_rows[row] = true;
        dirty_starts[row] = start_col;
        dirty_ends[row] = end_col;
    }
    return .{ .rows = dirty_rows, .starts = dirty_starts, .ends = dirty_ends };
}

fn buildAsciiFullWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 24;
    const cols: u16 = 80;
    const bg = rgba(12, 12, 18);
    const fg = rgba(235, 238, 242);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const idx = row * cols + col;
            cells[idx].codepoint = @as(u21, 'A') + @as(u21, @intCast(col % 26));
            cells[idx].fg = fg;
        }
    }
    return .{
        .name = "ascii_full",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = @as(usize, rows) * @as(usize, cols),
        .input = .{ .cells = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildSparseRowsWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 30;
    const cols: u16 = 120;
    const bg = rgba(10, 14, 20);
    const fg = rgba(220, 230, 240);
    const accent = rgba(140, 200, 255);
    const cells = try initCells(allocator, rows, cols, bg);
    const active_rows = [_]u16{ 4, 17, 18 };
    const dirty = try initDirtySparse(allocator, rows, &active_rows, 8, 87);
    for (active_rows) |row| {
        var col: u16 = 8;
        while (col <= 87) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, cols) + @as(usize, col);
            cells[idx].codepoint = if ((col - 8) % 9 == 0) 0x2500 else 'x';
            cells[idx].fg = if ((col - 8) % 16 < 8) fg else accent;
            cells[idx].bg = if (row == 17) rgba(28, 18, 36) else bg;
        }
    }
    return .{
        .name = "sparse_rows",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = active_rows.len * 80,
        .input = .{ .cells = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = false, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildMixedBoxWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 40;
    const cols: u16 = 100;
    const bg = rgba(15, 15, 15);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    const glyph_cycle = [_]u21{ 'A', 'B', 0x2500, 0x2502, 0x253C, 0x2588, 0x2592, 0x03BB };
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const idx = row * cols + col;
            cells[idx].codepoint = glyph_cycle[(row + col) % glyph_cycle.len];
            cells[idx].fg = rgba(@intCast(80 + (col % 120)), @intCast(90 + (row % 100)), @intCast(140 + ((row + col) % 100)));
            cells[idx].bg = if ((row / 4) % 2 == 0) bg else rgba(24, 24, 32);
        }
    }
    return .{
        .name = "mixed_box_full",
        .cell_px = .{ .width = 10, .height = 18 },
        .dirty_cells_per_run = @as(usize, rows) * @as(usize, cols),
        .input = .{ .cells = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildWideDirtySpansWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 36;
    const cols: u16 = 132;
    const bg = rgba(7, 10, 13);
    const fg = rgba(225, 230, 235);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty_rows_list = [_]u16{ 5, 6, 7, 8, 14, 15, 16, 22, 23, 24, 25, 31 };
    const dirty = try initDirtySparse(allocator, rows, &dirty_rows_list, 12, 119);
    for (dirty_rows_list) |row| {
        var col: u16 = 12;
        while (col <= 119) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, cols) + @as(usize, col);
            cells[idx].codepoint = if (col % 17 == 0) 0x251C else if (col % 7 == 0) 0x2580 else 'm';
            cells[idx].fg = fg;
            cells[idx].bg = if ((col / 8) % 2 == 0) rgba(18, 24, 30) else rgba(32, 18, 18);
        }
    }
    return .{
        .name = "wide_dirty_spans",
        .cell_px = .{ .width = 9, .height = 17 },
        .dirty_cells_per_run = dirty_rows_list.len * 108,
        .input = .{ .cells = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = false, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildComplexTextWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 12;
    const cols: u16 = 32;
    const bg = rgba(14, 12, 18);
    const fg = rgba(232, 236, 242);
    const combining = &[_]u32{ 'i', 0x0332 };
    const emoji = &[_]u32{0x1f642};
    const cells = try allocator.alloc(render.Core.CellTextInput, @as(usize, rows) * @as(usize, cols));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const cp = if (idx % 2 == 0) combining else emoji;
        cell.* = .{
            .codepoints = cp,
            .fg = fg,
            .bg = bg,
            .presentation = if (idx % 2 == 0) .any else .emoji,
        };
    }
    return .{
        .name = "complex_text_full",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = cells.len,
        .input = .{ .cell_texts = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildCellTextAsciiFullWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 24;
    const cols: u16 = 80;
    const bg = rgba(12, 12, 18);
    const fg = rgba(235, 238, 242);
    const ascii = [_]u32{'a'};
    const cells = try allocator.alloc(render.Core.CellTextInput, @as(usize, rows) * @as(usize, cols));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells) |*cell| {
        cell.* = .{
            .codepoints = &ascii,
            .fg = fg,
            .bg = bg,
        };
    }
    return .{
        .name = "cell_text_ascii_full",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = cells.len,
        .input = .{ .cell_texts = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildCellTextMixedWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 16;
    const cols: u16 = 48;
    const bg = rgba(16, 14, 22);
    const fg = rgba(232, 236, 242);
    const accent = rgba(166, 212, 255);
    const ascii = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const cells = try allocator.alloc(render.Core.CellTextInput, @as(usize, rows) * @as(usize, cols));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const even = idx % 2 == 0;
        cell.* = .{
            .codepoints = if (even) &ascii else &combining,
            .fg = if (even) fg else accent,
            .bg = bg,
            .presentation = .any,
        };
    }
    return .{
        .name = "cell_text_mixed",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = cells.len,
        .input = .{ .cell_texts = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn runWorkload(io: std.Io, allocator: std.mem.Allocator, workload: Workload, runs: usize) !WorkloadResult {
    const observations = try allocator.alloc(RunObservation, runs);
    defer allocator.free(observations);
    const fill_values = try allocator.alloc(usize, runs);
    defer allocator.free(fill_values);
    const glyph_values = try allocator.alloc(usize, runs);
    defer allocator.free(glyph_values);
    const upload_values = try allocator.alloc(usize, runs);
    defer allocator.free(upload_values);

    const cell_metrics = defaultCellMetrics(workload.cell_px);
    const session = render.Core.TextFontSession{
        .primary_face = .{ .value = 1 },
        .metrics = cell_metrics,
    };
    const analysis_options = render.Core.TextEngineAnalysisOptions{
        .scene = .{
            .damage = .{
                .full = workload.damage.full,
                .scroll_up_rows = workload.damage.scroll_up_rows,
                .dirty_rows = workload.damage.dirty_rows,
                .dirty_cols_start = workload.damage.dirty_cols_start,
                .dirty_cols_end = workload.damage.dirty_cols_end,
            },
        },
    };
    var lane_report: ?LaneReport = null;
    var counting = CountingAllocator.init(allocator);
    var engine = render.Core.TextEngine.init(counting.allocator());
    defer engine.deinit();

    {
        var warm = switch (workload.input) {
            .cells => |cells| try engine.analyzeCellsWithSessionOptions(
                cells,
                workload.grid,
                session,
                analysis_options,
            ),
            .cell_texts => |cells| try engine.analyzeCellTextInputsOptions(
                cells,
                workload.grid,
                session,
                analysis_options,
            ),
        };
        for (warm.raster_plan.outputs) |output| _ = engine.atlas.markRendered(output.key);
        warm.deinit();
    }

    var i: usize = 0;
    while (i < runs) : (i += 1) {
        counting.resetWindow();
        const start = nowNs(io);
        var analysis = switch (workload.input) {
            .cells => |cells| try engine.analyzeCellsWithSessionOptions(
                cells,
                workload.grid,
                session,
                analysis_options,
            ),
            .cell_texts => |cells| try engine.analyzeCellTextInputsOptions(
                cells,
                workload.grid,
                session,
                analysis_options,
            ),
        };
        const end = nowNs(io);
        defer analysis.deinit();
        const run_lane_report = analysis.lane_report;
        if (lane_report) |existing| {
            std.debug.assert(std.meta.eql(existing, run_lane_report));
        } else {
            lane_report = run_lane_report;
        }
        observations[i] = .{
            .ns = end - start,
            .alloc_count = counting.window_alloc_count,
            .alloc_bytes = counting.window_alloc_bytes,
            .peak_live_bytes = counting.window_peak_live_bytes,
        };
        for (analysis.raster_plan.outputs) |output| _ = engine.atlas.markRendered(output.key);
        fill_values[i] = analysis.scene.scene.background_draws.len + analysis.scene.scene.decoration_draws.len + analysis.scene.scene.cursor_draws.len;
        glyph_values[i] = analysis.scene.scene.sprite_draws.len;
        upload_values[i] = analysis.raster_plan.outputs.len;
    }

    const ns_values = try allocator.alloc(u64, runs);
    defer allocator.free(ns_values);
    const alloc_count_values = try allocator.alloc(usize, runs);
    defer allocator.free(alloc_count_values);
    const alloc_bytes_values = try allocator.alloc(usize, runs);
    defer allocator.free(alloc_bytes_values);
    const peak_live_values = try allocator.alloc(usize, runs);
    defer allocator.free(peak_live_values);

    for (observations, 0..) |obs, idx| {
        ns_values[idx] = obs.ns;
        alloc_count_values[idx] = obs.alloc_count;
        alloc_bytes_values[idx] = obs.alloc_bytes;
        peak_live_values[idx] = obs.peak_live_bytes;
    }

    const final_lane_report = lane_report orelse LaneReport{};

    return .{
        .name = workload.name,
        .grid_cols = workload.grid.cols,
        .grid_rows = workload.grid.rows,
        .visible_cells = final_lane_report.visible_cells,
        .normal_cells = final_lane_report.normal_cells,
        .complex_cells = final_lane_report.complex_cells,
        .complex_multi_codepoint_cells = final_lane_report.complex_multi_codepoint_cells,
        .complex_emoji_cells = final_lane_report.complex_emoji_cells,
        .complex_special_sprite_cells = final_lane_report.complex_special_sprite_cells,
        .normal_clusters = final_lane_report.normal_clusters,
        .complex_clusters = final_lane_report.complex_clusters,
        .direct_normal_draws = final_lane_report.direct_normal_draws,
        .direct_normal_raster_misses = final_lane_report.direct_normal_raster_misses,
        .legacy_resolved_normal_clusters = final_lane_report.legacy.resolved_clusters.normal,
        .legacy_resolved_complex_clusters = final_lane_report.legacy.resolved_clusters.complex,
        .legacy_shaped_normal_clusters = final_lane_report.legacy.shaped_clusters.normal,
        .legacy_shaped_complex_clusters = final_lane_report.legacy.shaped_clusters.complex,
        .legacy_grouped_normal_groups = final_lane_report.legacy.grouped_groups.normal,
        .legacy_grouped_complex_groups = final_lane_report.legacy.grouped_groups.complex,
        .legacy_scene_normal_sprite_draws = final_lane_report.legacy.scene_sprite_draws.normal,
        .legacy_scene_complex_sprite_draws = final_lane_report.legacy.scene_sprite_draws.complex,
        .frame_fully_normal_input = final_lane_report.frameFullyNormalInput(),
        .frame_stayed_out_of_legacy_path = final_lane_report.frameStayedOutOfLegacyPath(),
        .dirty_cells_per_run = workload.dirty_cells_per_run,
        .runs = runs,
        .median_ns = medianU64(ns_values),
        .p95_ns = p95U64(ns_values),
        .median_alloc_count = medianUsize(alloc_count_values),
        .median_alloc_bytes = medianUsize(alloc_bytes_values),
        .median_peak_live_bytes = medianUsize(peak_live_values),
        .median_fills = medianUsize(fill_values),
        .median_glyphs = medianUsize(glyph_values),
        .median_uploads = medianUsize(upload_values),
    };
}

fn parseArgs(argv: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--text")) {
            opts.format = .text;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--runs=")) {
            opts.runs = std.fmt.parseUnsigned(usize, arg["--runs=".len..], 10) catch return error.InvalidRuns;
            continue;
        }
        if (std.mem.eql(u8, arg, "--runs")) {
            i += 1;
            if (i >= argv.len) return error.MissingRuns;
            opts.runs = std.fmt.parseUnsigned(usize, argv[i], 10) catch return error.InvalidRuns;
            continue;
        }
        return error.UnknownArgument;
    }
    return opts;
}

fn printTextResult(result: WorkloadResult) void {
    const median_ms = @as(f64, @floatFromInt(result.median_ns)) / 1_000_000.0;
    const p95_ms = @as(f64, @floatFromInt(result.p95_ns)) / 1_000_000.0;
    std.debug.print("workload={s}\n", .{result.name});
    std.debug.print("grid_cols={d}\n", .{result.grid_cols});
    std.debug.print("grid_rows={d}\n", .{result.grid_rows});
    std.debug.print("visible_cells={d}\n", .{result.visible_cells});
    std.debug.print("normal_cells={d}\n", .{result.normal_cells});
    std.debug.print("complex_cells={d}\n", .{result.complex_cells});
    std.debug.print("complex_multi_codepoint_cells={d}\n", .{result.complex_multi_codepoint_cells});
    std.debug.print("complex_emoji_cells={d}\n", .{result.complex_emoji_cells});
    std.debug.print("complex_special_sprite_cells={d}\n", .{result.complex_special_sprite_cells});
    std.debug.print("normal_clusters={d}\n", .{result.normal_clusters});
    std.debug.print("complex_clusters={d}\n", .{result.complex_clusters});
    std.debug.print("direct_normal_draws={d}\n", .{result.direct_normal_draws});
    std.debug.print("direct_normal_raster_misses={d}\n", .{result.direct_normal_raster_misses});
    std.debug.print("legacy_resolved_normal_clusters={d}\n", .{result.legacy_resolved_normal_clusters});
    std.debug.print("legacy_resolved_complex_clusters={d}\n", .{result.legacy_resolved_complex_clusters});
    std.debug.print("legacy_shaped_normal_clusters={d}\n", .{result.legacy_shaped_normal_clusters});
    std.debug.print("legacy_shaped_complex_clusters={d}\n", .{result.legacy_shaped_complex_clusters});
    std.debug.print("legacy_grouped_normal_groups={d}\n", .{result.legacy_grouped_normal_groups});
    std.debug.print("legacy_grouped_complex_groups={d}\n", .{result.legacy_grouped_complex_groups});
    std.debug.print("legacy_scene_normal_sprite_draws={d}\n", .{result.legacy_scene_normal_sprite_draws});
    std.debug.print("legacy_scene_complex_sprite_draws={d}\n", .{result.legacy_scene_complex_sprite_draws});
    std.debug.print("frame_fully_normal_input={}\n", .{result.frame_fully_normal_input});
    std.debug.print("frame_stayed_out_of_legacy_path={}\n", .{result.frame_stayed_out_of_legacy_path});
    std.debug.print("runs={d}\n", .{result.runs});
    std.debug.print("dirty_cells_per_run={d}\n", .{result.dirty_cells_per_run});
    std.debug.print("median_ms={d:.3}\n", .{median_ms});
    std.debug.print("p95_ms={d:.3}\n", .{p95_ms});
    std.debug.print("dirty_cells_per_second={d:.0}\n", .{result.dirtyCellsPerSecond()});
    std.debug.print("median_alloc_count={d}\n", .{result.median_alloc_count});
    std.debug.print("median_alloc_bytes={d}\n", .{result.median_alloc_bytes});
    std.debug.print("median_peak_live_bytes={d}\n", .{result.median_peak_live_bytes});
    std.debug.print("median_fills={d}\n", .{result.median_fills});
    std.debug.print("median_glyphs={d}\n", .{result.median_glyphs});
    std.debug.print("median_uploads={d}\n", .{result.median_uploads});
    std.debug.print("---\n", .{});
}

fn printNdjsonResult(result: WorkloadResult) void {
    std.debug.print(
        "{{\"workload\":\"{s}\",\"grid_cols\":{d},\"grid_rows\":{d},\"visible_cells\":{d},\"normal_cells\":{d},\"complex_cells\":{d},\"complex_multi_codepoint_cells\":{d},\"complex_emoji_cells\":{d},\"complex_special_sprite_cells\":{d},\"normal_clusters\":{d},\"complex_clusters\":{d},\"direct_normal_draws\":{d},\"direct_normal_raster_misses\":{d},\"legacy_resolved_normal_clusters\":{d},\"legacy_resolved_complex_clusters\":{d},\"legacy_shaped_normal_clusters\":{d},\"legacy_shaped_complex_clusters\":{d},\"legacy_grouped_normal_groups\":{d},\"legacy_grouped_complex_groups\":{d},",
        .{
            result.name,
            result.grid_cols,
            result.grid_rows,
            result.visible_cells,
            result.normal_cells,
            result.complex_cells,
            result.complex_multi_codepoint_cells,
            result.complex_emoji_cells,
            result.complex_special_sprite_cells,
            result.normal_clusters,
            result.complex_clusters,
            result.direct_normal_draws,
            result.direct_normal_raster_misses,
            result.legacy_resolved_normal_clusters,
            result.legacy_resolved_complex_clusters,
            result.legacy_shaped_normal_clusters,
            result.legacy_shaped_complex_clusters,
            result.legacy_grouped_normal_groups,
            result.legacy_grouped_complex_groups,
        },
    );
    std.debug.print(
        "\"legacy_scene_normal_sprite_draws\":{d},\"legacy_scene_complex_sprite_draws\":{d},\"frame_fully_normal_input\":{},\"frame_stayed_out_of_legacy_path\":{},\"runs\":{d},\"dirty_cells_per_run\":{d},\"median_ns\":{d},\"p95_ns\":{d},\"dirty_cells_per_second\":{d:.0},\"median_alloc_count\":{d},\"median_alloc_bytes\":{d},\"median_peak_live_bytes\":{d},\"median_fills\":{d},\"median_glyphs\":{d},\"median_uploads\":{d}}}\n",
        .{
            result.legacy_scene_normal_sprite_draws,
            result.legacy_scene_complex_sprite_draws,
            result.frame_fully_normal_input,
            result.frame_stayed_out_of_legacy_path,
            result.runs,
            result.dirty_cells_per_run,
            result.median_ns,
            result.p95_ns,
            result.dirtyCellsPerSecond(),
            result.median_alloc_count,
            result.median_alloc_bytes,
            result.median_peak_live_bytes,
            result.median_fills,
            result.median_glyphs,
            result.median_uploads,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const opts = try parseArgs(argv);
    const io = init.io;

    const workloads = [_]Workload{
        try buildAsciiFullWorkload(arena),
        try buildCellTextAsciiFullWorkload(arena),
        try buildSparseRowsWorkload(arena),
        try buildMixedBoxWorkload(arena),
        try buildWideDirtySpansWorkload(arena),
        try buildCellTextMixedWorkload(arena),
        try buildComplexTextWorkload(arena),
    };

    for (workloads) |workload| {
        const result = try runWorkload(io, arena, workload, opts.runs);
        switch (opts.format) {
            .ndjson => printNdjsonResult(result),
            .text => printTextResult(result),
        }
    }
}
