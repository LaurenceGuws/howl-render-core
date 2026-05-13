//! Responsibility: define glyph-group rasterization contracts.
//! Ownership: render text engine.
//! Reason: rasterize shaped groups as sprites, not only individual codepoints.

const std = @import("std");
const contract = @import("../text_contract.zig");
const metrics = @import("metrics.zig");
const special_glyphs = @import("special_glyphs.zig");

pub const RasterSpriteRequest = struct {
    key: contract.SpriteKey,
    group: contract.GlyphGroup,
    cell_metrics: contract.CellMetrics,
};

pub const RasterSpriteOutput = struct {
    allocator: std.mem.Allocator,
    key: contract.SpriteKey,
    width_px: u16,
    height_px: u16,
    color_mode: contract.SpriteColorMode = .alpha,
    visual_bounds: SpriteBounds = .{},
    pixels: []u8,

    pub fn deinit(self: *RasterSpriteOutput) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn visualBounds(self: RasterSpriteOutput) SpriteBounds {
        if (self.visual_bounds.width_px != 0 and self.visual_bounds.height_px != 0) return self.visual_bounds;
        return alphaBounds(self.pixels, self.width_px, self.height_px);
    }
};

pub const SpriteBounds = struct {
    x_px: u16 = 0,
    y_px: u16 = 0,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

pub fn alphaBounds(pixels: []const u8, width_px: u16, height_px: u16) SpriteBounds {
    if (width_px == 0 or height_px == 0) return .{};
    var min_x: u16 = width_px;
    var min_y: u16 = height_px;
    var max_x: u16 = 0;
    var max_y: u16 = 0;
    var seen = false;
    for (0..height_px) |yy| {
        const row = yy * @as(usize, width_px);
        for (0..width_px) |xx| {
            if (row + xx >= pixels.len or pixels[row + xx] == 0) continue;
            const x: u16 = @intCast(xx);
            const y: u16 = @intCast(yy);
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
            seen = true;
        }
    }
    if (!seen) return .{};
    return .{
        .x_px = min_x,
        .y_px = min_y,
        .width_px = max_x - min_x + 1,
        .height_px = max_y - min_y + 1,
    };
}

pub const OwnedRasterPlan = struct {
    allocator: std.mem.Allocator,
    outputs: []RasterSpriteOutput,
    owned: bool = true,

    pub fn deinit(self: *OwnedRasterPlan) void {
        if (self.owned) {
            for (self.outputs) |*out| out.deinit();
            self.allocator.free(self.outputs);
        }
        self.* = undefined;
    }
};

pub const RasterizeSpriteFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!RasterSpriteOutput;

pub const Rasterizer = struct {
    ctx: *anyopaque,
    rasterize_sprite: RasterizeSpriteFn,

    pub fn rasterize(self: Rasterizer, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) !RasterSpriteOutput {
        return self.rasterize_sprite(self.ctx, allocator, req);
    }
};

pub fn requestForGroup(group: contract.GlyphGroup, cell_metrics: contract.CellMetrics) contract.SpriteRasterRequest {
    const width_cells = @max(group.cell_span, 1);
    return .{
        .key = group.sprite_key,
        .group = group,
        .placement = group.placement,
        .width_px = @intCast(@as(u32, width_cells) * @as(u32, cell_metrics.cell_w_px)),
        .height_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
        .box_drawing = metrics.boxDrawingRasterMetrics(cell_metrics),
        .color_mode = if (group.kind == .emoji) .color else .alpha,
    };
}

pub fn appendPendingRequest(
    allocator: std.mem.Allocator,
    requests: *std.ArrayList(contract.SpriteRasterRequest),
    pending: bool,
    req: contract.SpriteRasterRequest,
) !void {
    if (!pending) return;
    for (requests.items) |existing| {
        if (existing.key.value == req.key.value) return;
    }
    try requests.append(allocator, req);
}

test "raster output reports non-empty alpha bounds" {
    const pixels = [_]u8{
        0, 0, 0, 0,
        0, 7, 8, 0,
        0, 0, 9, 0,
    };
    const bounds = alphaBounds(&pixels, 4, 3);
    try std.testing.expectEqual(@as(u16, 1), bounds.x_px);
    try std.testing.expectEqual(@as(u16, 1), bounds.y_px);
    try std.testing.expectEqual(@as(u16, 2), bounds.width_px);
    try std.testing.expectEqual(@as(u16, 2), bounds.height_px);
}

/// Builds a raster request for a generated undercurl alpha sprite.
pub fn requestForUndercurl(key: contract.SpriteKey, width_px: u16, height_px: u16, decoration: contract.DecorationSpriteRaster) contract.SpriteRasterRequest {
    return .{
        .kind = .undercurl,
        .key = key,
        .group = .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = key, .kind = .normal },
        .decoration = decoration,
        .width_px = width_px,
        .height_px = height_px,
        .color_mode = .alpha,
    };
}

/// Rasterizes a cosine undercurl into an alpha mask.
pub fn rasterizeUndercurlAlpha(pixels: []u8, width_px: u16, height_px: u16, decoration: contract.DecorationSpriteRaster) void {
    @memset(pixels, 0);
    const width = @max(width_px, 1);
    const height = @max(height_px, 1);
    const max_x = @max(decoration.period_px, 1);
    const cell_width = max_x + 1;
    const xfactor = std.math.tau / @as(f64, @floatFromInt(max_x));
    const half_height = @as(f64, @floatFromInt(@max(decoration.amplitude_px, 1)));
    const thickness: i32 = @intCast(decoration.stroke_px);
    const position = @min(decoration.y_px, height - 1);

    var x: u16 = 0;
    while (x < width) : (x += 1) {
        const cell_x = x % cell_width;
        const wave = half_height * std.math.cos(@as(f64, @floatFromInt(cell_x)) * xfactor);
        const floor_y = std.math.floor(wave);
        const upper_y: i32 = @as(i32, @intFromFloat(std.math.floor(wave - @as(f64, @floatFromInt(thickness)))));
        const lower_y: i32 = @as(i32, @intFromFloat(std.math.ceil(wave)));
        const lower_alpha: u8 = @intFromFloat(@round((wave - floor_y) * 255.0));
        const upper_alpha: u8 = 255 - lower_alpha;

        addAlpha(pixels, width, height, x, position, upper_y, upper_alpha);
        var fill_y = upper_y + 1;
        while (fill_y <= upper_y + thickness) : (fill_y += 1) {
            addAlpha(pixels, width, height, x, position, fill_y, 255);
        }
        addAlpha(pixels, width, height, x, position, lower_y, lower_alpha);
    }
}

/// Rasterizes backend-independent special sprites that should not depend on font fallback.
pub fn rasterizeGeneratedSpecialAlpha(pixels: []u8, width_px: u16, height_px: u16, codepoint: u32) bool {
    const baseline: i16 = @intCast(@min(height_px, @as(u16, @intCast(std.math.maxInt(i16)))));
    return rasterizeGeneratedSpecialAlphaWithMetrics(pixels, width_px, height_px, codepoint, metrics.boxDrawingRasterMetrics(.{ .cell_w_px = width_px, .cell_h_px = height_px, .baseline_px = baseline }));
}

/// Rasterizes backend-independent special sprites with explicit stroke metrics.
pub fn rasterizeGeneratedSpecialAlphaWithMetrics(pixels: []u8, width_px: u16, height_px: u16, codepoint: u32, box_drawing: contract.BoxDrawingRasterMetrics) bool {
    @memset(pixels, 0);
    const width = @max(width_px, 1);
    const height = @max(height_px, 1);
    switch (codepoint) {
        0x2504 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 2),
        0x2505 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 2),
        0x2506 => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 2),
        0x2507 => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 2),
        0x2508 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 3),
        0x2509 => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 3),
        0x250a => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 3),
        0x250b => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 3),
        0x254c => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.light_stroke_px, 1),
        0x254d => rasterizeDashedBoxLine(pixels, width, height, .horizontal, box_drawing.heavy_stroke_px, 1),
        0x254e => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.light_stroke_px, 1),
        0x254f => rasterizeDashedBoxLine(pixels, width, height, .vertical, box_drawing.heavy_stroke_px, 1),
        0x2500...0x2503, 0x250c...0x254b, 0x2550...0x256c, 0x2574...0x257f => if (lineSpec(codepoint)) |lines| rasterizeBoxLines(pixels, width, height, lines, box_drawing) else return false,
        0xe0b0 => rasterizePowerlineTriangle(pixels, width, height, true, false),
        0xe0b2 => rasterizePowerlineTriangle(pixels, width, height, false, false),
        0xe0b1 => rasterizePowerlineHalfDiagonal(pixels, width, height, true, box_drawing),
        0xe0b3 => rasterizePowerlineHalfDiagonal(pixels, width, height, false, box_drawing),
        0xe0b4 => rasterizePowerlineD(pixels, width, height, true, true, box_drawing),
        0xe0b6 => rasterizePowerlineD(pixels, width, height, false, true, box_drawing),
        0xe0b5 => rasterizePowerlineD(pixels, width, height, true, false, box_drawing),
        0xe0b7 => rasterizePowerlineD(pixels, width, height, false, false, box_drawing),
        0xe0b8 => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_left),
        0xe0b9, 0xe0bf => rasterizeCrossLine(pixels, width, height, true, box_drawing),
        0xe0ba => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_right),
        0xe0bb, 0xe0bd => rasterizeCrossLine(pixels, width, height, false, box_drawing),
        0xe0bc => rasterizePowerlineCornerTriangle(pixels, width, height, .top_left),
        0xe0be => rasterizePowerlineCornerTriangle(pixels, width, height, .top_right),
        0x2571 => rasterizeCrossLine(pixels, width, height, false, box_drawing),
        0x2572 => rasterizeCrossLine(pixels, width, height, true, box_drawing),
        0x2573 => {
            rasterizeCrossLine(pixels, width, height, false, box_drawing);
            rasterizeCrossLine(pixels, width, height, true, box_drawing);
        },
        0x256d => rasterizeRoundedCorner(pixels, width, height, .top_left, box_drawing),
        0x256e => rasterizeRoundedCorner(pixels, width, height, .top_right, box_drawing),
        0x2570 => rasterizeRoundedCorner(pixels, width, height, .bottom_left, box_drawing),
        0x256f => rasterizeRoundedCorner(pixels, width, height, .bottom_right, box_drawing),
        0x2580...0x259f => rasterizeBlockElementAlpha(pixels, width, height, codepoint),
        0x2800...0x28ff => rasterizeBrailleAlpha(pixels, width, height, @intCast(codepoint - 0x2800)),
        0x1fb00...0x1fb13 => rasterizeSextantAlpha(pixels, width, height, @intCast(codepoint - 0x1fb00 + 1)),
        0x1fb14...0x1fb27 => rasterizeSextantAlpha(pixels, width, height, @intCast(codepoint - 0x1fb00 + 2)),
        0x1fb28...0x1fb3b => rasterizeSextantAlpha(pixels, width, height, @intCast(codepoint - 0x1fb00 + 3)),
        0x1cd00...0x1cde5 => rasterizeOctantAlpha(pixels, width, height, @intCast(codepoint - 0x1cd00)),
        0x1fbe6 => rasterizeOctantAlpha(pixels, width, height, 0xe6),
        0x1fbe7 => rasterizeOctantAlpha(pixels, width, height, 0xe7),
        else => return false,
    }
    return true;
}

