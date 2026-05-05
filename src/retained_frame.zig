//! Responsibility: own renderer-side visible cell staging.
//! Ownership: retained render cell storage updated from dirty frame spans.
//! Reason: avoid rebuilding transient render cell input for every frame.

const std = @import("std");
const frame_state = @import("frame_state.zig");
const render_batch = @import("render_batch.zig");
const vt_state = @import("vt_state.zig");

pub const RetainedFrame = struct {
    const RowCache = struct {
        fills: std.ArrayListUnmanaged(render_batch.FillRect) = .empty,
        glyphs: std.ArrayListUnmanaged(render_batch.GlyphQuad) = .empty,

        fn deinit(self: *RowCache, allocator: std.mem.Allocator) void {
            self.fills.deinit(allocator);
            self.glyphs.deinit(allocator);
            self.* = .{};
        }

        fn clear(self: *RowCache) void {
            self.fills.clearRetainingCapacity();
            self.glyphs.clearRetainingCapacity();
        }
    };

    cells: std.ArrayListUnmanaged(render_batch.CellInput) = .empty,
    row_caches: std.ArrayListUnmanaged(RowCache) = .empty,
    dirty_rows: std.ArrayListUnmanaged(bool) = .empty,
    dirty_cols_start: std.ArrayListUnmanaged(u16) = .empty,
    dirty_cols_end: std.ArrayListUnmanaged(u16) = .empty,
    cols: u16 = 0,
    rows: u16 = 0,
    last_cell_height: u16 = 0,

    pub fn deinit(self: *RetainedFrame, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        for (self.row_caches.items) |*row_cache| row_cache.deinit(allocator);
        self.row_caches.deinit(allocator);
        self.dirty_rows.deinit(allocator);
        self.dirty_cols_start.deinit(allocator);
        self.dirty_cols_end.deinit(allocator);
        self.* = .{};
    }

    pub fn prepareBatch(
        self: *RetainedFrame,
        retained_allocator: std.mem.Allocator,
        allocator: std.mem.Allocator,
        state: frame_state.FrameData,
        surface_px: render_batch.PixelSize,
        cell_px: render_batch.CellSize,
        theme: vt_state.FrameTheme,
        capability: render_batch.BackendCapability,
    ) !render_batch.OwnedRenderBatch {
        try self.ensureSize(retained_allocator, state.grid.rows, state.grid.cols);
        self.last_cell_height = cell_px.height;

        const source_count = @min(state.grid.cells.len, self.cells.items.len);
        const scroll_up_rows = if (state.damage.full) 0 else @min(state.damage.scroll_up_rows, state.grid.rows);
        const full = state.damage.full or
            state.damage.dirty_rows.len != @as(usize, state.grid.rows) or
            state.damage.dirty_cols_start.len != @as(usize, state.grid.rows) or
            state.damage.dirty_cols_end.len != @as(usize, state.grid.rows);

        if (!full and scroll_up_rows > 0) self.applyScrollUp(retained_allocator, scroll_up_rows);

        if (full) {
            var idx: usize = 0;
            while (idx < source_count) : (idx += 1) self.cells.items[idx] = mapCell(state.grid.cells[idx], theme);
            @memset(self.dirty_rows.items, true);
            @memset(self.dirty_cols_start.items, 0);
            @memset(self.dirty_cols_end.items, if (state.grid.cols == 0) 0 else state.grid.cols -| 1);
        } else {
            @memcpy(self.dirty_rows.items, state.damage.dirty_rows);
            @memcpy(self.dirty_cols_start.items, state.damage.dirty_cols_start);
            @memcpy(self.dirty_cols_end.items, state.damage.dirty_cols_end);
            var row: usize = 0;
            while (row < @as(usize, state.grid.rows)) : (row += 1) {
                if (!state.damage.dirty_rows[row]) continue;
                const start_col = @min(@as(usize, state.damage.dirty_cols_start[row]), @as(usize, state.grid.cols));
                const end_col = @min(@as(usize, state.damage.dirty_cols_end[row]) +| 1, @as(usize, state.grid.cols));
                if (start_col >= end_col) continue;
                var col = start_col;
                while (col < end_col) : (col += 1) {
                    const idx = row * @as(usize, state.grid.cols) + col;
                    if (idx >= source_count) break;
                    self.cells.items[idx] = mapCell(state.grid.cells[idx], theme);
                }
            }
        }

        try self.rebuildDirtyRows(retained_allocator, surface_px, cell_px, full, capability);
        return self.flattenOwnedBatch(allocator, surface_px, cell_px, full, scroll_up_rows, state.cursor, theme, capability);
    }

    fn ensureSize(self: *RetainedFrame, allocator: std.mem.Allocator, rows: u16, cols: u16) !void {
        if (self.rows == rows and self.cols == cols and self.cells.items.len == @as(usize, rows) * @as(usize, cols)) return;
        for (self.row_caches.items) |*row_cache| row_cache.deinit(allocator);
        self.row_caches.deinit(allocator);
        self.row_caches = .empty;
        self.rows = rows;
        self.cols = cols;
        try self.cells.resize(allocator, @as(usize, rows) * @as(usize, cols));
        try self.row_caches.resize(allocator, rows);
        try self.dirty_rows.resize(allocator, rows);
        try self.dirty_cols_start.resize(allocator, rows);
        try self.dirty_cols_end.resize(allocator, rows);
        for (self.row_caches.items) |*row_cache| row_cache.* = .{};
        @memset(self.cells.items, .{ .codepoint = ' ', .fg = vt_state.default_theme.default_fg, .bg = vt_state.default_theme.default_bg });
        @memset(self.dirty_rows.items, true);
        @memset(self.dirty_cols_start.items, 0);
        @memset(self.dirty_cols_end.items, if (cols == 0) 0 else cols -| 1);
    }

    fn rebuildDirtyRows(
        self: *RetainedFrame,
        allocator: std.mem.Allocator,
        surface_px: render_batch.PixelSize,
        cell_px: render_batch.CellSize,
        full: bool,
        capability: render_batch.BackendCapability,
    ) !void {
        var row: usize = 0;
        while (row < @as(usize, self.rows)) : (row += 1) {
            if (!full and !self.dirty_rows.items[row]) continue;
            var row_cache = &self.row_caches.items[row];
            row_cache.clear();
            try buildRowCache(row_cache, allocator, self.cells.items, self.cols, row, surface_px, cell_px, capability);
        }
    }

    fn applyScrollUp(self: *RetainedFrame, allocator: std.mem.Allocator, delta_rows: u16) void {
        const rows = @as(usize, self.rows);
        const cols = @as(usize, self.cols);
        const delta = @min(@as(usize, delta_rows), rows);
        if (delta == 0 or delta >= rows or cols == 0) return;
        const scroll_y: i32 = @intCast(delta * @as(usize, self.last_cell_height));
        const shift_cells = delta * cols;
        const keep_cells = (rows - delta) * cols;
        std.mem.copyForwards(
            render_batch.CellInput,
            self.cells.items[0..keep_cells],
            self.cells.items[shift_cells .. shift_cells + keep_cells],
        );
        for (self.row_caches.items[0..delta]) |*row_cache| row_cache.deinit(allocator);
        std.mem.copyForwards(
            RowCache,
            self.row_caches.items[0 .. rows - delta],
            self.row_caches.items[delta..rows],
        );
        for (self.row_caches.items[0 .. rows - delta]) |*row_cache| shiftRowCacheY(row_cache, -scroll_y);
        for (self.row_caches.items[rows - delta .. rows]) |*row_cache| row_cache.* = .{};
    }

    fn flattenOwnedBatch(
        self: *RetainedFrame,
        allocator: std.mem.Allocator,
        surface_px: render_batch.PixelSize,
        cell_px: render_batch.CellSize,
        full: bool,
        scroll_up_rows: u16,
        cursor: frame_state.CursorInfo,
        theme: vt_state.FrameTheme,
        capability: render_batch.BackendCapability,
    ) !render_batch.OwnedRenderBatch {
        const include_all_rows = full;
        var fill_count: usize = 0;
        var glyph_count: usize = 0;
        var row: usize = 0;
        while (row < @as(usize, self.rows)) : (row += 1) {
            if (!include_all_rows and !self.dirty_rows.items[row]) continue;
            fill_count += self.row_caches.items[row].fills.items.len;
            glyph_count += self.row_caches.items[row].glyphs.items.len;
        }

        const fills_owned = try allocator.alloc(render_batch.FillRect, fill_count);
        errdefer allocator.free(fills_owned);
        const glyphs_owned = try allocator.alloc(render_batch.GlyphQuad, glyph_count);
        errdefer allocator.free(glyphs_owned);

        var uploads = std.ArrayList(render_batch.AtlasUpload).initCapacity(allocator, glyph_count) catch return error.OutOfMemory;
        defer uploads.deinit(allocator);
        var uploaded_codepoints = std.AutoHashMap(u21, void).init(allocator);
        defer uploaded_codepoints.deinit();

        var fill_offset: usize = 0;
        var glyph_offset: usize = 0;
        row = 0;
        while (row < @as(usize, self.rows)) : (row += 1) {
            if (!include_all_rows and !self.dirty_rows.items[row]) continue;
            const row_cache = &self.row_caches.items[row];
            if (row_cache.fills.items.len > 0) {
                @memcpy(fills_owned[fill_offset .. fill_offset + row_cache.fills.items.len], row_cache.fills.items);
                fill_offset += row_cache.fills.items.len;
            }
            for (row_cache.glyphs.items) |glyph| {
                glyphs_owned[glyph_offset] = glyph;
                glyph_offset += 1;
                if (capability.supports_glyph_quads and capability.max_atlas_slots > 0 and glyph.codepoint > 0x20) {
                    if (!uploaded_codepoints.contains(glyph.codepoint)) {
                        try uploaded_codepoints.put(glyph.codepoint, {});
                        try uploads.append(allocator, .{ .codepoint = glyph.codepoint, .width = cell_px.width, .height = cell_px.height });
                    }
                }
            }
        }

        const uploads_owned = try uploads.toOwnedSlice(allocator);
        const cursor_draw: ?render_batch.CursorDraw = if (cursor.visible) .{
            .cell_col = cursor.col,
            .cell_row = cursor.row,
            .shape = mapCursorShape(cursor.shape),
            .color = theme.cursor_color,
        } else null;

        return .{
            .batch = .{
                .surface_px = surface_px,
                .cell_px = cell_px,
                .grid = .{ .cols = self.cols, .rows = self.rows },
                .full_redraw = full,
                .scroll_up_rows = if (full) 0 else scroll_up_rows,
                .fills = fills_owned,
                .glyphs = glyphs_owned,
                .cursor = cursor_draw,
                .atlas_uploads = uploads_owned,
            },
            ._fills = fills_owned,
            ._glyphs = glyphs_owned,
            ._uploads = uploads_owned,
            ._allocator = allocator,
        };
    }
};

