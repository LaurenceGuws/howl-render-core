
const std = @import("std");
const surface = @import("surface.zig");
const types = @import("types.zig");
const text_engine = @import("text/engine.zig");
const text_scene = @import("text/scene.zig");

pub const FrameTheme = struct {
    default_fg: types.Rgba8,
    default_bg: types.Rgba8,
    cursor_color: types.Rgba8,
    ansi16: [16]types.Rgba8,
};
pub const default_theme = FrameTheme{
    .default_fg = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .default_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .cursor_color = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .ansi16 = .{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 170, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 170, .b = 0, .a = 255 },
        .{ .r = 170, .g = 85, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 170, .a = 255 },
        .{ .r = 170, .g = 0, .b = 170, .a = 255 },
        .{ .r = 0, .g = 170, .b = 170, .a = 255 },
        .{ .r = 170, .g = 170, .b = 170, .a = 255 },
        .{ .r = 85, .g = 85, .b = 85, .a = 255 },
        .{ .r = 255, .g = 85, .b = 85, .a = 255 },
        .{ .r = 85, .g = 255, .b = 85, .a = 255 },
        .{ .r = 255, .g = 255, .b = 85, .a = 255 },
        .{ .r = 85, .g = 85, .b = 255, .a = 255 },
        .{ .r = 255, .g = 85, .b = 255, .a = 255 },
        .{ .r = 85, .g = 255, .b = 255, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    },
};