const RoundedCorner = enum { top_left, top_right, bottom_left, bottom_right };

const BoxLineStyle = enum { none, light, heavy, double };

const BoxLines = struct {
    up: BoxLineStyle = .none,
    right: BoxLineStyle = .none,
    down: BoxLineStyle = .none,
    left: BoxLineStyle = .none,
};

fn lineSpec(cp: u32) ?BoxLines {
    return switch (cp) {
        0x2500 => .{ .left = .light, .right = .light },
        0x2501 => .{ .left = .heavy, .right = .heavy },
        0x2502 => .{ .up = .light, .down = .light },
        0x2503 => .{ .up = .heavy, .down = .heavy },
        0x250c => .{ .down = .light, .right = .light },
        0x250d => .{ .down = .light, .right = .heavy },
        0x250e => .{ .down = .heavy, .right = .light },
        0x250f => .{ .down = .heavy, .right = .heavy },
        0x2510 => .{ .down = .light, .left = .light },
        0x2511 => .{ .down = .light, .left = .heavy },
        0x2512 => .{ .down = .heavy, .left = .light },
        0x2513 => .{ .down = .heavy, .left = .heavy },
        0x2514 => .{ .up = .light, .right = .light },
        0x2515 => .{ .up = .light, .right = .heavy },
        0x2516 => .{ .up = .heavy, .right = .light },
        0x2517 => .{ .up = .heavy, .right = .heavy },
        0x2518 => .{ .up = .light, .left = .light },
        0x2519 => .{ .up = .light, .left = .heavy },
        0x251a => .{ .up = .heavy, .left = .light },
        0x251b => .{ .up = .heavy, .left = .heavy },
        0x251c => .{ .up = .light, .down = .light, .right = .light },
        0x251d => .{ .up = .light, .down = .light, .right = .heavy },
        0x251e => .{ .up = .heavy, .right = .light, .down = .light },
        0x251f => .{ .down = .heavy, .right = .light, .up = .light },
        0x2520 => .{ .up = .heavy, .down = .heavy, .right = .light },
        0x2521 => .{ .down = .light, .right = .heavy, .up = .heavy },
        0x2522 => .{ .up = .light, .right = .heavy, .down = .heavy },
        0x2523 => .{ .up = .heavy, .down = .heavy, .right = .heavy },
        0x2524 => .{ .up = .light, .down = .light, .left = .light },
        0x2525 => .{ .up = .light, .down = .light, .left = .heavy },
        0x2526 => .{ .up = .heavy, .left = .light, .down = .light },
        0x2527 => .{ .down = .heavy, .left = .light, .up = .light },
        0x2528 => .{ .up = .heavy, .down = .heavy, .left = .light },
        0x2529 => .{ .down = .light, .left = .heavy, .up = .heavy },
        0x252a => .{ .up = .light, .left = .heavy, .down = .heavy },
        0x252b => .{ .up = .heavy, .down = .heavy, .left = .heavy },
        0x252c => .{ .down = .light, .left = .light, .right = .light },
        0x252d => .{ .left = .heavy, .right = .light, .down = .light },
        0x252e => .{ .right = .heavy, .left = .light, .down = .light },
        0x252f => .{ .down = .light, .left = .heavy, .right = .heavy },
        0x2530 => .{ .down = .heavy, .left = .light, .right = .light },
        0x2531 => .{ .right = .light, .left = .heavy, .down = .heavy },
        0x2532 => .{ .left = .light, .right = .heavy, .down = .heavy },
        0x2533 => .{ .down = .heavy, .left = .heavy, .right = .heavy },
        0x2534 => .{ .up = .light, .left = .light, .right = .light },
        0x2535 => .{ .left = .heavy, .right = .light, .up = .light },
        0x2536 => .{ .right = .heavy, .left = .light, .up = .light },
        0x2537 => .{ .up = .light, .left = .heavy, .right = .heavy },
        0x2538 => .{ .up = .heavy, .left = .light, .right = .light },
        0x2539 => .{ .right = .light, .left = .heavy, .up = .heavy },
        0x253a => .{ .left = .light, .right = .heavy, .up = .heavy },
        0x253b => .{ .up = .heavy, .left = .heavy, .right = .heavy },
        0x253c => .{ .up = .light, .down = .light, .left = .light, .right = .light },
        0x253d => .{ .left = .heavy, .right = .light, .up = .light, .down = .light },
        0x253e => .{ .right = .heavy, .left = .light, .up = .light, .down = .light },
        0x253f => .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy },
        0x2540 => .{ .up = .heavy, .down = .light, .left = .light, .right = .light },
        0x2541 => .{ .down = .heavy, .up = .light, .left = .light, .right = .light },
        0x2542 => .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light },
        0x2543 => .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light },
        0x2544 => .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light },
        0x2545 => .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light },
        0x2546 => .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light },
        0x2547 => .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy },
        0x2548 => .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2549 => .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy },
        0x254a => .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy },
        0x254b => .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2550 => .{ .left = .double, .right = .double },
        0x2551 => .{ .up = .double, .down = .double },
        0x2552 => .{ .down = .light, .right = .double },
        0x2553 => .{ .down = .double, .right = .light },
        0x2554 => .{ .down = .double, .right = .double },
        0x2555 => .{ .down = .light, .left = .double },
        0x2556 => .{ .down = .double, .left = .light },
        0x2557 => .{ .down = .double, .left = .double },
        0x2558 => .{ .up = .light, .right = .double },
        0x2559 => .{ .up = .double, .right = .light },
        0x255a => .{ .up = .double, .right = .double },
        0x255b => .{ .up = .light, .left = .double },
        0x255c => .{ .up = .double, .left = .light },
        0x255d => .{ .up = .double, .left = .double },
        0x255e => .{ .up = .light, .down = .light, .right = .double },
        0x255f => .{ .up = .double, .down = .double, .right = .light },
        0x2560 => .{ .up = .double, .down = .double, .right = .double },
        0x2561 => .{ .up = .light, .down = .light, .left = .double },
        0x2562 => .{ .up = .double, .down = .double, .left = .light },
        0x2563 => .{ .up = .double, .down = .double, .left = .double },
        0x2564 => .{ .down = .light, .left = .double, .right = .double },
        0x2565 => .{ .down = .double, .left = .light, .right = .light },
        0x2566 => .{ .down = .double, .left = .double, .right = .double },
        0x2567 => .{ .up = .light, .left = .double, .right = .double },
        0x2568 => .{ .up = .double, .left = .light, .right = .light },
        0x2569 => .{ .up = .double, .left = .double, .right = .double },
        0x256a => .{ .up = .light, .down = .light, .left = .double, .right = .double },
        0x256b => .{ .up = .double, .down = .double, .left = .light, .right = .light },
        0x256c => .{ .up = .double, .down = .double, .left = .double, .right = .double },
        0x2574 => .{ .left = .light },
        0x2575 => .{ .up = .light },
        0x2576 => .{ .right = .light },
        0x2577 => .{ .down = .light },
        0x2578 => .{ .left = .heavy },
        0x2579 => .{ .up = .heavy },
        0x257a => .{ .right = .heavy },
        0x257b => .{ .down = .heavy },
        0x257c => .{ .left = .light, .right = .heavy },
        0x257d => .{ .up = .light, .down = .heavy },
        0x257e => .{ .left = .heavy, .right = .light },
        0x257f => .{ .up = .heavy, .down = .light },
        else => null,
    };
}