fn buildRowCache(
    row_cache: *RetainedFrame.RowCache,
    allocator: std.mem.Allocator,
    cells: []const render_batch.CellInput,
    cols: u16,
    row: usize,
    surface_px: render_batch.PixelSize,
    cell_px: render_batch.CellSize,
    capability: render_batch.BackendCapability,
) !void {
    const col_end_exclusive = @as(usize, cols);
    if (col_end_exclusive == 0) return;
    try appendBackgroundSpans(&row_cache.fills, allocator, cells, cols, row, 0, col_end_exclusive, cell_px);
    const glyphs_enabled = capability.supports_glyph_quads and capability.max_atlas_slots > 0;
    var col: usize = 0;
    while (col < col_end_exclusive) : (col += 1) {
        const idx = row * @as(usize, cols) + col;
        if (idx >= cells.len) break;
        const cell = cells[idx];
        const cell_x: i32 = @intCast(col * @as(usize, cell_px.width));
        const cell_y: i32 = @intCast(row * @as(usize, cell_px.height));
        const procedural = try tryAppendProceduralGlyph(
            &row_cache.fills,
            allocator,
            cell,
            cell.codepoint,
            cell_x,
            cell_y,
            cell_px.width,
            cell_px.height,
        );
        if (procedural) continue;
        if (glyphs_enabled and cell.codepoint > 0x20 and !cell.continuation) {
            try row_cache.glyphs.append(allocator, .{
                .x = cell_x,
                .y = cell_y,
                .width = cell_px.width,
                .height = cell_px.height,
                .codepoint = cell.codepoint,
                .fg = cell.fg,
            });
        }
    }
    _ = surface_px;
}

