//! Responsibility: shared font and cell metric policy helpers.
//! Ownership: render-core text engine.
//! Reason: baseline and decoration geometry must not diverge by backend.

const std = @import("std");
const contract = @import("../text_contract.zig");

pub const FaceMetrics26Dot6 = struct {
    ascender: i32,
    descender: i32,
    height: i32,
    max_advance: i32,
    fallback_font_px: u16,
};

pub const DecorationGeometry = struct {
    underline_y_px: i32,
    underline_h_px: u16,
    strikethrough_y_px: i32,
    strikethrough_h_px: u16,
};

pub const CursorGeometry = struct {
    beam_w_px: u16,
    underline_h_px: u16,
    hollow_stroke_px: u16,
};

pub const BitmapPlacement = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
};

pub fn defaultCellMetrics(font_px: u16) contract.CellMetrics {
    const h = @max(font_px, 1);
    return .{
        .cell_w_px = @max(@divFloor(h, 2), 1),
        .cell_h_px = h,
        .baseline_px = @intCast(@max(h - @divFloor(h, 5), 1)),
        .box_thickness_px = defaultBoxThickness(h),
    };
}

pub fn defaultFontMetrics(cell: contract.CellMetrics) contract.FontMetrics {
    const baseline: f32 = @floatFromInt(cell.baseline_px);
    const decoration_thickness: f32 = @floatFromInt(scaledDecorationThickness(cell.cell_h_px));
    return .{
        .ascent_px = baseline,
        .descent_px = @floatFromInt(@as(i32, cell.cell_h_px) - @as(i32, cell.baseline_px)),
        .line_gap_px = 0,
        .underline_pos_px = baseline + decoration_thickness,
        .underline_thickness_px = decoration_thickness,
        .strikethrough_pos_px = baseline / 2.0,
        .strikethrough_thickness_px = decoration_thickness,
    };
}

pub fn defaultBoxThickness(cell_h_px: u16) u16 {
    _ = cell_h_px;
    // Default terminal stroke at scale 1, 96 dpi, and a 1 pt base width.
    return 2;
}

fn scaledDecorationThickness(cell_h_px: u16) u16 {
    return @intCast(@max(@divTrunc(@as(u32, @max(cell_h_px, 1)) + 15, 16), 1));
}

/// Resolves generated box drawing stroke metrics from cell metrics.
pub fn boxDrawingRasterMetrics(cell: contract.CellMetrics) contract.BoxDrawingRasterMetrics {
    const light = if (cell.box_thickness_px == 0) defaultBoxThickness(cell.cell_h_px) else cell.box_thickness_px;
    const doubled = @min(@as(u32, light) * 2, std.math.maxInt(u16));
    const incremented = @min(@as(u32, light) + 1, std.math.maxInt(u16));
    return .{ .light_stroke_px = light, .heavy_stroke_px = @intCast(@max(doubled, incremented)) };
}

pub fn decorationGeometry(cell: contract.CellMetrics, font: contract.FontMetrics) DecorationGeometry {
    const underline_h = clampThickness(font.underline_thickness_px, cell.cell_h_px);
    const strike_h = clampThickness(font.strikethrough_thickness_px, cell.cell_h_px);
    return .{
        .underline_y_px = clampY(@as(i32, @intFromFloat(std.math.round(font.underline_pos_px))), underline_h, cell.cell_h_px),
        .underline_h_px = underline_h,
        .strikethrough_y_px = clampY(@as(i32, @intFromFloat(std.math.round(font.strikethrough_pos_px))), strike_h, cell.cell_h_px),
        .strikethrough_h_px = strike_h,
    };
}

pub fn cursorGeometry(cell: contract.CellMetrics) CursorGeometry {
    return .{
        .beam_w_px = if (cell.cell_w_px >= 2) 2 else 1,
        .underline_h_px = if (cell.cell_h_px >= 2) 2 else 1,
        .hollow_stroke_px = 1,
    };
}