fn rasterizeBoxLines(pixels: []u8, width: u16, height: u16, lines: BoxLines, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const light = @max(box_drawing.light_stroke_px, 1);
    const heavy = @max(box_drawing.heavy_stroke_px, light);

    const h_light = centeredRange(height, height / 2, light);
    const h_heavy = centeredRange(height, height / 2, heavy);
    const h_double_top = saturatingSubU16(h_light.start, light);
    const h_double_bottom = @min(h_light.end + light, height);

    const v_light = centeredRange(width, width / 2, light);
    const v_heavy = centeredRange(width, width / 2, heavy);
    const v_double_left = saturatingSubU16(v_light.start, light);
    const v_double_right = @min(v_light.end + light, width);

    // Each arm stops at the neighboring stroke edge instead of overpainting center.
    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy.end
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double) h_double_bottom else h_light.end
    else if (lines.left == .none and lines.right == .none)
        h_light.end
    else
        h_light.start;

    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy.start
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double) h_double_top else h_light.start
    else if (lines.left == .none and lines.right == .none)
        h_light.start
    else
        h_light.end;

    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy.end
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double) v_double_right else v_light.end
    else if (lines.up == .none and lines.down == .none)
        v_light.end
    else
        v_light.start;

    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy.start
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double) v_double_left else v_light.start
    else if (lines.up == .none and lines.down == .none)
        v_light.start
    else
        v_light.end;

    drawBoxVerticalArm(pixels, width, height, lines.up, 0, up_bottom, v_light, v_heavy, v_double_left, v_double_right, lines.left == .double, lines.right == .double, light);
    drawBoxHorizontalArm(pixels, width, height, lines.right, right_left, width, h_light, h_heavy, h_double_top, h_double_bottom, lines.up == .double, lines.down == .double, light);
    drawBoxVerticalArm(pixels, width, height, lines.down, down_top, height, v_light, v_heavy, v_double_left, v_double_right, lines.left == .double, lines.right == .double, light);
    drawBoxHorizontalArm(pixels, width, height, lines.left, 0, left_right, h_light, h_heavy, h_double_top, h_double_bottom, lines.up == .double, lines.down == .double, light);
}

fn drawBoxVerticalArm(pixels: []u8, width: u16, height: u16, style: BoxLineStyle, y0: u16, y1: u16, light_range: Range, heavy_range: Range, double_left: u16, double_right: u16, joins_left_double: bool, joins_right_double: bool, light: u16) void {
    if (y1 <= y0) return;
    switch (style) {
        .none => {},
        .light => fillRectRange(pixels, width, height, light_range.start, y0, light_range.end, y1),
        .heavy => fillRectRange(pixels, width, height, heavy_range.start, y0, heavy_range.end, y1),
        .double => {
            const left_y1 = if (joins_left_double) @min(light_range.start + light, y1) else y1;
            const right_y1 = if (joins_right_double) @min(light_range.start + light, y1) else y1;
            fillRectRange(pixels, width, height, double_left, y0, light_range.start, left_y1);
            fillRectRange(pixels, width, height, light_range.end, y0, double_right, right_y1);
        },
    }
}

fn drawBoxHorizontalArm(pixels: []u8, width: u16, height: u16, style: BoxLineStyle, x0: u16, x1: u16, light_range: Range, heavy_range: Range, double_top: u16, double_bottom: u16, joins_up_double: bool, joins_down_double: bool, light: u16) void {
    if (x1 <= x0) return;
    switch (style) {
        .none => {},
        .light => fillRectRange(pixels, width, height, x0, light_range.start, x1, light_range.end),
        .heavy => fillRectRange(pixels, width, height, x0, heavy_range.start, x1, heavy_range.end),
        .double => {
            const top_x0 = if (joins_up_double) @max(saturatingSubU16(width / 2, light / 2) + light, x0) else x0;
            const bottom_x0 = if (joins_down_double) @max(saturatingSubU16(width / 2, light / 2) + light, x0) else x0;
            fillRectRange(pixels, width, height, top_x0, double_top, x1, light_range.start);
            fillRectRange(pixels, width, height, bottom_x0, light_range.end, x1, double_bottom);
        },
    }
}

fn fillRectRange(pixels: []u8, stride: u16, canvas_height: u16, x0: u16, y0: u16, x1: u16, y1: u16) void {
    const left = @min(x0, stride);
    const top = @min(y0, canvas_height);
    const right = @min(x1, stride);
    const bottom = @min(y1, canvas_height);
    if (right <= left or bottom <= top) return;
    fillRectAlpha(pixels, stride, left, top, right - left, bottom - top, 255);
}

const BoxLineAxis = enum { horizontal, vertical };

fn rasterizeDashedBoxLine(pixels: []u8, width: u16, height: u16, axis: BoxLineAxis, stroke_px: u16, gaps: u16) void {
    const stroke = @max(stroke_px, 1);
    const size = if (axis == .horizontal) width else height;
    const dash_count = @max(gaps + 1, 1);
    const dash_len = @max(size / (dash_count * 2 - 1), stroke);
    var dash: u16 = 0;
    while (dash < dash_count) : (dash += 1) {
        const start = @min(dash * dash_len * 2, size);
        const end = @min(start + dash_len, size);
        if (end <= start) continue;
        if (axis == .horizontal) {
            const y = centeredRange(height, height / 2, stroke);
            if (y.end > y.start) fillRectAlpha(pixels, width, start, y.start, end - start, y.end - y.start, 255);
        } else {
            const x = centeredRange(width, width / 2, stroke);
            if (x.end > x.start) fillRectAlpha(pixels, width, x.start, start, x.end - x.start, end - start, 255);
        }
    }
}

fn rasterizeRoundedCorner(pixels: []u8, width: u16, height: u16, corner: RoundedCorner, box_drawing: contract.BoxDrawingRasterMetrics) void {
    // Use a signed-distance arc so corners align with centered box strokes.
    const stroke_u = @max(box_drawing.light_stroke_px, 1);
    const stroke = @as(f64, @floatFromInt(stroke_u));
    const hori = centeredRange(height, height / 2, stroke_u);
    const vert = centeredRange(width, width / 2, stroke_u);
    const adjusted_hx = @as(f64, @floatFromInt(vert.start)) + @as(f64, @floatFromInt(vert.end - vert.start)) / 2.0;
    const adjusted_hy = @as(f64, @floatFromInt(hori.start)) + @as(f64, @floatFromInt(hori.end - hori.start)) / 2.0;
    const radius = @min(adjusted_hx, adjusted_hy);
    const bx = adjusted_hx - radius;
    const by = adjusted_hy - radius;
    const half_stroke = stroke / 2.0;
    const aa = 0.5;
    const x_shift = switch (corner) {
        .top_right, .bottom_right => adjusted_hx,
        .top_left, .bottom_left => -adjusted_hx,
    };
    const y_shift = switch (corner) {
        .top_left, .top_right => -adjusted_hy,
        .bottom_left, .bottom_right => adjusted_hy,
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const sample_y = @as(f64, @floatFromInt(y)) + y_shift + 0.5;
            const sample_x = @as(f64, @floatFromInt(x)) + x_shift + 0.5;
            const pos_y = sample_y - adjusted_hy;
            const pos_x = sample_x - adjusted_hx;
            const qx = @abs(pos_x) - bx;
            const qy = @abs(pos_y) - by;
            const dx = if (qx > 0.0) qx else 0.0;
            const dy = if (qy > 0.0) qy else 0.0;
            const dist = @sqrt(dx * dx + dy * dy) + @min(@max(qx, qy), 0.0) - radius;
            const edge_aa: f64 = if (qx > 1e-7 and qy > 1e-7) aa else 0.0;
            const outer = half_stroke - dist;
            const inner = -half_stroke - dist;
            const alpha = smoothStep(-edge_aa, edge_aa, outer) - smoothStep(-edge_aa, edge_aa, inner);
            if (alpha <= 0.0) continue;
            const idx = @as(usize, y) * @as(usize, width) + @as(usize, x);
            pixels[idx] = @max(pixels[idx], @as(u8, @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0))));
        }
    }

    snapRoundedCornerConnections(pixels, width, height, corner, stroke_u);
}

fn snapRoundedCornerConnections(pixels: []u8, width: u16, height: u16, corner: RoundedCorner, stroke_px: u16) void {
    const h_range = centeredRange(height, height / 2, stroke_px);
    const v_range = centeredRange(width, width / 2, stroke_px);
    const h_x: u16 = switch (corner) {
        .top_left, .bottom_left => width - 1,
        .top_right, .bottom_right => 0,
    };
    const v_y: u16 = switch (corner) {
        .top_left, .top_right => height - 1,
        .bottom_left, .bottom_right => 0,
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        pixels[@as(usize, y) * @as(usize, width) + @as(usize, h_x)] = if (y >= h_range.start and y < h_range.end) 255 else 0;
    }

    var x: u16 = 0;
    while (x < width) : (x += 1) {
        pixels[@as(usize, v_y) * @as(usize, width) + @as(usize, x)] = if (x >= v_range.start and x < v_range.end) 255 else 0;
    }
}

fn centeredRange(size: u16, center: u16, thickness: u16) Range {
    const start = saturatingSubU16(center, thickness / 2);
    return .{ .start = start, .end = @min(start + thickness, size) };
}

fn smoothStep(edge0: f64, edge1: f64, x: f64) f64 {
    if (edge0 == edge1) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn rasterizeCrossLine(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const line_w = @as(f64, @floatFromInt(@max(box_drawing.light_stroke_px, 1)));
    if (left) {
        drawLineAlpha(pixels, width, height, 0, 0, @floatFromInt(width - 1), @floatFromInt(height - 1), line_w);
    } else {
        drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), 0, 0, @floatFromInt(height - 1), line_w);
    }
}