fn mapCell(src: frame_state.Cell, theme: vt_state.FrameTheme) render_batch.CellInput {
    return .{
        .codepoint = src.codepoint,
        .fg = colorToRgba8(src.fg_color, true, theme),
        .bg = colorToRgba8(src.bg_color, false, theme),
        .continuation = src.flags.continuation,
    };
}

fn colorToRgba8(color: frame_state.Color, is_fg: bool, theme: vt_state.FrameTheme) render_batch.Rgba8 {
    return switch (color.kind) {
        .default => if (is_fg) theme.default_fg else theme.default_bg,
        .indexed => indexed256(@intCast(color.value & 0xFF), theme),
        .rgb => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
    };
}

fn indexed256(idx: u8, theme: vt_state.FrameTheme) render_batch.Rgba8 {
    if (idx < 16) return theme.ansi16[idx];
    if (idx < 232) {
        const i: u32 = idx - 16;
        return .{
            .r = @intCast((i / 36) * 51),
            .g = @intCast(((i / 6) % 6) * 51),
            .b = @intCast((i % 6) * 51),
            .a = 255,
        };
    }
    const gray: u8 = @intCast((@as(u32, idx) - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray, .a = 255 };
}

fn mapCursorShape(shape: frame_state.CursorShape) render_batch.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

test "retained frame updates only dirty spans" {
    const allocator = std.testing.allocator;
    var retained = RetainedFrame{};
    defer retained.deinit(allocator);

    var cells = [_]frame_state.Cell{.{ .codepoint = 'A' }, .{ .codepoint = 'B' }, .{ .codepoint = 'C' }, .{ .codepoint = 'D' }};
    var dirty_rows = [_]bool{ true, true };
    var starts = [_]u16{ 0, 0 };
    var ends = [_]u16{ 1, 1 };
    var batch = try retained.prepareBatch(allocator, allocator, .{
        .viewport = .{ .cols = 2, .rows = 2 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .visible = false },
        .damage = .{ .full = true, .dirty_rows = &dirty_rows, .dirty_cols_start = &starts, .dirty_cols_end = &ends },
    }, .{ .width = 16, .height = 32 }, .{ .width = 8, .height = 16 }, vt_state.default_theme, .{ .max_atlas_slots = 4, .supports_fill_rect = true, .supports_glyph_quads = true });
    batch.deinit();

    cells[0].codepoint = 'Z';
    cells[3].codepoint = 'Y';
    dirty_rows = .{ false, true };
    starts = .{ 0, 1 };
    ends = .{ 0, 1 };
    batch = try retained.prepareBatch(allocator, allocator, .{
        .viewport = .{ .cols = 2, .rows = 2 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .visible = false },
        .damage = .{ .full = false, .dirty_rows = &dirty_rows, .dirty_cols_start = &starts, .dirty_cols_end = &ends },
    }, .{ .width = 16, .height = 32 }, .{ .width = 8, .height = 16 }, vt_state.default_theme, .{ .max_atlas_slots = 4, .supports_fill_rect = true, .supports_glyph_quads = true });
    batch.deinit();

    try std.testing.expectEqual(@as(u21, 'A'), retained.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), retained.cells.items[3].codepoint);
}