pub fn bitmapPlacement(cell: contract.CellMetrics, face: FaceMetrics26Dot6, bitmap_left: i32, bitmap_top: i32, bitmap_w: u16, bitmap_h: u16) BitmapPlacement {
    _ = face;
    const baseline_y: i32 = cell.baseline_px;
    return .{
        .x_px = bitmap_left,
        .y_px = baseline_y - bitmap_top,
        .width_px = bitmap_w,
        .height_px = bitmap_h,
    };
}

pub fn advancePx(advance_26_6: i32, fallback: u16) f32 {
    if (advance_26_6 <= 0) return @floatFromInt(@max(fallback, 1));
    return @as(f32, @floatFromInt(advance_26_6)) / 64.0;
}

pub fn groupPlacement(glyphs: []const contract.GlyphInstance, cell_metrics: contract.CellMetrics, cell_span: u8) contract.GlyphPlacement {
    const fallback_advance: f32 = @floatFromInt(@as(u32, @max(cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
    if (glyphs.len == 0) return .{ .advance_px = fallback_advance };

    var min_x = glyphs[0].x_offset_px;
    var min_y = glyphs[0].y_offset_px;
    var advance: f32 = 0;
    for (glyphs) |glyph| {
        min_x = @min(min_x, glyph.x_offset_px);
        min_y = @min(min_y, glyph.y_offset_px);
        advance += if (glyph.x_advance_px > 0) glyph.x_advance_px else @as(f32, @floatFromInt(cell_metrics.cell_w_px));
    }
    return .{
        .x_offset_px = min_x,
        .y_offset_px = min_y,
        .advance_px = if (advance > 0) advance else fallback_advance,
    };
}

pub fn cellMetricsFromFaceMetrics(input: FaceMetrics26Dot6) contract.CellMetrics {
    const h = metricCeilPx(input.height, input.fallback_font_px);
    const w = metricCeilPx(input.max_advance, @max(@divFloor(input.fallback_font_px, 2), 1));
    return .{
        .cell_w_px = @max(w, 1),
        .cell_h_px = @max(h, 1),
        .baseline_px = @intCast(baselineFromFaceMetrics(input, h)),
        .box_thickness_px = defaultBoxThickness(h),
    };
}

pub fn cellSizeFromMetrics(cell: contract.CellMetrics) struct { width: u16, height: u16 } {
    return .{ .width = cell.cell_w_px, .height = cell.cell_h_px };
}

pub fn baselineFromFaceMetrics(input: FaceMetrics26Dot6, cell_h: u16) i32 {
    const ascender_raw = @as(f32, @floatFromInt(input.ascender)) / 64.0;
    const descent_raw = @abs(@as(f32, @floatFromInt(input.descender)) / 64.0);
    const line_height_raw = @max(@as(f32, @floatFromInt(input.height)) / 64.0, 1.0);
    const line_gap_raw = @max(0.0, line_height_raw - (ascender_raw + descent_raw));
    const baseline_from_top_raw = ascender_raw + line_gap_raw / 2.0;
    const scaled_baseline = baseline_from_top_raw * (@as(f32, @floatFromInt(cell_h)) / line_height_raw);
    const rounded = @as(i32, @intFromFloat(std.math.round(scaled_baseline)));
    return std.math.clamp(rounded, 1, @as(i32, @intCast(@max(cell_h, 1))));
}

pub fn metricCeilPx(metric_26_6: anytype, fallback: u16) u16 {
    const raw: i32 = @intCast(metric_26_6);
    if (raw <= 0) return @max(fallback, 1);
    return @intCast(@max(@divTrunc(raw + 63, 64), 1));
}

fn clampThickness(raw: f32, cell_h: u16) u16 {
    const rounded = @as(i32, @intFromFloat(std.math.round(raw)));
    return @intCast(std.math.clamp(rounded, 1, @as(i32, @intCast(@max(cell_h, 1)))));
}

fn clampY(raw: i32, height: u16, cell_h: u16) i32 {
    const max_y = @as(i32, @intCast(@max(cell_h, 1))) - @as(i32, @intCast(height));
    return std.math.clamp(raw, 0, @max(max_y, 0));
}

test "default metrics stay in cell bounds" {
    const cell = defaultCellMetrics(16);
    try std.testing.expect(cell.baseline_px > 0);
    try std.testing.expect(cell.baseline_px <= cell.cell_h_px);
}

test "default decoration thickness scales with cell height" {
    const small = defaultFontMetrics(.{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    const large = defaultFontMetrics(.{ .cell_w_px = 64, .cell_h_px = 128, .baseline_px = 100 });
    try std.testing.expectEqual(@as(f32, 1), small.underline_thickness_px);
    try std.testing.expect(large.underline_thickness_px > small.underline_thickness_px);
    try std.testing.expectEqual(large.underline_thickness_px, large.strikethrough_thickness_px);
}

test "face metrics derive bounded baseline" {
    const cell = cellMetricsFromFaceMetrics(.{
        .ascender = 12 * 64,
        .descender = -4 * 64,
        .height = 18 * 64,
        .max_advance = 9 * 64,
        .fallback_font_px = 16,
    });
    try std.testing.expectEqual(@as(u16, 9), cell.cell_w_px);
    try std.testing.expectEqual(@as(u16, 18), cell.cell_h_px);
    try std.testing.expect(cell.baseline_px > 0);
    try std.testing.expect(cell.baseline_px <= cell.cell_h_px);
}

test "decoration and cursor geometry stay in cell bounds" {
    const cell = contract.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    const font = defaultFontMetrics(cell);
    const deco = decorationGeometry(cell, font);
    try std.testing.expect(deco.underline_y_px >= 0);
    try std.testing.expect(deco.underline_y_px + deco.underline_h_px <= cell.cell_h_px);
    try std.testing.expect(deco.strikethrough_y_px >= 0);
    try std.testing.expect(deco.strikethrough_y_px + deco.strikethrough_h_px <= cell.cell_h_px);

    const cursor = cursorGeometry(cell);
    try std.testing.expectEqual(@as(u16, 2), cursor.beam_w_px);
    try std.testing.expectEqual(@as(u16, 2), cursor.underline_h_px);
    try std.testing.expectEqual(@as(u16, 1), cursor.hollow_stroke_px);
}

test "bitmap placement preserves bearings around baseline" {
    const face = FaceMetrics26Dot6{
        .ascender = 12 * 64,
        .descender = -4 * 64,
        .height = 18 * 64,
        .max_advance = 9 * 64,
        .fallback_font_px = 16,
    };
    const cell = cellMetricsFromFaceMetrics(face);
    const placement = bitmapPlacement(cell, face, -1, 10, 8, 11);
    try std.testing.expectEqual(@as(i32, -1), placement.x_px);
    try std.testing.expect(placement.y_px >= -@as(i32, @intCast(placement.height_px)));
    try std.testing.expectEqual(@as(u16, 8), placement.width_px);
}

test "advance helper preserves positive glyph advance" {
    try std.testing.expectEqual(@as(f32, 9.0), advancePx(9 * 64, 8));
    try std.testing.expectEqual(@as(f32, 8.0), advancePx(0, 8));
}

test "group placement preserves glyph offsets and summed advance" {
    const placement = groupPlacement(&.{
        .{ .face_id = .{ .value = 1 }, .glyph_id = 1, .cluster_index = 0, .x_offset_px = -1, .y_offset_px = 2, .x_advance_px = 6 },
        .{ .face_id = .{ .value = 1 }, .glyph_id = 2, .cluster_index = 0, .x_offset_px = 0, .y_offset_px = 1, .x_advance_px = 5 },
    }, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, 1);
    try std.testing.expectEqual(@as(f32, -1), placement.x_offset_px);
    try std.testing.expectEqual(@as(f32, 1), placement.y_offset_px);
    try std.testing.expectEqual(@as(f32, 11), placement.advance_px);
}
