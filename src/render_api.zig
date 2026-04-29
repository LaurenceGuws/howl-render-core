//! Responsibility: map surface frame data into render-core planning api input.
//! Ownership: composition api between terminal surface state and renderer planning.
//! Reason: keep render-core backend-neutral and host code minimal.

const std = @import("std");
const terminal_surface = @import("terminal_surface.zig");
const render_core = @import("howl_render_core");

/// Palette values and cursor color used while planning renders.
pub const FrameTheme = render_core.FrameTheme;
/// Default palette tuned for the minimum viable presentation.
pub const linux_mvp_theme = render_core.linux_mvp_theme;
/// Surface pixel dimensions provided to render planning.
pub const RenderPixelSize = render_core.PixelSize;
/// Cell pixel dimensions provided to render planning.
pub const RenderCellSize = render_core.CellSize;
/// Renderer feature limits that shape plan generation.
pub const RenderBackendCapability = render_core.BackendCapability;
/// Render plan plus owned upload buffers.
pub const OwnedRenderPlan = render_core.OwnedPlan;

fn indexed256(idx: u8, theme: FrameTheme) render_core.Rgba8 {
    if (idx < 16) return theme.ansi16[idx];
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

fn colorToRgba8(color: terminal_surface.Color, is_fg: bool, theme: FrameTheme) render_core.Rgba8 {
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

fn mapCursorShape(shape: terminal_surface.CursorShape) render_core.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

/// Build a render plan from frame data using the default theme.
pub fn buildRenderPlanFromFrame(
    allocator: std.mem.Allocator,
    frame: terminal_surface.FrameData,
    surface_px: RenderPixelSize,
    cell_px: RenderCellSize,
    capability: RenderBackendCapability,
) !OwnedRenderPlan {
    return buildRenderPlanFromFrameWithTheme(
        allocator,
        frame,
        surface_px,
        cell_px,
        linux_mvp_theme,
        capability,
    );
}

/// Build a render plan from frame data using a caller-supplied theme.
pub fn buildRenderPlanFromFrameWithTheme(
    allocator: std.mem.Allocator,
    frame: terminal_surface.FrameData,
    surface_px: RenderPixelSize,
    cell_px: RenderCellSize,
    theme: FrameTheme,
    capability: RenderBackendCapability,
) !OwnedRenderPlan {
    const cell_inputs = try allocator.alloc(render_core.CellInput, frame.grid.cells.len);
    defer allocator.free(cell_inputs);

    for (frame.grid.cells, cell_inputs) |src, *dst| {
        dst.* = .{
            .codepoint = src.codepoint,
            .fg = colorToRgba8(src.fg_color, true, theme),
            .bg = colorToRgba8(src.bg_color, false, theme),
            .continuation = src.flags.continuation,
        };
    }

    const cursor_input: ?render_core.CursorInput = if (frame.cursor.visible) .{
        .col = frame.cursor.col,
        .row = frame.cursor.row,
        .shape = mapCursorShape(frame.cursor.shape),
        .color = theme.cursor_color,
    } else null;

    return render_core.buildPlan(allocator, .{
        .surface_px = surface_px,
        .cell_px = cell_px,
        .grid = .{ .cells = cell_inputs, .cols = frame.grid.cols, .rows = frame.grid.rows },
        .cursor = cursor_input,
    }, capability);
}

fn makeFrameCell(cp: u21, fg_kind: anytype, fg_val: u24, bg_kind: anytype, bg_val: u24) terminal_surface.Cell {
    return .{
        .codepoint = cp,
        .flags = .{},
        .fg_color = .{ .kind = fg_kind, .value = fg_val },
        .bg_color = .{ .kind = bg_kind, .value = bg_val },
        .attrs = .{},
    };
}

fn testCapability(max_slots: u32) render_core.BackendCapability {
    return .{
        .max_atlas_slots = max_slots,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
}

test "api: default-color cells map to default fill color" {
    const cells = [_]terminal_surface.Cell{makeFrameCell(0, .default, 0, .default, 0)};
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildRenderPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.plan.fills.len);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.g, owned.plan.fills[0].color.g);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.b, owned.plan.fills[0].color.b);
}