fn rasterizeOctantAlpha(pixels: []u8, width: u16, height: u16, which: u8) void {
    const mask = octantMask(which);
    if ((mask & 0x01) != 0) fillOctantSegment(pixels, width, height, 0, true);
    if ((mask & 0x02) != 0) fillOctantSegment(pixels, width, height, 1, true);
    if ((mask & 0x04) != 0) fillOctantSegment(pixels, width, height, 2, true);
    if ((mask & 0x08) != 0) fillOctantSegment(pixels, width, height, 3, true);
    if ((mask & 0x10) != 0) fillOctantSegment(pixels, width, height, 0, false);
    if ((mask & 0x20) != 0) fillOctantSegment(pixels, width, height, 1, false);
    if ((mask & 0x40) != 0) fillOctantSegment(pixels, width, height, 2, false);
    if ((mask & 0x80) != 0) fillOctantSegment(pixels, width, height, 3, false);
}

fn fillOctantSegment(pixels: []u8, width: u16, height: u16, which: u8, left: bool) void {
    const y_range = fourthRange(height, which);
    const x0: u16 = if (left) 0 else width / 2;
    const x1: u16 = if (left) width / 2 else width;
    if (x1 > x0 and y_range.end > y_range.start) fillRectAlpha(pixels, width, x0, y_range.start, x1 - x0, y_range.end - y_range.start, 255);
}

fn fourthRange(size: u16, which: u8) Range {
    const thickness = @max(@as(u16, 1), size / 4);
    const block = thickness * 4;
    if (block == size) return .{ .start = thickness * which, .end = thickness * (@as(u16, which) + 1) };
    if (block > size) {
        const start = @min(@as(u16, which) * thickness, saturatingSubU16(size, thickness));
        return .{ .start = start, .end = start + thickness };
    }

    var thicknesses = [_]u16{thickness} ** 4;
    var extra = size - block;
    const order = [_]usize{ 1, 2, 3, 0 };
    for (order) |idx| {
        if (extra == 0) break;
        thicknesses[idx] += 1;
        extra -= 1;
    }
    var pos: u16 = 0;
    var idx: usize = 0;
    while (idx < which) : (idx += 1) pos += thicknesses[idx];
    return .{ .start = pos, .end = pos + thicknesses[which] };
}

fn octantMask(which: u8) u8 {
    const a: u8 = 1;
    const b: u8 = 2;
    const c: u8 = 4;
    const d: u8 = 8;
    const m: u8 = 16;
    const n: u8 = 32;
    const o: u8 = 64;
    const p: u8 = 128;
    const mapping = [_]u8{
        b,                 b | m,             a | b | m,         n,             a | n,             a | m | n,         b | n,             a | b | n,         b | m | n,         c,                 a | c,             c | m,             a | c | m,         a | b | c,         b | c | m,         a | b | c | m,
        c | n,             a | c | n,         c | m | n,         a | c | m | n, b | c | n,         a | b | c | n,     b | c | m | n,     a | b | c | m | n, o,                 a | o,             m | o,             a | m | o,         b | o,             a | b | o,         b | m | o,         a | b | m | o,
        a | n | o,         m | n | o,         a | m | n | o,     b | n | o,     a | b | n | o,     b | m | n | o,     a | b | m | n | o, c | o,             a | c | o,         c | m | o,         a | c | m | o,     b | c | o,         a | b | c | o,     b | c | m | o,     a | b | c | m | o, c | n | o,
        a | c | n | o,     c | m | n | o,     a | c | m | n | o, b | c | n | o, a | b | c | n | o, b | c | m | n | o, a | d,             d | m,             a | d | m,         b | d,             a | b | d,         b | d | m,         a | b | d | m,     d | n,             a | d | n,         d | m | n,
        a | d | m | n,     b | d | n,         a | b | d | n,     b | d | m | n, a | b | d | m | n, a | c | d,         c | d | m,         a | c | d | m,     b | c | d,         b | c | d | m,     a | b | c | d | m, c | d | n,         a | c | d | n,     a | c | d | m | n, b | c | d | n,     a | b | c | d | n,
        b | c | d | m | n, d | o,             a | d | o,         d | m | o,     a | d | m | o,     b | d | o,         a | b | d | o,     b | d | m | o,     a | b | d | m | o, d | n | o,         a | d | n | o,     d | m | n | o,     a | d | m | n | o, b | d | n | o,     a | b | d | n | o, b | d | m | n | o,
        ~(c | p),          c | d | o,         a | c | d | o,     c | d | m | o, a | c | d | m | o, b | c | d | o,     ~(m | n | p),      b | c | d | m | o, ~(n | p),          c | d | n | o,     a | c | d | n | o, c | d | m | n | o, ~(b | p),          b | c | d | n | o, ~(m | p),          ~(a | p),
        ~p,                a | p,             m | p,             a | m | p,     b | p,             a | b | p,         b | m | p,         a | b | m | p,     n | p,             a | n | p,         m | n | p,         a | m | n | p,     b | n | p,         a | b | n | p,     b | m | n | p,     ~(c | d | o),
        c | p,             a | c | p,         c | m | p,         a | c | m | p, b | c | p,         a | b | c | p,     b | c | m | p,     ~(d | n | o),      c | n | p,         a | c | n | p,     c | m | n | p,     ~(b | d | o),      b | c | n | p,     ~(d | m | o),      ~(a | d | o),      ~(d | o),
        a | o | p,         m | o | p,         a | m | o | p,     b | o | p,     b | m | o | p,     a | b | m | o | p, n | o | p,         a | n | o | p,     a | m | n | o | p, b | n | o | p,     a | b | n | o | p, b | m | n | o | p, c | o | p,         a | c | o | p,     c | m | o | p,     a | c | m | o | p,
        b | c | o | p,     a | b | c | o | p, b | c | m | o | p, ~(n | d),      c | n | o | p,     a | c | n | o | p, c | m | n | o | p, ~(b | d),          b | c | n | o | p, ~(d | m),          ~(a | d),          ~d,                a | d | p,         d | m | p,         a | d | m | p,     b | d | p,
        a | b | d | p,     b | d | m | p,     a | b | d | m | p, d | n | p,     a | d | n | p,     d | m | n | p,     a | d | m | n | p, b | d | n | p,     a | b | d | n | p, b | d | m | n | p, ~(c | o),          c | d | p,         a | c | d | p,     c | d | m | p,     a | c | d | m | p, b | c | d | p,
        a | b | c | d | p, b | c | d | m | p, ~(n | o),          c | d | n | p, a | c | d | n | p, c | d | m | n | p, ~(b | o),          b | c | d | n | p, ~(m | o),          ~(a | o),          ~o,                d | o | p,         a | d | o | p,     d | m | o | p,     a | d | m | o | p, b | d | o | p,
        a | b | d | o | p, b | d | m | o | p, ~(c | n),          d | n | o | p, a | d | n | o | p, d | m | n | o | p, ~(b | c),          b | d | n | o | p, ~(c | m),          ~(a | c),          ~c,                a | c | d | o | p, c | d | m | o | p, ~(b | n),          b | c | d | o | p, ~(a | n),
        ~n,                c | d | n | o | p, ~(b | m),          ~b,            ~m,                ~a,                b | c,             n | o,
    };
    return mapping[which];
}

fn rasterizeSextantAlpha(pixels: []u8, width: u16, height: u16, which: u8) void {
    drawSextantRow(pixels, width, height, which % 4, 0);
    drawSextantRow(pixels, width, height, which / 4, 1);
    drawSextantRow(pixels, width, height, which / 16, 2);
}

fn drawSextantRow(pixels: []u8, width: u16, height: u16, row_bits: u8, row: u16) void {
    if ((row_bits & 1) != 0) fillSextantCell(pixels, width, height, row, 0);
    if ((row_bits & 2) != 0) fillSextantCell(pixels, width, height, row, 1);
}

fn fillSextantCell(pixels: []u8, width: u16, height: u16, row: u16, col: u16) void {
    const y0: u16 = @intCast(@as(u32, height) * @as(u32, row) / 3);
    const y1: u16 = @intCast(@as(u32, height) * @as(u32, row + 1) / 3);
    const x0: u16 = if (col == 0) 0 else width / 2;
    const x1: u16 = if (col == 0) width / 2 else width;
    if (x1 > x0 and y1 > y0) fillRectAlpha(pixels, width, x0, y0, x1 - x0, y1 - y0, 255);
}

