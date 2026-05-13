//! Responsibility: run deterministic render text-scene measurements.
//! Ownership: render benchmark surface for synthetic frame workloads.
//! Reason: isolate active text analysis cost before host and backend noise.

const std = @import("std");
const render = @import("howl_render");

const OutputFormat = enum { ndjson, text };
const LaneReport = render.Render.Text.Lane.LaneReport;

const WorkloadInput = union(enum) {
    cells: []render.Render.CellInput,
    cell_texts: []const render.Render.Text.Cluster.CellTextInput,
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
    resolve_us: u64,
    shape_us: u64,
    group_us: u64,
    scene_us: u64,
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
    complex_icon_cells: usize,
    complex_curly_underline_cells: usize,
    normal_clusters: usize,
    complex_clusters: usize,
    direct_normal_draws: usize,
    complex_path_resolved_normal_clusters: usize,
    complex_path_resolved_complex_clusters: usize,
    complex_path_shaped_normal_clusters: usize,
    complex_path_shaped_complex_clusters: usize,
    complex_path_grouped_normal_groups: usize,
    complex_path_grouped_complex_groups: usize,
    complex_path_scene_normal_sprite_draws: usize,
    complex_path_scene_complex_sprite_draws: usize,
    frame_fully_normal_input: bool,
    frame_stayed_out_of_complex_path: bool,
    dirty_cells_per_run: usize,
    runs: usize,
    cold_ns: u64,
    cold_resolve_us: u64,
    cold_shape_us: u64,
    cold_group_us: u64,
    cold_scene_us: u64,
    cold_alloc_count: usize,
    cold_alloc_bytes: usize,
    cold_peak_live_bytes: usize,
    cold_fills: usize,
    cold_glyphs: usize,
    cold_uploads: usize,
    cold_direct_normal_raster_misses: usize,
    warm_median_ns: u64,
    warm_p95_ns: u64,
    warm_median_resolve_us: u64,
    warm_median_shape_us: u64,
    warm_median_group_us: u64,
    warm_median_scene_us: u64,
    warm_median_alloc_count: usize,
    warm_median_alloc_bytes: usize,
    warm_median_peak_live_bytes: usize,
    warm_median_fills: usize,
    warm_median_glyphs: usize,
    warm_median_uploads: usize,
    warm_direct_normal_raster_misses: usize,

    fn dirtyCellsPerSecond(self: WorkloadResult) f64 {
        const median_seconds = @as(f64, @floatFromInt(self.warm_median_ns)) / 1_000_000_000.0;
        if (median_seconds <= 0) return 0;
        return @as(f64, @floatFromInt(self.dirty_cells_per_run)) / median_seconds;
    }
};

const Workload = struct {
    name: []const u8,
    input: WorkloadInput,
    grid: render.Render.GridMetrics,
    damage: struct {
        full: bool,
        scroll_up_rows: u16 = 0,
        dirty_rows: []const bool,
        dirty_cols_start: []const u16,
        dirty_cols_end: []const u16,
    },
    cell_px: render.Render.CellSize,
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

fn rgba(r: u8, g: u8, b: u8) render.Render.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn defaultCellMetrics(cell_px: render.Render.CellSize) render.Render.CellMetrics {
    const h = @max(cell_px.height, 1);
    return .{
        .cell_w_px = @max(cell_px.width, 1),
        .cell_h_px = h,
        .baseline_px = @intCast(@max(h - @divFloor(h, 5), 1)),
    };
}

fn initCells(allocator: std.mem.Allocator, rows: u16, cols: u16, bg: render.Render.Rgba8) ![]render.Render.CellInput {
    const len = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(render.Render.CellInput, len);
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
    const cells = try allocator.alloc(render.Render.Text.Cluster.CellTextInput, @as(usize, rows) * @as(usize, cols));
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
    const cells = try allocator.alloc(render.Render.Text.Cluster.CellTextInput, @as(usize, rows) * @as(usize, cols));
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
    const cells = try allocator.alloc(render.Render.Text.Cluster.CellTextInput, @as(usize, rows) * @as(usize, cols));
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

fn buildCurlyUnderlineMixedWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 18;
    const cols: u16 = 64;
    const bg = rgba(12, 16, 20);
    const fg = rgba(234, 238, 242);
    const accent = rgba(255, 180, 120);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const curly = idx % 3 == 1;
        cell.* = .{
            .codepoint = if (curly) 'u' else 'n',
            .fg = if (curly) accent else fg,
            .bg = bg,
            .underline = curly,
            .underline_style = if (curly) .curly else .straight,
        };
    }
    return .{
        .name = "curly_underline_mixed",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = cells.len,
        .input = .{ .cells = cells },
        .grid = .{ .cols = cols, .rows = rows },
        .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
    };
}