test "retained frame reuses retained rows on scroll up" {
    const allocator = std.testing.allocator;
    var retained = RetainedFrame{};
    defer retained.deinit(allocator);

    var cells = [_]frame_state.Cell{
        .{ .codepoint = 'A' }, .{ .codepoint = 'B' },
        .{ .codepoint = 'C' }, .{ .codepoint = 'D' },
        .{ .codepoint = 'E' }, .{ .codepoint = 'F' },
    };
    var dirty_rows = [_]bool{ true, true, true };
    var starts = [_]u16{ 0, 0, 0 };
    var ends = [_]u16{ 1, 1, 1 };
    var batch = try retained.prepareBatch(allocator, allocator, .{
        .viewport = .{ .cols = 2, .rows = 3 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 3 },
        .cursor = .{ .visible = false },
        .damage = .{ .full = true, .dirty_rows = &dirty_rows, .dirty_cols_start = &starts, .dirty_cols_end = &ends },
    }, .{ .width = 16, .height = 48 }, .{ .width = 8, .height = 16 }, vt_state.default_theme, .{ .max_atlas_slots = 4, .supports_fill_rect = true, .supports_glyph_quads = true });
    batch.deinit();

    cells = .{
        .{ .codepoint = 'C' }, .{ .codepoint = 'D' },
        .{ .codepoint = 'E' }, .{ .codepoint = 'F' },
        .{ .codepoint = 'G' }, .{ .codepoint = 'H' },
    };
    batch = try retained.prepareBatch(allocator, allocator, .{
        .viewport = .{ .cols = 2, .rows = 3 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 3 },
        .cursor = .{ .visible = false },
        .damage = .{ .full = false, .scroll_up_rows = 1, .dirty_rows = &dirty_rows, .dirty_cols_start = &starts, .dirty_cols_end = &ends },
    }, .{ .width = 16, .height = 48 }, .{ .width = 8, .height = 16 }, vt_state.default_theme, .{ .max_atlas_slots = 4, .supports_fill_rect = true, .supports_glyph_quads = true });
    defer batch.deinit();

    try std.testing.expect(!batch.batch.full_redraw);
    try std.testing.expectEqual(@as(u16, 1), batch.batch.scroll_up_rows);
    try std.testing.expectEqual(@as(u21, 'C'), retained.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), retained.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), retained.cells.items[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), retained.cells.items[3].codepoint);
    try std.testing.expectEqual(@as(u21, 'G'), retained.cells.items[4].codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), retained.cells.items[5].codepoint);
}