fn rasterizeBlockElementAlpha(pixels: []u8, width: u16, height: u16, codepoint: u32) void {
    switch (codepoint) {
        0x2580 => fillRows(pixels, width, height, 0, 4),
        0x2581 => fillRows(pixels, width, height, 7, 8),
        0x2582 => fillRows(pixels, width, height, 6, 8),
        0x2583 => fillRows(pixels, width, height, 5, 8),
        0x2584 => fillRows(pixels, width, height, 4, 8),
        0x2585 => fillRows(pixels, width, height, 3, 8),
        0x2586 => fillRows(pixels, width, height, 2, 8),
        0x2587 => fillRows(pixels, width, height, 1, 8),
        0x2588 => fillRectAlpha(pixels, width, 0, 0, width, height, 255),
        0x2589 => fillCols(pixels, width, height, 0, 7),
        0x258a => fillCols(pixels, width, height, 0, 6),
        0x258b => fillCols(pixels, width, height, 0, 5),
        0x258c => fillCols(pixels, width, height, 0, 4),
        0x258d => fillCols(pixels, width, height, 0, 3),
        0x258e => fillCols(pixels, width, height, 0, 2),
        0x258f => fillCols(pixels, width, height, 0, 1),
        0x2590 => fillCols(pixels, width, height, 4, 8),
        0x2591 => fillShade(pixels, width, height, .light),
        0x2592 => fillShade(pixels, width, height, .medium),
        0x2593 => fillShade(pixels, width, height, .dark),
        0x2594 => fillRows(pixels, width, height, 0, 1),
        0x2595 => fillCols(pixels, width, height, 7, 8),
        0x2596 => fillQuadrant(pixels, width, height, .bottom_left),
        0x2597 => fillQuadrant(pixels, width, height, .bottom_right),
        0x2598 => fillQuadrant(pixels, width, height, .top_left),
        0x2599 => fillQuadrants(pixels, width, height, &.{ .top_left, .bottom_left, .bottom_right }),
        0x259a => fillQuadrants(pixels, width, height, &.{ .top_left, .bottom_right }),
        0x259b => fillQuadrants(pixels, width, height, &.{ .top_left, .top_right, .bottom_left }),
        0x259c => fillQuadrants(pixels, width, height, &.{ .top_left, .top_right, .bottom_right }),
        0x259d => fillQuadrant(pixels, width, height, .top_right),
        0x259e => fillQuadrants(pixels, width, height, &.{ .top_right, .bottom_left }),
        0x259f => fillQuadrants(pixels, width, height, &.{ .top_right, .bottom_left, .bottom_right }),
        else => {},
    }
}

fn fillRows(pixels: []u8, width: u16, height: u16, start_eighth: u16, end_eighth: u16) void {
    var eighth = start_eighth;
    while (eighth < end_eighth) : (eighth += 1) {
        const range = eighthRange(height, eighth);
        if (range.end > range.start) fillRectAlpha(pixels, width, 0, range.start, width, range.end - range.start, 255);
    }
}

fn fillCols(pixels: []u8, width: u16, height: u16, start_eighth: u16, end_eighth: u16) void {
    var eighth = start_eighth;
    while (eighth < end_eighth) : (eighth += 1) {
        const range = eighthRange(width, eighth);
        if (range.end > range.start) fillRectAlpha(pixels, width, range.start, 0, range.end - range.start, height, 255);
    }
}

const Range = struct { start: u16, end: u16 };

fn eighthRange(size: u16, which: u16) Range {
    const thickness = @max(@as(u16, 1), size / 8);
    const block = thickness * 8;
    if (block == size) return .{ .start = thickness * which, .end = thickness * (which + 1) };
    if (block > size) {
        const start = @min(which * thickness, saturatingSubU16(size, thickness));
        return .{ .start = start, .end = start + thickness };
    }

    var thicknesses = [_]u16{thickness} ** 8;
    var extra = size - block;
    const order = [_]usize{ 3, 4, 2, 5, 6, 1, 7, 0 };
    for (order) |idx| {
        if (extra == 0) break;
        thicknesses[idx] += 1;
        extra -= 1;
    }
    var pos: u16 = 0;
    var idx: usize = 0;
    while (idx < which) : (idx += 1) pos += thicknesses[idx];
    return .{ .start = pos, .end = pos + thicknesses[which] };
}

const BlockQuadrant = enum { top_left, top_right, bottom_left, bottom_right };

fn fillQuadrants(pixels: []u8, width: u16, height: u16, quadrants: []const BlockQuadrant) void {
    for (quadrants) |quadrant| fillQuadrant(pixels, width, height, quadrant);
}

fn fillQuadrant(pixels: []u8, width: u16, height: u16, quadrant: BlockQuadrant) void {
    const half_w = width / 2;
    const half_h = height / 2;
    const x = switch (quadrant) {
        .top_left, .bottom_left => 0,
        .top_right, .bottom_right => half_w,
    };
    const y = switch (quadrant) {
        .top_left, .top_right => 0,
        .bottom_left, .bottom_right => half_h,
    };
    fillRectAlpha(pixels, width, x, y, width - x - if (x == 0) width - half_w else 0, height - y - if (y == 0) height - half_h else 0, 255);
}

const ShadeDensity = enum { light, medium, dark };

fn fillShade(pixels: []u8, width: u16, height: u16, density: ShadeDensity) void {
    const alpha: u8 = switch (density) {
        .light => 0x40,
        .medium => 0x80,
        .dark => 0xc0,
    };
    fillRectAlpha(pixels, width, 0, 0, width, height, alpha);
}

fn rasterizePowerlineTriangle(pixels: []u8, width: u16, height: u16, left: bool, inverted: bool) void {
    const x1: f64 = if (left) 0 else @floatFromInt(width - 1);
    const x2: f64 = if (left) @floatFromInt(width - 1) else 0;
    const y_mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const coverage = supersampledTriangleCoverage(x, y, .{ .x1 = x1, .x2 = x2, .y_mid = y_mid, .height = height, .inverted = inverted });
            if (coverage != 0) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = coverage;
        }
    }
}

fn rasterizePowerlineHalfDiagonal(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    const line_w = @as(f64, @floatFromInt(@max(box_drawing.light_stroke_px, 1)));
    if (left) {
        drawLineAlpha(pixels, width, height, 0, 0, @floatFromInt(width - 1), mid, line_w);
        drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), mid, 0, @floatFromInt(height - 1), line_w);
    } else {
        drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), 0, 0, mid, line_w);
        drawLineAlpha(pixels, width, height, 0, mid, @floatFromInt(width - 1), @floatFromInt(height - 1), line_w);
    }
}

fn rasterizePowerlineD(pixels: []u8, width: u16, height: u16, left: bool, filled: bool, box_drawing: contract.BoxDrawingRasterMetrics) void {
    if (filled) {
        rasterizePowerlineFilledD(pixels, width, height, left);
    } else {
        rasterizePowerlineRoundedD(pixels, width, height, left, box_drawing);
    }
}

const PointF = struct { x: f64, y: f64 };

const CubicBezier = struct {
    start: PointF,
    c1: PointF,
    c2: PointF,
    end: PointF,
};

fn rasterizePowerlineFilledD(pixels: []u8, width: u16, height: u16, left: bool) void {
    const max_x = findBezierControlX(width, height);
    const bottom: f64 = @floatFromInt(height);
    const cb = CubicBezier{
        .start = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = @floatFromInt(max_x), .y = 0 },
        .c2 = .{ .x = @floatFromInt(max_x), .y = bottom },
        .end = .{ .x = 0, .y = bottom },
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const coverage = supersampledFilledDCoverage(x, y, .{ .cb = cb, .width = width, .left = left });
            if (coverage != 0) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = coverage;
        }
    }
}

const TriangleCoverageCtx = struct { x1: f64, x2: f64, y_mid: f64, height: u16, inverted: bool };
const FilledDCoverageCtx = struct { cb: CubicBezier, width: u16, left: bool };

fn supersampledTriangleCoverage(x: u16, y: u16, ctx: TriangleCoverageCtx) u8 {
    return supersampledCoverage(x, y, triangleContains, ctx);
}

fn supersampledFilledDCoverage(x: u16, y: u16, ctx: FilledDCoverageCtx) u8 {
    return supersampledCoverage(x, y, filledDContains, ctx);
}

fn triangleContains(px: f64, py: f64, ctx: TriangleCoverageCtx) bool {
    const upper = lineY(ctx.x1, 0, ctx.x2, ctx.y_mid, px);
    const lower = lineY(ctx.x1, @floatFromInt(ctx.height - 1), ctx.x2, ctx.y_mid, px);
    return (py >= upper and py <= lower) != ctx.inverted;
}

fn filledDContains(px_raw: f64, py: f64, ctx: FilledDCoverageCtx) bool {
    const px = if (ctx.left) px_raw else @as(f64, @floatFromInt(ctx.width - 1)) - px_raw;
    const t = findBezierTForX(ctx.cb, px);
    if (bezierX(ctx.cb, t) > @as(f64, @floatFromInt(ctx.width - 1)) + 0.5) return false;
    const upper = bezierY(ctx.cb, t);
    const lower = bezierY(ctx.cb, 1.0 - t);
    return py >= upper and py <= lower;
}

fn supersampledCoverage(x: u16, y: u16, comptime inside: anytype, ctx: anytype) u8 {
    const factor = 4;
    var hits: u16 = 0;
    var sy: u8 = 0;
    while (sy < factor) : (sy += 1) {
        var sx: u8 = 0;
        while (sx < factor) : (sx += 1) {
            const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / factor;
            const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / factor;
            if (inside(px, py, ctx)) hits += 1;
        }
    }
    return @intCast((hits * 255 + (factor * factor / 2)) / (factor * factor));
}

fn rasterizePowerlineRoundedD(pixels: []u8, width: u16, height: u16, left: bool, box_drawing: contract.BoxDrawingRasterMetrics) void {
    const gap = @max(box_drawing.light_stroke_px, 1);
    const half_gap = @as(f64, @floatFromInt(gap)) / 2.0;
    const curve_w = if (width > gap) width - gap else width;
    const curve_h = if (height > gap) height - gap else height;
    const max_x = findBezierControlX(curve_w, curve_h);
    const cb = CubicBezier{
        .start = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = @floatFromInt(max_x), .y = 0 },
        .c2 = .{ .x = @floatFromInt(max_x), .y = @floatFromInt(curve_h - 1) },
        .end = .{ .x = 0, .y = @floatFromInt(curve_h - 1) },
    };
    drawCubicStrokeAlpha(pixels, width, height, cb, @floatFromInt(@max(gap, 1)), half_gap, left);
}