test "api: rgb color cells map to exact rgb values" {
    const cells = [_]terminal_surface.Cell{makeFrameCell('A', .rgb, 0xFF8000, .rgb, 0x001020)};
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildRenderPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(u8, 0x00), owned.plan.fills[0].color.r);
    try std.testing.expectEqual(@as(u8, 0x10), owned.plan.fills[0].color.g);
    try std.testing.expectEqual(@as(u8, 0x20), owned.plan.fills[0].color.b);
    try std.testing.expectEqual(@as(u8, 0xFF), owned.plan.glyphs[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0x80), owned.plan.glyphs[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0x00), owned.plan.glyphs[0].fg.b);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.glyphs[0].x);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.glyphs[0].y);
    try std.testing.expectEqual(@as(u21, 'A'), owned.plan.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(usize, 1), owned.plan.atlas_uploads.len);
    try std.testing.expectEqual(@as(u21, 'A'), owned.plan.atlas_uploads[0].codepoint);
}

test "api: cursor visible maps to cursor draw at correct position" {
    const cells = [_]terminal_surface.Cell{
        makeFrameCell(0, .default, 0, .default, 0),
        makeFrameCell(0, .default, 0, .default, 0),
    };
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 2, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .underline },
    };
    var owned = try buildRenderPlanFromFrame(std.testing.allocator, frame, .{ .width = 16, .height = 16 }, .{ .width = 8, .height = 16 }, testCapability(4));
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor != null);
    try std.testing.expectEqual(@as(u16, 1), owned.plan.cursor.?.cell_col);
    try std.testing.expectEqual(@as(u16, 0), owned.plan.cursor.?.cell_row);
    try std.testing.expectEqual(render_core.CursorShape.underline, owned.plan.cursor.?.shape);
}

test "api: cursor hidden maps to null cursor draw" {
    const cells = [_]terminal_surface.Cell{makeFrameCell(0, .default, 0, .default, 0)};
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildRenderPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, testCapability(4));
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor == null);
}

test "api: ansi16 indexed color maps to palette entry" {
    const cells = [_]terminal_surface.Cell{makeFrameCell(0, .default, 0, .indexed, 1)};
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildRenderPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].g, owned.plan.fills[0].color.g);
    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].b, owned.plan.fills[0].color.b);
}

test "indexed256: ansi range 0-15 matches palette" {
    for (0..16) |i| {
        const got = indexed256(@intCast(i), linux_mvp_theme);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].r, got.r);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].g, got.g);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].b, got.b);
    }
}

test "indexed256: color cube and grayscale map correctly" {
    const black = indexed256(16, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    const white = indexed256(231, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);

    const gray = indexed256(255, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 238), gray.r);
    try std.testing.expectEqual(@as(u8, 238), gray.g);
    try std.testing.expectEqual(@as(u8, 238), gray.b);
}

test "api: explicit theme overrides default and cursor colors" {
    const custom_theme = FrameTheme{
        .default_fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .default_bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
        .cursor_color = .{ .r = 7, .g = 8, .b = 9, .a = 255 },
        .ansi16 = linux_mvp_theme.ansi16,
    };
    const cells = [_]terminal_surface.Cell{makeFrameCell('A', .default, 0, .default, 0)};
    const frame = terminal_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = true, .shape = .block },
    };
    var owned = try buildRenderPlanFromFrameWithTheme(
        std.testing.allocator,
        frame,
        .{ .width = 8, .height = 16 },
        .{ .width = 8, .height = 16 },
        custom_theme,
        testCapability(4),
    );
    defer owned.deinit();

    try std.testing.expectEqual(custom_theme.default_bg.r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(custom_theme.default_fg.g, owned.plan.glyphs[0].fg.g);
    try std.testing.expectEqual(custom_theme.cursor_color.b, owned.plan.cursor.?.color.b);
    try std.testing.expectEqual(@as(u21, 'A'), owned.plan.glyphs[0].codepoint);
}
