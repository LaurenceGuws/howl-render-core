//! Responsibility: convert terminal-like frame snapshots into render-core batches.
//! Ownership: shared frame pipeline used by renderer implementations.
//! Reason: remove duplicated frame-mapping logic across render backends.

const std = @import("std");
const render_batch = @import("render_batch.zig");

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

fn mapCursorShape(shape: anytype) render_batch.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

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
            .fg = colorToRgba8(src.fg_color, true, t),
            .bg = colorToRgba8(src.bg_color, false, t),
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
