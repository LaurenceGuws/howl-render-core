//! Responsibility: run deterministic render-core batch measurements.
//! Ownership: render-core benchmark surface for synthetic frame workloads.
//! Reason: isolate batch-build cost before host and backend noise.

const std = @import("std");
const render = @import("howl_render");

const OutputFormat = enum { ndjson, text };

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
    state: render.VtState,
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

fn rgba(r: u8, g: u8, b: u8) render.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn initCells(allocator: std.mem.Allocator, rows: u16, cols: u16, bg: render.Rgba8) ![]render.CellInput {
    const len = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(render.CellInput, len);
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
        .dirty_cells_per_run = @as(usize, rows) * @as(usize, cols),
        .state = .{
            .surface_px = .{ .width = cols * 9, .height = rows * 18 },
            .cell_px = .{ .width = 9, .height = 18 },
            .grid = .{ .cells = cells, .cols = cols, .rows = rows },
            .cursor = .{ .col = 10, .row = 4, .shape = .block, .color = rgba(255, 220, 120) },
            .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
        },
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
        .dirty_cells_per_run = active_rows.len * 80,
        .state = .{
            .surface_px = .{ .width = cols * 9, .height = rows * 18 },
            .cell_px = .{ .width = 9, .height = 18 },
            .grid = .{ .cells = cells, .cols = cols, .rows = rows },
            .cursor = .{ .col = 12, .row = 18, .shape = .beam, .color = accent },
            .damage = .{ .full = false, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
        },
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
        .dirty_cells_per_run = @as(usize, rows) * @as(usize, cols),
        .state = .{
            .surface_px = .{ .width = cols * 10, .height = rows * 18 },
            .cell_px = .{ .width = 10, .height = 18 },
            .grid = .{ .cells = cells, .cols = cols, .rows = rows },
            .cursor = .{ .col = 50, .row = 20, .shape = .underline, .color = rgba(255, 255, 255) },
            .damage = .{ .full = true, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
        },
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
        .dirty_cells_per_run = dirty_rows_list.len * 108,
        .state = .{
            .surface_px = .{ .width = cols * 9, .height = rows * 17 },
            .cell_px = .{ .width = 9, .height = 17 },
            .grid = .{ .cells = cells, .cols = cols, .rows = rows },
            .damage = .{ .full = false, .dirty_rows = dirty.rows, .dirty_cols_start = dirty.starts, .dirty_cols_end = dirty.ends },
        },
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

    const config = render.BackendConfig{
        .surface_px = workload.state.surface_px,
        .cell_px = workload.state.cell_px,
    };
    const capability = render.BackendCapability{
        .max_atlas_slots = 4096,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const rc = render.init(config, capability);

    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var counting = CountingAllocator.init(allocator);
        counting.resetWindow();
        const start = nowNs(io);
        var owned = try rc.renderBatch(counting.allocator(), workload.state);
        const end = nowNs(io);
        const stats = owned.batch.stats();
        observations[i] = .{
            .ns = end - start,
            .alloc_count = counting.window_alloc_count,
            .alloc_bytes = counting.window_alloc_bytes,
            .peak_live_bytes = counting.window_peak_live_bytes,
        };
        fill_values[i] = stats.fills;
        glyph_values[i] = stats.glyphs;
        upload_values[i] = stats.atlas_uploads;
        owned.deinit();
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

    return .{
        .name = workload.name,
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
        "{{\"workload\":\"{s}\",\"runs\":{d},\"dirty_cells_per_run\":{d},\"median_ns\":{d},\"p95_ns\":{d},\"dirty_cells_per_second\":{d:.0},\"median_alloc_count\":{d},\"median_alloc_bytes\":{d},\"median_peak_live_bytes\":{d},\"median_fills\":{d},\"median_glyphs\":{d},\"median_uploads\":{d}}}\n",
        .{
            result.name,
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
        try buildSparseRowsWorkload(arena),
        try buildMixedBoxWorkload(arena),
        try buildWideDirtySpansWorkload(arena),
    };

    for (workloads) |workload| {
        const result = try runWorkload(io, arena, workload, opts.runs);
        switch (opts.format) {
            .ndjson => printNdjsonResult(result),
            .text => printTextResult(result),
        }
    }
}
