//! Responsibility: convert terminal-like frame snapshots into render-core batches.
//! Ownership: shared frame pipeline used by renderer implementations.
//! Reason: remove duplicated frame-mapping logic across render backends.

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

    for (state.grid.cells, cell_inputs) |src, *dst| {
        dst.* = .{
            .codepoint = src.codepoint,
            .fg = colorToTextSceneRgba8(src.fg_color, true, t),
            .bg = colorToTextSceneRgba8(src.bg_color, false, t),
            .underline_color = if (src.attrs.underline_color_set) colorToTextSceneRgba8(src.underline_color, true, t) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .underline_style = mapUnderlineStyle(src.underline_style),
            .underline = src.attrs.underline,
            .strikethrough = src.attrs.strikethrough,
            .continuation = src.flags.continuation,
        };
    }

    const cursor: ?text_scene.CursorInput = if (state.cursor.visible) .{
        .cell_col = state.cursor.col,
        .cell_row = state.cursor.row,
        .shape = mapTextSceneCursorShape(state.cursor.shape),
        .color = t.cursor_color,
    } else null;

    return .{
        .allocator = allocator,
        .cells = cell_inputs,
        .grid = .{ .cols = state.grid.cols, .rows = state.grid.rows },
        .options = .{ .scene = .{
            .cursor = cursor,
            .damage = .{
                .full = state.damage.full,
                .scroll_up_rows = damageScrollUpRows(state.damage),
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
    try std.testing.expect(input.options.scene.cursor != null);
    try std.testing.expect(input.options.scene.damage.full);
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