fn shiftRowCacheY(row_cache: *RetainedFrame.RowCache, delta_y: i32) void {
    for (row_cache.fills.items) |*fill| fill.y += delta_y;
    for (row_cache.glyphs.items) |*glyph| glyph.y += delta_y;
}

fn sameColor(a: render_batch.Rgba8, b: render_batch.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn appendBackgroundSpans(
    fills: *std.ArrayListUnmanaged(render_batch.FillRect),
    allocator: std.mem.Allocator,
    cells: []const render_batch.CellInput,
    cols: u16,
    row: usize,
    col_start: usize,
    col_end_exclusive: usize,
    cell_px: render_batch.CellSize,
) !void {
    var span_start = col_start;
    while (span_start < col_end_exclusive) {
        const first_idx = row * @as(usize, cols) + span_start;
        if (first_idx >= cells.len) break;
        const bg = cells[first_idx].bg;
        var span_end = span_start + 1;
        while (span_end < col_end_exclusive) : (span_end += 1) {
            const idx = row * @as(usize, cols) + span_end;
            if (idx >= cells.len or !sameColor(cells[idx].bg, bg)) break;
        }
        try fills.append(allocator, .{
            .x = @intCast(span_start * @as(usize, cell_px.width)),
            .y = @intCast(row * @as(usize, cell_px.height)),
            .width = @intCast((span_end - span_start) * @as(usize, cell_px.width)),
            .height = cell_px.height,
            .color = bg,
        });
        span_start = span_end;
    }
}

fn tryAppendProceduralGlyph(
    fills: *std.ArrayListUnmanaged(render_batch.FillRect),
    allocator: std.mem.Allocator,
    cell: render_batch.CellInput,
    codepoint: u21,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
) !bool {
    if (codepoint < 0x2500 or codepoint > 0x259F) return false;
    const th_h: u16 = @max(1, cell_h / 8);
    const th_v: u16 = @max(1, cell_w / 8);
    switch (codepoint) {
        0x2500 => { try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); return true; },
        0x2502 => { try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x250C => { try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2510 => { try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2514 => { try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2518 => { try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x251C => { try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2524 => { try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x252C => { try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2534 => { try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x253C => { try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg); try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg); return true; },
        0x2580 => { try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = cell_w, .height = @max(1, cell_h / 2), .color = cell.fg }); return true; },
        0x2584 => { const hh: u16 = @max(1, cell_h / 2); try fills.append(allocator, .{ .x = cell_x, .y = cell_y + @as(i32, @intCast(cell_h - hh)), .width = cell_w, .height = hh, .color = cell.fg }); return true; },
        0x2588 => { try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = cell_w, .height = cell_h, .color = cell.fg }); return true; },
        0x258C => { try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = @max(1, cell_w / 2), .height = cell_h, .color = cell.fg }); return true; },
        0x2590 => { const hw: u16 = @max(1, cell_w / 2); try fills.append(allocator, .{ .x = cell_x + @as(i32, @intCast(cell_w - hw)), .y = cell_y, .width = hw, .height = cell_h, .color = cell.fg }); return true; },
        else => return false,
    }
}

fn appendH(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const yy = y + @as(i32, @intCast((h - t) / 2)); try fills.append(allocator, .{ .x = x, .y = yy, .width = w, .height = t, .color = color }); }
fn appendHLeft(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const yy = y + @as(i32, @intCast((h - t) / 2)); const ww = @max(@divFloor(w + t, 2), 1); try fills.append(allocator, .{ .x = x, .y = yy, .width = ww, .height = t, .color = color }); }
fn appendHRight(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const yy = y + @as(i32, @intCast((h - t) / 2)); const xx = x + @as(i32, @intCast((w - t) / 2)); const ww = w - @as(u16, @intCast((w - t) / 2)); try fills.append(allocator, .{ .x = xx, .y = yy, .width = ww, .height = t, .color = color }); }
fn appendV(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const xx = x + @as(i32, @intCast((w - t) / 2)); try fills.append(allocator, .{ .x = xx, .y = y, .width = t, .height = h, .color = color }); }
fn appendVTop(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const xx = x + @as(i32, @intCast((w - t) / 2)); const hh = @max(@divFloor(h + t, 2), 1); try fills.append(allocator, .{ .x = xx, .y = y, .width = t, .height = hh, .color = color }); }
fn appendVBottom(fills: *std.ArrayListUnmanaged(render_batch.FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: render_batch.Rgba8) !void { const xx = x + @as(i32, @intCast((w - t) / 2)); const yy = y + @as(i32, @intCast((h - t) / 2)); const hh = h - @as(u16, @intCast((h - t) / 2)); try fills.append(allocator, .{ .x = xx, .y = yy, .width = t, .height = hh, .color = color }); }