fn indexed256(idx: u8, t: FrameTheme) types.Rgba8 {
    if (idx < 16) return t.ansi16[idx];
    if (idx < 232) {
        const i: u32 = idx - 16;
        const r: u8 = @intCast((i / 36) * 51);
        const g: u8 = @intCast(((i / 6) % 6) * 51);
        const b: u8 = @intCast((i % 6) * 51);
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    const gray: u8 = @intCast((@as(u32, idx) - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray, .a = 255 };
}

fn colorToRgba8(color: anytype, is_fg: bool, t: FrameTheme) types.Rgba8 {
    return switch (color.kind) {
        .default => if (is_fg) t.default_fg else t.default_bg,
        .indexed => indexed256(@intCast(color.value & 0xFF), t),
        .rgb => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
    };
}

fn colorToTextSceneRgba8(color: anytype, is_fg: bool, t: FrameTheme) types.Rgba8 {
    if (!is_fg and color.kind == .default) return .{ .r = t.default_bg.r, .g = t.default_bg.g, .b = t.default_bg.b, .a = 0 };
    return colorToRgba8(color, is_fg, t);
}

fn mapCursorShape(shape: anytype) text_scene.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

fn mapTextSceneCursorShape(shape: anytype) text_scene.CursorShape {
    const name = @tagName(shape);
    if (std.mem.eql(u8, name, "underline")) return .underline;
    if (std.mem.eql(u8, name, "beam")) return .beam;
    if (std.mem.eql(u8, name, "hollow_block")) return .hollow_block;
    return .block;
}

fn mapUnderlineStyle(style: surface.UnderlineStyle) types.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

fn damageScrollUpRows(damage: anytype) u16 {
    return if (@hasField(@TypeOf(damage), "scroll_up_rows")) damage.scroll_up_rows else 0;
}

fn isAlacrittyEmptyCell(cell: surface.Cell) bool {
    const blank = cell.codepoint == ' ' or cell.codepoint == '\t';
    const default_colors = cell.bg_color.kind == .default and cell.fg_color.kind == .default;
    const visible_flags = cell.flags.continuation or
        cell.attrs.inverse or
        cell.attrs.underline or
        cell.attrs.strikethrough;
    return blank and default_colors and !visible_flags;
}

fn emptyCellInput() types.CellInput {
    return .{
        .codepoint = 0,
        .fg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .empty = true,
    };
}

fn mapCellInput(src: surface.Cell, t: FrameTheme) types.CellInput {
    return .{
        .codepoint = src.codepoint,
        .fg = colorToTextSceneRgba8(src.fg_color, true, t),
        .bg = colorToTextSceneRgba8(src.bg_color, false, t),
        .underline_color = if (src.attrs.underline_color_set) colorToTextSceneRgba8(src.underline_color, true, t) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = mapUnderlineStyle(src.underline_style),
        .underline = src.attrs.underline,
        .strikethrough = src.attrs.strikethrough,
        .continuation = src.flags.continuation,
        .empty = isAlacrittyEmptyCell(src),
    };
}

fn canMapDirtyOnly(state: anytype) bool {
    const rows = @as(usize, state.grid.rows);
    return !state.damage.full and
        state.damage.dirty_rows.len == rows and
        state.damage.dirty_cols_start.len == rows and
        state.damage.dirty_cols_end.len == rows;
}

fn mapDirtyCellsOnly(
    dst: []types.CellInput,
    cells: []const surface.Cell,
    grid_cols: u16,
    grid_rows: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    t: FrameTheme,
) void {
    const cols: usize = @max(@as(usize, grid_cols), 1);
    const rows = @as(usize, grid_rows);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        if (!dirty_rows[row]) continue;
        const base = row * cols;
        if (base >= cells.len) continue;
        const start_col = @min(@as(usize, dirty_cols_start[row]), cols - 1);
        const end_col = @min(@as(usize, dirty_cols_end[row]), cols - 1);
        if (end_col < start_col) continue;
        var idx = base + start_col;
        const end_idx = @min(base + end_col + 1, cells.len);
        while (idx < end_idx) : (idx += 1) {
            dst[idx] = mapCellInput(cells[idx], t);
        }
    }
}

pub const OwnedFrameTextInput = struct {
    allocator: std.mem.Allocator,
    cells: []types.CellInput,
    grid: @import("text_contract.zig").GridMetrics,
    options: text_engine.AnalysisOptions,

    pub fn deinit(self: *OwnedFrameTextInput) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedTextSceneInput = OwnedFrameTextInput;

pub fn vtStateToTextSceneInput(
    allocator: std.mem.Allocator,
    state: anytype,
) !OwnedTextSceneInput {
    return vtStateToTextSceneInputWithTheme(allocator, state, default_theme);
}

pub fn vtStateToFrameTextInput(
    allocator: std.mem.Allocator,
    state: anytype,
) !OwnedFrameTextInput {
    return vtStateToFrameTextInputWithTheme(allocator, state, default_theme);
}

pub fn vtStateToTextSceneInputWithTheme(
    allocator: std.mem.Allocator,
    state: anytype,
    t: FrameTheme,
) !OwnedTextSceneInput {
    return vtStateToFrameTextInputWithTheme(allocator, state, t);
}

pub fn vtStateToFrameTextInputWithTheme(
    allocator: std.mem.Allocator,
    state: anytype,
    t: FrameTheme,
) !OwnedFrameTextInput {
    const cell_inputs = try allocator.alloc(types.CellInput, state.grid.cells.len);
    errdefer allocator.free(cell_inputs);

    if (canMapDirtyOnly(state)) {
        @memset(cell_inputs, emptyCellInput());
        mapDirtyCellsOnly(
            cell_inputs,
            state.grid.cells,
            state.grid.cols,
            state.grid.rows,
            state.damage.dirty_rows,
            state.damage.dirty_cols_start,
            state.damage.dirty_cols_end,
            t,
        );
    } else {
        for (state.grid.cells, cell_inputs) |src, *dst| {
            dst.* = mapCellInput(src, t);
        }
    }

    const cursor: ?text_scene.CursorInput = if (state.cursor.visible) .{
        .cell_col = state.cursor.col,
        .cell_row = state.cursor.row,
        .shape = mapTextSceneCursorShape(state.cursor.shape),
        .color = t.cursor_color,
    } else null;

    const scroll_up_rows = damageScrollUpRows(state.damage);
    return .{
        .allocator = allocator,
        .cells = cell_inputs,
        .grid = .{ .cols = state.grid.cols, .rows = state.grid.rows },
        .options = .{ .scene = .{
            .cursor = cursor,
            .damage = .{
                .full = state.damage.full,
                .scroll_up_rows = scroll_up_rows,
                .dirty_rows = state.damage.dirty_rows,
                .dirty_cols_start = state.damage.dirty_cols_start,
                .dirty_cols_end = state.damage.dirty_cols_end,
            },
        } },
    };
}

test "frame_input converts frame state to text scene input" {
    const cells = [_]surface.Cell{.{
        .codepoint = 'A',
        .underline_color = .{ .kind = .rgb, .value = 0xCC3366 },
        .attrs = .{ .underline = true, .underline_color_set = true },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = .beam },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expectEqual(@as(usize, 1), input.cells.len);
    try std.testing.expectEqual(@as(u21, 'A'), input.cells[0].codepoint);
    try std.testing.expect(input.cells[0].underline);
    try std.testing.expectEqual(@as(u8, 0xCC), input.cells[0].underline_color.r);
    try std.testing.expectEqual(@as(u8, 0), input.cells[0].bg.a);
    try std.testing.expect(!input.cells[0].empty);
    try std.testing.expect(input.options.scene.cursor != null);
    try std.testing.expect(input.options.scene.damage.full);
}

test "frame_input marks Alacritty-empty cells before color mapping" {
    const cells = [_]surface.Cell{
        .{},
        .{ .codepoint = '\t' },
        .{ .codepoint = ' ', .bg_color = .{ .kind = .rgb, .value = 0 } },
        .{ .codepoint = ' ', .attrs = .{ .underline = true } },
        .{ .codepoint = ' ', .flags = .{ .continuation = true } },
    };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 5, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };

    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expect(input.cells[0].empty);
    try std.testing.expect(input.cells[1].empty);
    try std.testing.expect(!input.cells[2].empty);
    try std.testing.expect(!input.cells[3].empty);
    try std.testing.expect(!input.cells[4].empty);
}

test "frame_input threads partial damage into text scene input" {
    const cells = [_]surface.Cell{ .{}, .{} };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 2 };
    const dirty_ends = [_]u16{ 0, 5 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 6, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{
            .full = false,
            .scroll_up_rows = 1,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expect(!input.options.scene.damage.full);
    try std.testing.expectEqual(@as(u16, 1), input.options.scene.damage.scroll_up_rows);
    try std.testing.expectEqual(@as(usize, 2), input.options.scene.damage.dirty_rows.len);
    try std.testing.expectEqual(@as(u16, 2), input.options.scene.damage.dirty_cols_start[1]);
}

test "frame_input maps only dirty ranges for partial damage" {
    const cells = [_]surface.Cell{
        .{ .codepoint = 'A' },
        .{ .codepoint = 'B' },
        .{ .codepoint = 'C' },
        .{ .codepoint = 'D' },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 1 };
    const dirty_ends = [_]u16{ 0, 1 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{
            .full = false,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expect(input.cells[0].empty);
    try std.testing.expect(input.cells[1].empty);
    try std.testing.expect(input.cells[2].empty);
    try std.testing.expectEqual(@as(u21, 'D'), input.cells[3].codepoint);
    try std.testing.expect(!input.cells[3].empty);
}
