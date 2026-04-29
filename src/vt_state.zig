//! Responsibility: convert terminal-like frame snapshots into render-core batches.
//! Ownership: shared frame pipeline used by renderer implementations.
//! Reason: remove duplicated frame-mapping logic across render backends.

const std = @import("std");
const types = @import("types.zig");
const render_batch = @import("render_batch.zig");

pub const FrameTheme = types.FrameTheme;
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

fn mapCursorShape(shape: anytype) types.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

pub fn vtStateToRenderBatch(
    allocator: std.mem.Allocator,
    frame: anytype,
    surface_px: types.PixelSize,
    cell_px: types.CellSize,
    capability: types.BackendCapability,
) !types.OwnedRenderBatch {
    return vtStateToRenderBatchWithTheme(
        allocator,
        frame,
        surface_px,
        cell_px,
        default_theme,
        capability,
    );
}

pub fn vtStateToRenderBatchWithTheme(
    allocator: std.mem.Allocator,
    frame: anytype,
    surface_px: types.PixelSize,
    cell_px: types.CellSize,
    t: FrameTheme,
    capability: types.BackendCapability,
) !types.OwnedRenderBatch {
    const cell_inputs = try allocator.alloc(types.CellInput, frame.grid.cells.len);
    defer allocator.free(cell_inputs);

    for (frame.grid.cells, cell_inputs) |src, *dst| {
        dst.* = .{
            .codepoint = src.codepoint,
            .fg = colorToRgba8(src.fg_color, true, t),
            .bg = colorToRgba8(src.bg_color, false, t),
            .continuation = src.flags.continuation,
        };
    }

    const cursor_input: ?types.CursorInput = if (frame.cursor.visible) .{
        .col = frame.cursor.col,
        .row = frame.cursor.row,
        .shape = mapCursorShape(frame.cursor.shape),
        .color = t.cursor_color,
    } else null;

    return render_batch.renderBatch(allocator, .{
        .surface_px = surface_px,
        .cell_px = cell_px,
        .grid = .{ .cells = cell_inputs, .cols = frame.grid.cols, .rows = frame.grid.rows },
        .cursor = cursor_input,
    }, capability);
}