fn findBezierControlX(width: u16, height: u16) u16 {
    var cx: u16 = width - 1;
    var last = cx;
    while (cx < width * 4) : (cx += 1) {
        const cb = CubicBezier{
            .start = .{ .x = 0, .y = 0 },
            .c1 = .{ .x = @floatFromInt(cx), .y = 0 },
            .c2 = .{ .x = @floatFromInt(cx), .y = @floatFromInt(height - 1) },
            .end = .{ .x = 0, .y = @floatFromInt(height - 1) },
        };
        if (bezierX(cb, 0.5) > @as(f64, @floatFromInt(width - 1))) return last;
        last = cx;
    }
    return last;
}

fn findBezierTForX(cb: CubicBezier, x: f64) f64 {
    var lo: f64 = 0;
    var hi: f64 = 0.5;
    var i: u8 = 0;
    while (i < 24) : (i += 1) {
        const mid = (lo + hi) / 2.0;
        if (bezierX(cb, mid) < x) lo = mid else hi = mid;
    }
    return (lo + hi) / 2.0;
}

fn drawCubicStrokeAlpha(pixels: []u8, width: u16, height: u16, cb: CubicBezier, line_width: f64, y_offset: f64, left: bool) void {
    const samples = 96;
    const half = @max(line_width, 1.0) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const px = @as(f64, @floatFromInt(if (left) x else width - 1 - x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5 - y_offset;
            var min_d2 = std.math.floatMax(f64);
            var i: usize = 0;
            while (i <= samples) : (i += 1) {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples));
                const sx = bezierX(cb, t);
                const sy = bezierY(cb, t);
                const dx = px - sx;
                const dy = py - sy;
                min_d2 = @min(min_d2, dx * dx + dy * dy);
            }
            const coverage = std.math.clamp(half - @sqrt(min_d2) + 0.5, 0.0, 1.0);
            if (coverage <= 0) continue;
            pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = @intFromFloat(@round(coverage * 255.0));
        }
    }
}

fn bezierX(cb: CubicBezier, t: f64) f64 {
    return bezierValue(cb.start.x, cb.c1.x, cb.c2.x, cb.end.x, t);
}

fn bezierY(cb: CubicBezier, t: f64) f64 {
    return bezierValue(cb.start.y, cb.c1.y, cb.c2.y, cb.end.y, t);
}

fn bezierValue(start: f64, c1: f64, c2: f64, end: f64, t: f64) f64 {
    const u = 1.0 - t;
    return u * u * u * start + 3.0 * t * u * (u * c1 + t * c2) + t * t * t * end;
}

const PowerlineCorner = enum { top_left, top_right, bottom_left, bottom_right };

fn rasterizePowerlineCornerTriangle(pixels: []u8, width: u16, height: u16, corner: PowerlineCorner) void {
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const xf = @as(f64, @floatFromInt(x)) + 0.5;
            const yf = @as(f64, @floatFromInt(y)) + 0.5;
            const diag_down = lineY(0, 0, @floatFromInt(width - 1), @floatFromInt(height - 1), xf);
            const diag_up = lineY(@floatFromInt(width - 1), 0, 0, @floatFromInt(height - 1), xf);
            const inside = switch (corner) {
                .top_left => yf <= diag_up,
                .top_right => yf <= diag_down,
                .bottom_left => yf >= diag_down,
                .bottom_right => yf >= diag_up,
            };
            if (inside) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = 255;
        }
    }
}

fn drawLineAlpha(pixels: []u8, width: u16, height: u16, x1: f64, y1: f64, x2: f64, y2: f64, line_width: f64) void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = @max(dx * dx + dy * dy, 1.0);
    const half = @max(line_width, 1.0) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const t = std.math.clamp(((px - x1) * dx + (py - y1) * dy) / len2, 0.0, 1.0);
            const cx = x1 + t * dx;
            const cy = y1 + t * dy;
            const dist = @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage <= 0) continue;
            const idx = @as(usize, y) * @as(usize, width) + @as(usize, x);
            pixels[idx] = @max(pixels[idx], @as(u8, @intFromFloat(@round(coverage * 255.0))));
        }
    }
}

fn lineY(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) f64 {
    if (x1 == x2) return y1;
    const m = (y2 - y1) / (x2 - x1);
    return m * x + y1 - m * x1;
}

fn rasterizeBrailleAlpha(pixels: []u8, width: u16, height: u16, mask: u8) void {
    if (mask == 0) return;
    const layout = brailleLayout(width, height);
    var bit: u8 = 0;
    while (bit < 8) : (bit += 1) {
        if ((mask & (@as(u8, 1) << @intCast(bit))) == 0) continue;
        const dot_number = bit + 1;
        const col: u16 = switch (dot_number) {
            1, 2, 3, 7 => 0,
            else => 1,
        };
        const row: u16 = switch (dot_number) {
            1, 4 => 0,
            2, 5 => 1,
            3, 6 => 2,
            else => 3,
        };
        const x = layout.x[col];
        const y = layout.y[row];
        drawBrailleDotAlpha(pixels, width, height, x, y, layout.dot);
    }
}

fn drawBrailleDotAlpha(pixels: []u8, width: u16, height: u16, x0: u16, y0: u16, dot: u16) void {
    const w = @min(dot, width - x0);
    const h = @min(dot, height - y0);
    if (w == 0 or h == 0) return;
    if (w == 1 and h == 1) {
        pixels[@as(usize, y0) * @as(usize, width) + @as(usize, x0)] = 255;
        return;
    }

    const factor = 4;
    const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
    const rx = @max(@as(f64, @floatFromInt(w)) / 2.0, 0.5);
    const ry = @max(@as(f64, @floatFromInt(h)) / 2.0, 0.5);
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            var hits: u16 = 0;
            var sy: u8 = 0;
            while (sy < factor) : (sy += 1) {
                var sx: u8 = 0;
                while (sx < factor) : (sx += 1) {
                    const px = @as(f64, @floatFromInt(x0 + x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / factor;
                    const py = @as(f64, @floatFromInt(y0 + y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / factor;
                    const nx = (px - cx) / rx;
                    const ny = (py - cy) / ry;
                    if (nx * nx + ny * ny <= 1.0) hits += 1;
                }
            }
            const alpha: u8 = @intCast((hits * 255 + (factor * factor / 2)) / (factor * factor));
            if (alpha == 0) continue;
            const idx = @as(usize, y0 + y) * @as(usize, width) + @as(usize, x0 + x);
            pixels[idx] = @max(pixels[idx], alpha);
        }
    }
}

const BrailleLayout = struct { dot: u16, x: [2]u16, y: [4]u16 };

fn brailleLayout(width: u16, height: u16) BrailleLayout {
    var dot: i32 = @intCast(@min(width / 4, height / 8));
    var x_spacing: i32 = @intCast(width / 4);
    var y_spacing: i32 = @intCast(height / 8);
    var x_margin = @divFloor(x_spacing, 2);
    var y_margin = @divFloor(y_spacing, 2);
    var x_left: i32 = @as(i32, @intCast(width)) - 2 * x_margin - x_spacing - 2 * dot;
    var y_left: i32 = @as(i32, @intCast(height)) - 2 * y_margin - 3 * y_spacing - 4 * dot;

    if (x_left >= 2 and y_left >= 4 and dot == 0) {
        dot += 1;
        x_left -= 2;
        y_left -= 4;
    }
    if (x_left >= 2 and x_margin == 0) {
        x_margin += 1;
        x_left -= 2;
    }
    if (y_left >= 2 and y_margin == 0) {
        y_margin += 1;
        y_left -= 2;
    }
    if (x_left >= 1) {
        x_spacing += 1;
        x_left -= 1;
    }
    if (y_left >= 3) {
        y_spacing += 1;
        y_left -= 3;
    }
    if (x_left >= 2) {
        x_margin += 1;
        x_left -= 2;
    }
    if (y_left >= 2) {
        y_margin += 1;
        y_left -= 2;
    }
    if (x_left >= 2 and y_left >= 4) {
        dot += 1;
    }

    const safe_dot: u16 = @intCast(@max(dot, 1));
    const x0: u16 = @intCast(@max(x_margin, 0));
    const y0: u16 = @intCast(@max(y_margin, 0));
    return .{
        .dot = safe_dot,
        .x = .{ x0, @intCast(@min(@as(i32, @intCast(width - 1)), x_margin + dot + x_spacing)) },
        .y = .{
            y0,
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + dot + y_spacing)),
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + 2 * dot + 2 * y_spacing)),
            @intCast(@min(@as(i32, @intCast(height - 1)), y_margin + 3 * dot + 3 * y_spacing)),
        },
    };
}

fn fillRectAlpha(pixels: []u8, stride: u16, x: u16, y: u16, width: u16, height: u16, alpha: u8) void {
    var yy = y;
    while (yy < y + height) : (yy += 1) {
        var xx = x;
        while (xx < x + width) : (xx += 1) {
            pixels[@as(usize, yy) * @as(usize, stride) + @as(usize, xx)] = alpha;
        }
    }
}

fn saturatingSubU16(a: u16, b: u16) u16 {
    return if (a > b) a - b else 0;
}