fn buildIconPuaMixedWorkload(allocator: std.mem.Allocator) !Workload {
    const rows: u16 = 12;
    const cols: u16 = 48;
    const bg = rgba(14, 16, 22);
    const fg = rgba(236, 239, 243);
    const accent = rgba(255, 196, 96);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const icon = idx % 4 == 1;
        cell.* = .{
            .codepoint = if (icon) 0xf101 else 'n',
            .fg = if (icon) accent else fg,
            .bg = bg,
        };
    }
    return .{
        .name = "icon_pua_mixed",
        .cell_px = .{ .width = 9, .height = 18 },
        .dirty_cells_per_run = cells.len,
        .input = .{ .cells = cells },
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
    const session = render.Render.Text.FontSession.FontSession{
        .primary_face = .{ .value = 1 },
        .metrics = cell_metrics,
    };
    const analysis_options = render.Render.Text.Engine.AnalysisOptions{
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
    var engine = render.Render.Text.Engine.Engine.init(counting.allocator());
    defer engine.deinit();

    counting.resetWindow();
    const cold_start = nowNs(io);
    var cold = switch (workload.input) {
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
    const cold_end = nowNs(io);
    const cold_lane_report = cold.lane_report;
    const cold_observation = RunObservation{
        .ns = cold_end - cold_start,
        .alloc_count = counting.window_alloc_count,
        .alloc_bytes = counting.window_alloc_bytes,
        .peak_live_bytes = counting.window_peak_live_bytes,
        .resolve_us = cold.timings.resolve_us,
        .shape_us = cold.timings.shape_us,
        .group_us = cold.timings.group_us,
        .scene_us = cold.timings.scene_us,
    };
    const cold_fills = cold.scene.scene.background_draws.len + cold.scene.scene.decoration_draws.len + cold.scene.scene.cursor_draws.len;
    const cold_glyphs = cold.scene.scene.sprite_draws.len;
    const cold_uploads = cold.raster_plan.outputs.len;
    for (cold.raster_plan.outputs) |output| _ = engine.atlas.markRendered(output.key);
    cold.deinit();

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
            assertSameLaneCounts(cold_lane_report, run_lane_report);
        }
        observations[i] = .{
            .ns = end - start,
            .alloc_count = counting.window_alloc_count,
            .alloc_bytes = counting.window_alloc_bytes,
            .peak_live_bytes = counting.window_peak_live_bytes,
            .resolve_us = analysis.timings.resolve_us,
            .shape_us = analysis.timings.shape_us,
            .group_us = analysis.timings.group_us,
            .scene_us = analysis.timings.scene_us,
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
    const resolve_values = try allocator.alloc(u64, runs);
    defer allocator.free(resolve_values);
    const shape_values = try allocator.alloc(u64, runs);
    defer allocator.free(shape_values);
    const group_values = try allocator.alloc(u64, runs);
    defer allocator.free(group_values);
    const scene_values = try allocator.alloc(u64, runs);
    defer allocator.free(scene_values);

    for (observations, 0..) |obs, idx| {
        ns_values[idx] = obs.ns;
        alloc_count_values[idx] = obs.alloc_count;
        alloc_bytes_values[idx] = obs.alloc_bytes;
        peak_live_values[idx] = obs.peak_live_bytes;
        resolve_values[idx] = obs.resolve_us;
        shape_values[idx] = obs.shape_us;
        group_values[idx] = obs.group_us;
        scene_values[idx] = obs.scene_us;
    }

    const final_lane_report = lane_report orelse LaneReport{};
    assertSameLaneCounts(cold_lane_report, final_lane_report);
    const warm_median_ns = medianU64(ns_values);
    const warm_p95_ns = p95U64(ns_values);
    const warm_median_resolve_us = medianU64(resolve_values);
    const warm_median_shape_us = medianU64(shape_values);
    const warm_median_group_us = medianU64(group_values);
    const warm_median_scene_us = medianU64(scene_values);
    const warm_median_alloc_count = medianUsize(alloc_count_values);
    const warm_median_alloc_bytes = medianUsize(alloc_bytes_values);
    const warm_median_peak_live_bytes = medianUsize(peak_live_values);
    const warm_median_fills = medianUsize(fill_values);
    const warm_median_glyphs = medianUsize(glyph_values);
    const warm_median_uploads = medianUsize(upload_values);
    std.debug.assert(cold_uploads >= warm_median_uploads);
    std.debug.assert(cold_lane_report.direct_normal_raster_misses >= final_lane_report.direct_normal_raster_misses);

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
        .complex_icon_cells = final_lane_report.complex_icon_cells,
        .complex_curly_underline_cells = final_lane_report.complex_curly_underline_cells,
        .normal_clusters = final_lane_report.normal_clusters,
        .complex_clusters = final_lane_report.complex_clusters,
        .direct_normal_draws = final_lane_report.direct_normal_draws,
        .complex_path_resolved_normal_clusters = final_lane_report.legacy.resolved_clusters.normal,
        .complex_path_resolved_complex_clusters = final_lane_report.legacy.resolved_clusters.complex,
        .complex_path_shaped_normal_clusters = final_lane_report.legacy.shaped_clusters.normal,
        .complex_path_shaped_complex_clusters = final_lane_report.legacy.shaped_clusters.complex,
        .complex_path_grouped_normal_groups = final_lane_report.legacy.grouped_groups.normal,
        .complex_path_grouped_complex_groups = final_lane_report.legacy.grouped_groups.complex,
        .complex_path_scene_normal_sprite_draws = final_lane_report.legacy.scene_sprite_draws.normal,
        .complex_path_scene_complex_sprite_draws = final_lane_report.legacy.scene_sprite_draws.complex,
        .frame_fully_normal_input = final_lane_report.frameFullyNormalInput(),
        .frame_stayed_out_of_complex_path = final_lane_report.frameStayedOutOfLegacyPath(),
        .dirty_cells_per_run = workload.dirty_cells_per_run,
        .runs = runs,
        .cold_ns = cold_observation.ns,
        .cold_resolve_us = cold_observation.resolve_us,
        .cold_shape_us = cold_observation.shape_us,
        .cold_group_us = cold_observation.group_us,
        .cold_scene_us = cold_observation.scene_us,
        .cold_alloc_count = cold_observation.alloc_count,
        .cold_alloc_bytes = cold_observation.alloc_bytes,
        .cold_peak_live_bytes = cold_observation.peak_live_bytes,
        .cold_fills = cold_fills,
        .cold_glyphs = cold_glyphs,
        .cold_uploads = cold_uploads,
        .cold_direct_normal_raster_misses = cold_lane_report.direct_normal_raster_misses,
        .warm_median_ns = warm_median_ns,
        .warm_p95_ns = warm_p95_ns,
        .warm_median_resolve_us = warm_median_resolve_us,
        .warm_median_shape_us = warm_median_shape_us,
        .warm_median_group_us = warm_median_group_us,
        .warm_median_scene_us = warm_median_scene_us,
        .warm_median_alloc_count = warm_median_alloc_count,
        .warm_median_alloc_bytes = warm_median_alloc_bytes,
        .warm_median_peak_live_bytes = warm_median_peak_live_bytes,
        .warm_median_fills = warm_median_fills,
        .warm_median_glyphs = warm_median_glyphs,
        .warm_median_uploads = warm_median_uploads,
        .warm_direct_normal_raster_misses = final_lane_report.direct_normal_raster_misses,
    };
}

fn assertSameLaneCounts(expected: LaneReport, actual: LaneReport) void {
    std.debug.assert(expected.visible_cells == actual.visible_cells);
    std.debug.assert(expected.normal_cells == actual.normal_cells);
    std.debug.assert(expected.complex_cells == actual.complex_cells);
    std.debug.assert(expected.complex_multi_codepoint_cells == actual.complex_multi_codepoint_cells);
    std.debug.assert(expected.complex_emoji_cells == actual.complex_emoji_cells);
    std.debug.assert(expected.complex_special_sprite_cells == actual.complex_special_sprite_cells);
    std.debug.assert(expected.complex_icon_cells == actual.complex_icon_cells);
    std.debug.assert(expected.complex_curly_underline_cells == actual.complex_curly_underline_cells);
    std.debug.assert(expected.normal_clusters == actual.normal_clusters);
    std.debug.assert(expected.complex_clusters == actual.complex_clusters);
    std.debug.assert(expected.direct_normal_draws == actual.direct_normal_draws);
    std.debug.assert(expected.legacy.resolved_clusters.normal == actual.legacy.resolved_clusters.normal);
    std.debug.assert(expected.legacy.resolved_clusters.complex == actual.legacy.resolved_clusters.complex);
    std.debug.assert(expected.legacy.shaped_clusters.normal == actual.legacy.shaped_clusters.normal);
    std.debug.assert(expected.legacy.shaped_clusters.complex == actual.legacy.shaped_clusters.complex);
    std.debug.assert(expected.legacy.grouped_groups.normal == actual.legacy.grouped_groups.normal);
    std.debug.assert(expected.legacy.grouped_groups.complex == actual.legacy.grouped_groups.complex);
    std.debug.assert(expected.legacy.scene_sprite_draws.normal == actual.legacy.scene_sprite_draws.normal);
    std.debug.assert(expected.legacy.scene_sprite_draws.complex == actual.legacy.scene_sprite_draws.complex);
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
    const cold_ms = @as(f64, @floatFromInt(result.cold_ns)) / 1_000_000.0;
    const warm_median_ms = @as(f64, @floatFromInt(result.warm_median_ns)) / 1_000_000.0;
    const warm_p95_ms = @as(f64, @floatFromInt(result.warm_p95_ns)) / 1_000_000.0;
    std.debug.print("workload={s}\n", .{result.name});
    std.debug.print("grid_cols={d}\n", .{result.grid_cols});
    std.debug.print("grid_rows={d}\n", .{result.grid_rows});
    std.debug.print("visible_cells={d}\n", .{result.visible_cells});
    std.debug.print("normal_cells={d}\n", .{result.normal_cells});
    std.debug.print("complex_cells={d}\n", .{result.complex_cells});
    std.debug.print("complex_multi_codepoint_cells={d}\n", .{result.complex_multi_codepoint_cells});
    std.debug.print("complex_emoji_cells={d}\n", .{result.complex_emoji_cells});
    std.debug.print("complex_special_sprite_cells={d}\n", .{result.complex_special_sprite_cells});
    std.debug.print("complex_icon_cells={d}\n", .{result.complex_icon_cells});
    std.debug.print("complex_curly_underline_cells={d}\n", .{result.complex_curly_underline_cells});
    std.debug.print("normal_clusters={d}\n", .{result.normal_clusters});
    std.debug.print("complex_clusters={d}\n", .{result.complex_clusters});
    std.debug.print("direct_normal_draws={d}\n", .{result.direct_normal_draws});
    std.debug.print("cold_direct_normal_raster_misses={d}\n", .{result.cold_direct_normal_raster_misses});
    std.debug.print("warm_direct_normal_raster_misses={d}\n", .{result.warm_direct_normal_raster_misses});
    std.debug.print("complex_path_resolved_normal_clusters={d}\n", .{result.complex_path_resolved_normal_clusters});
    std.debug.print("complex_path_resolved_complex_clusters={d}\n", .{result.complex_path_resolved_complex_clusters});
    std.debug.print("complex_path_shaped_normal_clusters={d}\n", .{result.complex_path_shaped_normal_clusters});
    std.debug.print("complex_path_shaped_complex_clusters={d}\n", .{result.complex_path_shaped_complex_clusters});
    std.debug.print("complex_path_grouped_normal_groups={d}\n", .{result.complex_path_grouped_normal_groups});
    std.debug.print("complex_path_grouped_complex_groups={d}\n", .{result.complex_path_grouped_complex_groups});
    std.debug.print("complex_path_scene_normal_sprite_draws={d}\n", .{result.complex_path_scene_normal_sprite_draws});
    std.debug.print("complex_path_scene_complex_sprite_draws={d}\n", .{result.complex_path_scene_complex_sprite_draws});
    std.debug.print("frame_fully_normal_input={}\n", .{result.frame_fully_normal_input});
    std.debug.print("frame_stayed_out_of_complex_path={}\n", .{result.frame_stayed_out_of_complex_path});
    std.debug.print("runs={d}\n", .{result.runs});
    std.debug.print("dirty_cells_per_run={d}\n", .{result.dirty_cells_per_run});
    std.debug.print("cold_ms={d:.3}\n", .{cold_ms});
    std.debug.print("cold_resolve_us={d}\n", .{result.cold_resolve_us});
    std.debug.print("cold_shape_us={d}\n", .{result.cold_shape_us});
    std.debug.print("cold_group_us={d}\n", .{result.cold_group_us});
    std.debug.print("cold_scene_us={d}\n", .{result.cold_scene_us});
    std.debug.print("cold_alloc_count={d}\n", .{result.cold_alloc_count});
    std.debug.print("cold_alloc_bytes={d}\n", .{result.cold_alloc_bytes});
    std.debug.print("cold_peak_live_bytes={d}\n", .{result.cold_peak_live_bytes});
    std.debug.print("cold_fills={d}\n", .{result.cold_fills});
    std.debug.print("cold_glyphs={d}\n", .{result.cold_glyphs});
    std.debug.print("cold_uploads={d}\n", .{result.cold_uploads});
    std.debug.print("warm_median_ms={d:.3}\n", .{warm_median_ms});
    std.debug.print("warm_p95_ms={d:.3}\n", .{warm_p95_ms});
    std.debug.print("warm_median_resolve_us={d}\n", .{result.warm_median_resolve_us});
    std.debug.print("warm_median_shape_us={d}\n", .{result.warm_median_shape_us});
    std.debug.print("warm_median_group_us={d}\n", .{result.warm_median_group_us});
    std.debug.print("warm_median_scene_us={d}\n", .{result.warm_median_scene_us});
    std.debug.print("dirty_cells_per_second={d:.0}\n", .{result.dirtyCellsPerSecond()});
    std.debug.print("warm_median_alloc_count={d}\n", .{result.warm_median_alloc_count});
    std.debug.print("warm_median_alloc_bytes={d}\n", .{result.warm_median_alloc_bytes});
    std.debug.print("warm_median_peak_live_bytes={d}\n", .{result.warm_median_peak_live_bytes});
    std.debug.print("warm_median_fills={d}\n", .{result.warm_median_fills});
    std.debug.print("warm_median_glyphs={d}\n", .{result.warm_median_glyphs});
    std.debug.print("warm_median_uploads={d}\n", .{result.warm_median_uploads});
    std.debug.print("---\n", .{});
}

fn printNdjsonResult(result: WorkloadResult) void {
    std.debug.print(
        "{{\"workload\":\"{s}\",\"grid_cols\":{d},\"grid_rows\":{d},\"visible_cells\":{d},\"normal_cells\":{d},\"complex_cells\":{d},\"complex_multi_codepoint_cells\":{d},\"complex_emoji_cells\":{d},\"complex_special_sprite_cells\":{d},\"complex_icon_cells\":{d},\"complex_curly_underline_cells\":{d},\"normal_clusters\":{d},\"complex_clusters\":{d},\"direct_normal_draws\":{d},\"cold_direct_normal_raster_misses\":{d},\"warm_direct_normal_raster_misses\":{d},\"complex_path_resolved_normal_clusters\":{d},\"complex_path_resolved_complex_clusters\":{d},\"complex_path_shaped_normal_clusters\":{d},\"complex_path_shaped_complex_clusters\":{d},\"complex_path_grouped_normal_groups\":{d},\"complex_path_grouped_complex_groups\":{d},",
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
            result.complex_icon_cells,
            result.complex_curly_underline_cells,
            result.normal_clusters,
            result.complex_clusters,
            result.direct_normal_draws,
            result.cold_direct_normal_raster_misses,
            result.warm_direct_normal_raster_misses,
            result.complex_path_resolved_normal_clusters,
            result.complex_path_resolved_complex_clusters,
            result.complex_path_shaped_normal_clusters,
            result.complex_path_shaped_complex_clusters,
            result.complex_path_grouped_normal_groups,
            result.complex_path_grouped_complex_groups,
        },
    );
    std.debug.print(
        "\"complex_path_scene_normal_sprite_draws\":{d},\"complex_path_scene_complex_sprite_draws\":{d},\"frame_fully_normal_input\":{},\"frame_stayed_out_of_complex_path\":{},\"runs\":{d},\"dirty_cells_per_run\":{d},\"cold_ns\":{d},\"cold_resolve_us\":{d},\"cold_shape_us\":{d},\"cold_group_us\":{d},\"cold_scene_us\":{d},\"cold_alloc_count\":{d},\"cold_alloc_bytes\":{d},\"cold_peak_live_bytes\":{d},\"cold_fills\":{d},\"cold_glyphs\":{d},\"cold_uploads\":{d},\"warm_median_ns\":{d},\"warm_p95_ns\":{d},\"warm_median_resolve_us\":{d},\"warm_median_shape_us\":{d},\"warm_median_group_us\":{d},\"warm_median_scene_us\":{d},\"dirty_cells_per_second\":{d:.0},\"warm_median_alloc_count\":{d},\"warm_median_alloc_bytes\":{d},\"warm_median_peak_live_bytes\":{d},\"warm_median_fills\":{d},\"warm_median_glyphs\":{d},\"warm_median_uploads\":{d}}}\n",
        .{
            result.complex_path_scene_normal_sprite_draws,
            result.complex_path_scene_complex_sprite_draws,
            result.frame_fully_normal_input,
            result.frame_stayed_out_of_complex_path,
            result.runs,
            result.dirty_cells_per_run,
            result.cold_ns,
            result.cold_resolve_us,
            result.cold_shape_us,
            result.cold_group_us,
            result.cold_scene_us,
            result.cold_alloc_count,
            result.cold_alloc_bytes,
            result.cold_peak_live_bytes,
            result.cold_fills,
            result.cold_glyphs,
            result.cold_uploads,
            result.warm_median_ns,
            result.warm_p95_ns,
            result.warm_median_resolve_us,
            result.warm_median_shape_us,
            result.warm_median_group_us,
            result.warm_median_scene_us,
            result.dirtyCellsPerSecond(),
            result.warm_median_alloc_count,
            result.warm_median_alloc_bytes,
            result.warm_median_peak_live_bytes,
            result.warm_median_fills,
            result.warm_median_glyphs,
            result.warm_median_uploads,
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
        try buildCurlyUnderlineMixedWorkload(arena),
        try buildIconPuaMixedWorkload(arena),
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
