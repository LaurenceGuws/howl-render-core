//! Responsibility: convert terminal-like frame snapshots into render-core batches.
//! Ownership: shared frame pipeline used by renderer implementations.
//! Reason: remove duplicated frame-mapping logic across render backends.

const std = @import("std");
const frame_state = @import("frame_state.zig");
const render_batch = @import("render_batch.zig");
const text_engine = @import("text_stack/engine.zig");
const text_scene = @import("text_stack/scene.zig");

pub const FrameTheme = struct {
    default_fg: render_batch.Rgba8,
    default_bg: render_batch.Rgba8,
    cursor_color: render_batch.Rgba8,
    ansi16: [16]render_batch.Rgba8,
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

fn indexed256(idx: u8, t: FrameTheme) render_batch.Rgba8 {
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

fn colorToRgba8(color: anytype, is_fg: bool, t: FrameTheme) render_batch.Rgba8 {
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

fn colorToTextSceneRgba8(color: anytype, is_fg: bool, t: FrameTheme) render_batch.Rgba8 {
    if (!is_fg and color.kind == .default) return .{ .r = t.default_bg.r, .g = t.default_bg.g, .b = t.default_bg.b, .a = 0 };
    return colorToRgba8(color, is_fg, t);
}

fn mapCursorShape(shape: anytype) render_batch.CursorShape {
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

fn mapUnderlineStyle(style: frame_state.UnderlineStyle) render_batch.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

pub const OwnedTextSceneInput = struct {
    allocator: std.mem.Allocator,
    cells: []render_batch.CellInput,
    grid: @import("text_contract.zig").GridMetrics,
    options: text_engine.AnalysisOptions,

    pub fn deinit(self: *OwnedTextSceneInput) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub fn vtStateToRenderBatch(
    allocator: std.mem.Allocator,
    state: anytype,
    surface_px: render_batch.PixelSize,
    cell_px: render_batch.CellSize,
    capability: render_batch.BackendCapability,
) render_batch.RenderBatchBuildError!render_batch.OwnedRenderBatch {
    return vtStateToRenderBatchWithTheme(
        allocator,
        state,
        surface_px,
        cell_px,
        default_theme,
        capability,
    );
}

pub fn vtStateToRenderBatchWithTheme(
    allocator: std.mem.Allocator,
    state: anytype,
    surface_px: render_batch.PixelSize,
    cell_px: render_batch.CellSize,
    t: FrameTheme,
    capability: render_batch.BackendCapability,
) render_batch.RenderBatchBuildError!render_batch.OwnedRenderBatch {
    const cell_inputs = try allocator.alloc(render_batch.CellInput, state.grid.cells.len);
    defer allocator.free(cell_inputs);

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

    const cursor_input: ?render_batch.CursorInput = if (state.cursor.visible) .{
        .col = state.cursor.col,
        .row = state.cursor.row,
        .shape = mapCursorShape(state.cursor.shape),
        .color = t.cursor_color,
    } else null;

    return render_batch.renderBatch(allocator, .{
        .surface_px = surface_px,
        .cell_px = cell_px,
        .grid = .{ .cells = cell_inputs, .cols = state.grid.cols, .rows = state.grid.rows },
        .cursor = cursor_input,
        .damage = .{
            .full = state.damage.full,
            .dirty_rows = state.damage.dirty_rows,
            .dirty_cols_start = state.damage.dirty_cols_start,
            .dirty_cols_end = state.damage.dirty_cols_end,
        },
    }, capability);
}

pub fn vtStateToTextSceneInput(
    allocator: std.mem.Allocator,
    state: anytype,
) !OwnedTextSceneInput {
    return vtStateToTextSceneInputWithTheme(allocator, state, default_theme);
}

pub fn vtStateToTextSceneInputWithTheme(
    allocator: std.mem.Allocator,
    state: anytype,
    t: FrameTheme,
) !OwnedTextSceneInput {
    const cell_inputs = try allocator.alloc(render_batch.CellInput, state.grid.cells.len);
    errdefer allocator.free(cell_inputs);

    for (state.grid.cells, cell_inputs) |src, *dst| {
        dst.* = .{
            .codepoint = src.codepoint,
            .fg = colorToRgba8(src.fg_color, true, t),
            .bg = colorToRgba8(src.bg_color, false, t),
            .underline_color = if (src.attrs.underline_color_set) colorToRgba8(src.underline_color, true, t) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
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
        .options = .{ .scene = .{ .cursor = cursor } },
    };
}

test "vt_state preserves underline and strikethrough attrs in batch input" {
    const cells = [_]frame_state.Cell{.{
        .codepoint = 'A',
        .attrs = .{ .underline = true, .strikethrough = true },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var owned = try vtStateToRenderBatch(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, .{ .max_atlas_slots = 4, .supports_fill_rect = true, .supports_glyph_quads = true });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 3), owned.batch.fills.len);
}

test "vt_state converts frame state to text scene input" {
    const cells = [_]frame_state.Cell{.{
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
    try std.testing.expect(input.options.scene.cursor != null);
}