fn addAlpha(pixels: []u8, width: u16, height: u16, x: u16, position: u16, y_offset: i32, alpha: u8) void {
    if (alpha == 0) return;
    const raw_y = @as(i32, @intCast(position)) + y_offset;
    const y_clamped = std.math.clamp(raw_y, 0, @as(i32, @intCast(height - 1)));
    const idx = @as(usize, @intCast(y_clamped)) * @as(usize, width) + @as(usize, x);
    pixels[idx] = @intCast(@min(@as(u16, pixels[idx]) + @as(u16, alpha), 255));
}

pub fn placeholderRaster(allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) !RasterSpriteOutput {
    const bytes = @as(usize, req.width_px) * @as(usize, req.height_px);
    const pixels = try allocator.alloc(u8, bytes);
    @memset(pixels, 0);
    if (req.kind == .undercurl) rasterizeUndercurlAlpha(pixels, req.width_px, req.height_px, req.decoration);
    return .{
        .allocator = allocator,
        .key = req.key,
        .width_px = req.width_px,
        .height_px = req.height_px,
        .color_mode = req.color_mode,
        .pixels = pixels,
    };
}

pub fn defaultRasterizer() Rasterizer {
    return .{ .ctx = undefined, .rasterize_sprite = placeholderRasterThunk };
}

fn placeholderRasterThunk(_: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!RasterSpriteOutput {
    return placeholderRaster(allocator, req);
}

pub fn rasterizeRequestsWithRasterizer(allocator: std.mem.Allocator, raster: Rasterizer, requests: []const contract.SpriteRasterRequest) !OwnedRasterPlan {
    const outputs = try allocator.alloc(RasterSpriteOutput, requests.len);
    errdefer allocator.free(outputs);

    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*out| out.deinit();
    }

    for (requests, 0..) |req, idx| {
        outputs[idx] = try raster.rasterize(allocator, req);
        initialized += 1;
    }

    return .{ .allocator = allocator, .outputs = outputs };
}

test "raster request preserves group key and dimensions" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 2, .glyphs = &.{}, .sprite_key = .{ .value = 42 }, .kind = .normal };
    const req = requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    try std.testing.expectEqual(@as(u64, 42), req.key.value);
    try std.testing.expectEqual(@as(u16, 16), req.width_px);
    try std.testing.expectEqual(@as(i16, 12), req.baseline_px);
    try std.testing.expectEqual(@as(u16, 2), req.box_drawing.light_stroke_px);
    var out = try placeholderRaster(std.testing.allocator, req);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 16 * 16), out.pixels.len);
}

test "raster request preserves configured box drawing thickness" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 43 }, .kind = .box_fallback };
    const req = requestForGroup(group, .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 3 });
    try std.testing.expectEqual(@as(u16, 3), req.box_drawing.light_stroke_px);
    try std.testing.expectEqual(@as(u16, 6), req.box_drawing.heavy_stroke_px);
}

test "undercurl raster request generates alpha mask" {
    const req = requestForUndercurl(.{ .value = 7 }, 24, 16, .{ .stroke_px = 2, .amplitude_px = 3, .period_px = 12, .y_px = 12 });
    var out = try placeholderRaster(std.testing.allocator, req);
    defer out.deinit();
    var lit: usize = 0;
    for (out.pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < out.pixels.len);
}

test "generated special support table matches rasterizer dispatch" {
    const RangeCase = struct { start: u32, end: u32 };
    const cases = [_]RangeCase{
        .{ .start = 0x2500, .end = 0x257f },
        .{ .start = 0x2580, .end = 0x259f },
        .{ .start = 0x2800, .end = 0x28ff },
        .{ .start = 0xe0b0, .end = 0xe0bf },
        .{ .start = 0x1fb00, .end = 0x1fb13 },
        .{ .start = 0x1fb14, .end = 0x1fb27 },
        .{ .start = 0x1fb28, .end = 0x1fb3b },
        .{ .start = 0x1cd00, .end = 0x1cde5 },
        .{ .start = 0x1fbe6, .end = 0x1fbe7 },
    };

    for (cases) |case| {
        var cp = case.start;
        while (cp <= case.end) : (cp += 1) {
            try std.testing.expect(special_glyphs.isGeneratedSpecialSupported(cp));
            var pixels = [_]u8{0} ** (12 * 18);
            try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, 12, 18, cp));
        }
    }

    try std.testing.expect(!special_glyphs.isGeneratedSpecialSupported(0x1fb70));
    var pixels = [_]u8{0} ** (12 * 18);
    try std.testing.expect(!rasterizeGeneratedSpecialAlpha(&pixels, 12, 18, 0x1fb70));
}

test "generated special raster draws braille dots" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2801));
    var other = [_]u8{0} ** (width * height);
    try std.testing.expect(!rasterizeGeneratedSpecialAlpha(&other, width, height, 'A'));
    var top_left: usize = 0;
    var bottom_right: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const alpha = pixels[y * width + x];
            if (alpha == 0) continue;
            if (x < width / 2 and y < height / 4) top_left += 1;
            if (x >= width / 2 and y >= height * 3 / 4) bottom_right += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(usize, 0), bottom_right);
}

test "generated braille preserves gaps at small cell sizes" {
    const width = 6;
    const height = 12;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x28ff));

    var blank_col = false;
    for (0..width) |x| {
        var lit = false;
        for (0..height) |y| lit = lit or pixels[y * width + x] != 0;
        if (!lit) blank_col = true;
    }
    var blank_row = false;
    for (0..height) |y| {
        var lit = false;
        for (0..width) |x| lit = lit or pixels[y * width + x] != 0;
        if (!lit) blank_row = true;
    }

    try std.testing.expect(blank_col);
    try std.testing.expect(blank_row);
}

test "generated braille uses antialiased dots when possible" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x28ff));

    var partial = false;
    for (pixels) |alpha| {
        if (alpha > 0 and alpha < 255) partial = true;
    }
    try std.testing.expect(partial);
}

test "generated special raster draws powerline triangle" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b0));
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit > pixels.len / 4);
    try std.testing.expect(pixels[0] < 128);
}

test "generated special raster draws powerline separator" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b1));
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < pixels.len / 2);
}

test "generated special raster draws cubic powerline D" {
    const width = 16;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b4));
    try std.testing.expect(pixels[(height / 2) * width] != 0);
    try std.testing.expect(pixels[(height / 2) * width + width - 2] != 0);
    try std.testing.expect(pixels[(height - 1) * width] != 0);
    try std.testing.expect(pixels[width - 1] < 255);
    var partial_alpha = false;
    for (pixels) |alpha| {
        if (alpha > 0 and alpha < 255) partial_alpha = true;
    }
    try std.testing.expect(partial_alpha);
}

test "generated special raster draws stroked powerline D" {
    const width = 16;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b5));
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < pixels.len / 2);
}

test "generated special raster draws eighth block" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2581));
    var top_lit: usize = 0;
    var bottom_lit: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (y < height / 2) top_lit += 1 else bottom_lit += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), top_lit);
    try std.testing.expect(bottom_lit > 0);
}

test "generated special raster draws quadrant block" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2598));
    try std.testing.expect(pixels[0] != 0);
    try std.testing.expectEqual(@as(u8, 0), pixels[width - 1]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(height - 1) * width]);
}

test "generated special raster distributes eighth blocks" {
    const width = 10;
    const height = 8;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2595));
    var left_lit: usize = 0;
    var right_lit: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (x < width - 1) left_lit += 1 else right_lit += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), left_lit);
    try std.testing.expectEqual(@as(usize, height), right_lit);
}

test "generated special raster uses uniform shade intensity" {
    const width = 13;
    const height = 13;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2592));
    for (pixels) |alpha| {
        try std.testing.expectEqual(@as(u8, 0x80), alpha);
    }
}

test "generated special raster draws sextants" {
    const width = 8;
    const height = 15;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fb00));
    var top_left: usize = 0;
    var top_right: usize = 0;
    var lower_rows: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (y < height / 3 and x < width / 2) top_left += 1;
            if (y < height / 3 and x >= width / 2) top_right += 1;
            if (y >= height / 3) lower_rows += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(usize, 0), top_right);
    try std.testing.expectEqual(@as(usize, 0), lower_rows);
}

test "generated special raster draws upper-range sextant mapping" {
    const width = 8;
    const height = 15;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fb14));
    var top_right: usize = 0;
    var middle_rows: usize = 0;
    var bottom_left: usize = 0;
    var bottom_right: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (y < height / 3 and x >= width / 2) top_right += 1;
            if (y >= height / 3 and y < height * 2 / 3) middle_rows += 1;
            if (y >= height * 2 / 3 and x < width / 2) bottom_left += 1;
            if (y >= height * 2 / 3 and x >= width / 2) bottom_right += 1;
        }
    }
    try std.testing.expect(top_right > 0);
    try std.testing.expect(middle_rows > 0);
    try std.testing.expect(bottom_left > 0);
    try std.testing.expectEqual(@as(usize, 0), bottom_right);
}

test "generated special raster draws octants" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1cd00));
    var top_left: usize = 0;
    var rest: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (y >= height / 4 and y < height / 2 and x < width / 2) top_left += 1 else rest += 1;
        }
    }
    try std.testing.expect(top_left > 0);
    try std.testing.expectEqual(@as(usize, 0), rest);
}

test "generated special raster draws terminal octant aliases" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x1fbe6));
    var left_lit: usize = 0;
    var right_lit: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] == 0) continue;
            if (x < width / 2) left_lit += 1 else right_lit += 1;
        }
    }
    try std.testing.expect(left_lit > 0);
    try std.testing.expectEqual(@as(usize, 0), right_lit);
}

test "generated special raster draws box diagonal lines" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2571));
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < pixels.len / 2);
}

