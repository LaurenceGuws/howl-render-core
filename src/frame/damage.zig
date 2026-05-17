const std = @import("std");

pub fn buildSurfaceRects(
    comptime PixelSize: type,
    comptime CellSize: type,
    comptime GridMetrics: type,
    comptime Rect: type,
    allocator: std.mem.Allocator,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridMetrics,
    damage: anytype,
    scroll_up_px: u16,
    full_redraw: bool,
) ![]Rect {
    if (render_px.width == 0 or render_px.height == 0) return &.{};
    if (full_redraw or damage.full or scroll_up_px > 0) return fullRect(Rect, allocator, render_px);
    return buildDirtyRowRects(CellSize, GridMetrics, Rect, allocator, cell_px, grid, damage);
}

pub fn buildBufferRects(
    comptime PixelSize: type,
    comptime CellSize: type,
    comptime GridMetrics: type,
    comptime Rect: type,
    allocator: std.mem.Allocator,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridMetrics,
    damage: anytype,
    scroll_up_px: u16,
    full_redraw: bool,
) ![]Rect {
    if (render_px.width == 0 or render_px.height == 0) return &.{};
    if (full_redraw or damage.full) return fullRect(Rect, allocator, render_px);
    if (scroll_up_px > 0) return buildScrollAndDirtyRects(PixelSize, CellSize, GridMetrics, Rect, allocator, render_px, cell_px, grid, damage, scroll_up_px);
    return buildDirtyRowRects(CellSize, GridMetrics, Rect, allocator, cell_px, grid, damage);
}

fn fullRect(comptime Rect: type, allocator: std.mem.Allocator, render_px: anytype) ![]Rect {
    const out = try allocator.alloc(Rect, 1);
    out[0] = .{ .x = 0, .y = 0, .width = render_px.width, .height = render_px.height };
    return out;
}

fn buildScrollAndDirtyRects(
    comptime PixelSize: type,
    comptime CellSize: type,
    comptime GridMetrics: type,
    comptime Rect: type,
    allocator: std.mem.Allocator,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridMetrics,
    damage: anytype,
    scroll_up_px: u16,
) ![]Rect {
    var rects = std.ArrayList(Rect).empty;
    errdefer rects.deinit(allocator);
    try rects.append(allocator, .{
        .x = 0,
        .y = render_px.height - scroll_up_px,
        .width = render_px.width,
        .height = scroll_up_px,
    });
    const dirty = try buildDirtyRowRects(CellSize, GridMetrics, Rect, allocator, cell_px, grid, damage);
    defer if (dirty.len > 0) allocator.free(dirty);
    try rects.appendSlice(allocator, dirty);
    return try rects.toOwnedSlice(allocator);
}

fn buildDirtyRowRects(
    comptime CellSize: type,
    comptime GridMetrics: type,
    comptime Rect: type,
    allocator: std.mem.Allocator,
    cell_px: CellSize,
    grid: GridMetrics,
    damage: anytype,
) ![]Rect {
    const rows = @as(usize, grid.rows);
    if (rows == 0) return &.{};
    if (damage.dirty_rows.len != rows) return &.{};
    if (damage.dirty_cols_start.len != rows) return &.{};
    if (damage.dirty_cols_end.len != rows) return &.{};

    var rects = std.ArrayList(Rect).empty;
    errdefer rects.deinit(allocator);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        if (!damage.dirty_rows[row]) continue;
        const start_col = @min(damage.dirty_cols_start[row], grid.cols -| 1);
        const end_col = @min(damage.dirty_cols_end[row], grid.cols -| 1);
        if (end_col < start_col) continue;
        try rects.append(allocator, .{
            .x = @as(i32, start_col) * @as(i32, cell_px.width),
            .y = @as(i32, @intCast(row)) * @as(i32, cell_px.height),
            .width = (@as(i32, end_col) - @as(i32, start_col) + 1) * @as(i32, cell_px.width),
            .height = @as(i32, cell_px.height),
        });
    }
    if (rects.items.len == 0) return &.{};
    return try rects.toOwnedSlice(allocator);
}