test "generated special raster draws double box lines" {
    const width = 12;
    const height = 18;
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&hline, width, height, 0x2550));
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&vline, width, height, 0x2551));

    var h_rows: usize = 0;
    for (0..height) |y| {
        var row_lit = false;
        for (0..width) |x| row_lit = row_lit or hline[y * width + x] != 0;
        if (row_lit) h_rows += 1;
    }
    var v_cols: usize = 0;
    for (0..width) |x| {
        var col_lit = false;
        for (0..height) |y| col_lit = col_lit or vline[y * width + x] != 0;
        if (col_lit) v_cols += 1;
    }

    try std.testing.expect(h_rows >= 2);
    try std.testing.expect(v_cols >= 2);
    try std.testing.expect(hline[(height / 2) * width + width / 2] == 0);
    try std.testing.expect(vline[(height / 2) * width + width / 2] == 0);
}

test "generated special raster draws dashed box lines" {
    const width = 18;
    const height = 18;
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&hline, width, height, 0x2504));
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&vline, width, height, 0x2506));

    var h_lit: usize = 0;
    var h_blank: usize = 0;
    const y = height / 2;
    for (0..width) |x| {
        if (hline[y * width + x] != 0) h_lit += 1 else h_blank += 1;
    }
    var v_lit: usize = 0;
    var v_blank: usize = 0;
    const x = width / 2;
    for (0..height) |yy| {
        if (vline[yy * width + x] != 0) v_lit += 1 else v_blank += 1;
    }

    try std.testing.expect(h_lit > 0 and h_blank > 0);
    try std.testing.expect(v_lit > 0 and v_blank > 0);
}

test "generated box connectors stop at stroke edges" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    const h = centeredRange(height, height / 2, box.light_stroke_px);
    const v = centeredRange(width, width / 2, box.light_stroke_px);

    var top_right = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&top_right, width, height, 0x2510, box));
    try std.testing.expectEqual(@as(u8, 255), top_right[h.start * width + v.start - 1]);
    try std.testing.expectEqual(@as(u8, 255), top_right[h.start * width + v.start]);
    try std.testing.expectEqual(@as(u8, 255), top_right[h.start * width + v.end - 1]);
    try std.testing.expectEqual(@as(u8, 0), top_right[h.start * width + v.end]);

    var bottom_left = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&bottom_left, width, height, 0x2514, box));
    try std.testing.expectEqual(@as(u8, 0), bottom_left[h.start * width + v.start - 1]);
    try std.testing.expectEqual(@as(u8, 255), bottom_left[h.start * width + v.start]);
    try std.testing.expectEqual(@as(u8, 255), bottom_left[h.start * width + v.end]);
}

test "generated tee connectors use centered light joins" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    const h = centeredRange(height, height / 2, box.light_stroke_px);
    const v = centeredRange(width, width / 2, box.light_stroke_px);

    var left_tee = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&left_tee, width, height, 0x251c, box));
    try std.testing.expectEqual(@as(u8, 0), left_tee[h.start * width + v.start - 1]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[h.start * width + v.end - 1]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[h.start * width + width - 1]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[(h.start - 1) * width + v.start]);
    try std.testing.expectEqual(@as(u8, 255), left_tee[h.end * width + v.start]);

    var top_tee = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&top_tee, width, height, 0x252c, box));
    try std.testing.expectEqual(@as(u8, 255), top_tee[h.start * width + v.start - 1]);
    try std.testing.expectEqual(@as(u8, 255), top_tee[h.start * width + v.end]);
    try std.testing.expectEqual(@as(u8, 255), top_tee[h.end * width + v.start]);
    try std.testing.expectEqual(@as(u8, 0), top_tee[(h.start - 1) * width + v.start]);
}

test "generated special raster draws rounded box corners" {
    const width = 18;
    const height = 18;
    const Case = struct {
        cp: u32,
        corner: RoundedCorner,
    };
    const cases = [_]Case{
        .{ .cp = 0x256d, .corner = .top_left },
        .{ .cp = 0x256e, .corner = .top_right },
        .{ .cp = 0x2570, .corner = .bottom_left },
        .{ .cp = 0x256f, .corner = .bottom_right },
    };

    for (cases) |case| {
        var pixels = [_]u8{0} ** (width * height);
        try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, case.cp));
        var lit: usize = 0;
        var partial_alpha = false;
        var expected_quadrant: usize = 0;
        var wrong_outer_quadrant: usize = 0;
        for (0..height) |y| {
            for (0..width) |x| {
                const alpha = pixels[y * width + x];
                if (alpha == 0) continue;
                lit += 1;
                if (alpha < 255) partial_alpha = true;

                const expected = switch (case.corner) {
                    .top_left => x >= width / 2 and y >= height / 2,
                    .top_right => x < width / 2 and y >= height / 2,
                    .bottom_left => x >= width / 2 and y < height / 2,
                    .bottom_right => x < width / 2 and y < height / 2,
                };
                if (expected) expected_quadrant += 1;

                const wrong_outer = switch (case.corner) {
                    .top_left => x < width / 2 and y < height / 2,
                    .top_right => x >= width / 2 and y < height / 2,
                    .bottom_left => x < width / 2 and y >= height / 2,
                    .bottom_right => x >= width / 2 and y >= height / 2,
                };
                if (wrong_outer) wrong_outer_quadrant += 1;
            }
        }

        try std.testing.expect(lit > 0);
        try std.testing.expect(lit < pixels.len / 2);
        try std.testing.expect(partial_alpha);
        try std.testing.expect(expected_quadrant > 0);
        try std.testing.expectEqual(@as(usize, 0), wrong_outer_quadrant);
    }
}

test "generated rounded corners align with straight box arms" {
    const width = 10;
    const height = 20;
    const box = contract.BoxDrawingRasterMetrics{ .light_stroke_px = 2, .heavy_stroke_px = 4 };
    var corner = [_]u8{0} ** (width * height);
    var hline = [_]u8{0} ** (width * height);
    var vline = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&corner, width, height, 0x256d, box));
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&hline, width, height, 0x2500, box));
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&vline, width, height, 0x2502, box));

    var corner_h_rows: usize = 0;
    var hline_rows: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        if (corner[y * width + width - 1] != 0) corner_h_rows += 1;
        if (hline[y * width + width - 1] != 0) hline_rows += 1;
    }

    var corner_v_cols: usize = 0;
    var vline_cols: usize = 0;
    var x: usize = 0;
    while (x < width) : (x += 1) {
        if (corner[(height - 1) * width + x] != 0) corner_v_cols += 1;
        if (vline[(height - 1) * width + x] != 0) vline_cols += 1;
    }

    try std.testing.expectEqual(hline_rows, corner_h_rows);
    try std.testing.expectEqual(vline_cols, corner_v_cols);
}

test "generated rounded corners honor box drawing thickness" {
    const width = 24;
    const height = 24;
    var thin = [_]u8{0} ** (width * height);
    var thick = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&thin, width, height, 0x256d, .{ .light_stroke_px = 1, .heavy_stroke_px = 2 }));
    try std.testing.expect(rasterizeGeneratedSpecialAlphaWithMetrics(&thick, width, height, 0x256d, .{ .light_stroke_px = 4, .heavy_stroke_px = 8 }));

    var thin_lit: usize = 0;
    var thick_lit: usize = 0;
    for (thin) |alpha| {
        if (alpha != 0) thin_lit += 1;
    }
    for (thick) |alpha| {
        if (alpha != 0) thick_lit += 1;
    }
    try std.testing.expect(thick_lit > thin_lit * 2);
}

test "generated special raster draws box crossing diagonals" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0x2573));
    try std.testing.expect(pixels[(height / 2) * width + width / 2] != 0);
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > width);
}

test "generated special raster draws powerline diagonal aliases" {
    const width = 8;
    const height = 16;
    var pixels = [_]u8{0} ** (width * height);
    try std.testing.expect(rasterizeGeneratedSpecialAlpha(&pixels, width, height, 0xe0b9));
    var lit: usize = 0;
    for (pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < pixels.len / 2);
}

test "raster plan creates one output per request" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 5 }, .kind = .emoji };
    const req = requestForGroup(group, .{ .cell_w_px = 10, .cell_h_px = 20, .baseline_px = 15 });
    var plan = try rasterizeRequestsWithRasterizer(std.testing.allocator, defaultRasterizer(), &.{req});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.outputs.len);
    try std.testing.expectEqual(contract.SpriteColorMode.color, plan.outputs[0].color_mode);
    try std.testing.expectEqual(@as(usize, 200), plan.outputs[0].pixels.len);
}

test "pending raster requests dedupe by sprite key" {
    var requests = std.ArrayList(contract.SpriteRasterRequest).empty;
    defer requests.deinit(std.testing.allocator);
    const req = requestForGroup(.{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 5 }, .kind = .normal }, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    try appendPendingRequest(std.testing.allocator, &requests, true, req);
    try appendPendingRequest(std.testing.allocator, &requests, true, req);
    try appendPendingRequest(std.testing.allocator, &requests, false, req);
    try std.testing.expectEqual(@as(usize, 1), requests.items.len);
}

test "raster plan uses injected rasterizer" {
    const Stub = struct {
        hits: usize = 0,

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!RasterSpriteOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return placeholderRaster(allocator, req);
        }
    };
    var stub = Stub{};
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 6 }, .kind = .normal };
    const req = requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    var plan = try rasterizeRequestsWithRasterizer(std.testing.allocator, .{ .ctx = &stub, .rasterize_sprite = Stub.raster }, &.{req});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
}
