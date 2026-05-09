//! Responsibility: define glyph-group rasterization contracts.
//! Ownership: render-core text engine.
//! Reason: rasterize shaped groups as sprites, not only individual codepoints.

const std = @import("std");
const contract = @import("../text_contract.zig");

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
    pixels: []u8,

    pub fn deinit(self: *RasterSpriteOutput) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const OwnedRasterPlan = struct {
    allocator: std.mem.Allocator,
    outputs: []RasterSpriteOutput,

    pub fn deinit(self: *OwnedRasterPlan) void {
        for (self.outputs) |*out| out.deinit();
        self.allocator.free(self.outputs);
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
        .color_mode = if (group.kind == .emoji) .color else .alpha,
    };
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

/// Rasterizes a Kitty-style cosine undercurl into an alpha mask.
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
    @memset(pixels, 0);
    const width = @max(width_px, 1);
    const height = @max(height_px, 1);
    switch (codepoint) {
        0xe0b0 => rasterizePowerlineTriangle(pixels, width, height, true, false),
        0xe0b2 => rasterizePowerlineTriangle(pixels, width, height, false, false),
        0xe0b1 => rasterizePowerlineHalfDiagonal(pixels, width, height, true),
        0xe0b3 => rasterizePowerlineHalfDiagonal(pixels, width, height, false),
        0xe0b4 => rasterizePowerlineD(pixels, width, height, true, true),
        0xe0b6 => rasterizePowerlineD(pixels, width, height, false, true),
        0xe0b5 => rasterizePowerlineD(pixels, width, height, true, false),
        0xe0b7 => rasterizePowerlineD(pixels, width, height, false, false),
        0xe0b8 => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_left),
        0xe0ba => rasterizePowerlineCornerTriangle(pixels, width, height, .bottom_right),
        0xe0bc => rasterizePowerlineCornerTriangle(pixels, width, height, .top_left),
        0xe0be => rasterizePowerlineCornerTriangle(pixels, width, height, .top_right),
        0x2580...0x259f => rasterizeBlockElementAlpha(pixels, width, height, codepoint),
        0x2800...0x28ff => rasterizeBrailleAlpha(pixels, width, height, @intCast(codepoint - 0x2800)),
        else => return false,
    }
    return true;
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
    const y0: u16 = @intCast(@as(u32, height) * @as(u32, start_eighth) / 8);
    const y1: u16 = @intCast(@as(u32, height) * @as(u32, end_eighth) / 8);
    if (y1 > y0) fillRectAlpha(pixels, width, 0, y0, width, y1 - y0, 255);
}

fn fillCols(pixels: []u8, width: u16, height: u16, start_eighth: u16, end_eighth: u16) void {
    const x0: u16 = @intCast(@as(u32, width) * @as(u32, start_eighth) / 8);
    const x1: u16 = @intCast(@as(u32, width) * @as(u32, end_eighth) / 8);
    if (x1 > x0) fillRectAlpha(pixels, width, x0, 0, x1 - x0, height, 255);
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
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const pattern = (x + y * 3) % 4;
            const draw = switch (density) {
                .light => pattern == 0,
                .medium => pattern == 0 or pattern == 2,
                .dark => pattern != 1,
            };
            if (draw) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = 255;
        }
    }
}

fn rasterizePowerlineTriangle(pixels: []u8, width: u16, height: u16, left: bool, inverted: bool) void {
    const x1: f64 = if (left) 0 else @floatFromInt(width - 1);
    const x2: f64 = if (left) @floatFromInt(width - 1) else 0;
    const y_mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const yf = @as(f64, @floatFromInt(y)) + 0.5;
            const xf = @as(f64, @floatFromInt(x)) + 0.5;
            const upper = lineY(x1, 0, x2, y_mid, xf);
            const lower = lineY(x1, @floatFromInt(height - 1), x2, y_mid, xf);
            const inside = yf >= upper and yf <= lower;
            if (inside != inverted) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = 255;
        }
    }
}

fn rasterizePowerlineHalfDiagonal(pixels: []u8, width: u16, height: u16, left: bool) void {
    const mid = @as(f64, @floatFromInt(height - 1)) / 2.0;
    const line_w = @as(f64, @floatFromInt(@max(height / 12, 1)));
    if (left) {
        drawLineAlpha(pixels, width, height, 0, 0, @floatFromInt(width - 1), mid, line_w);
        drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), mid, 0, @floatFromInt(height - 1), line_w);
    } else {
        drawLineAlpha(pixels, width, height, @floatFromInt(width - 1), 0, 0, mid, line_w);
        drawLineAlpha(pixels, width, height, 0, mid, @floatFromInt(width - 1), @floatFromInt(height - 1), line_w);
    }
}

fn rasterizePowerlineD(pixels: []u8, width: u16, height: u16, left: bool, filled: bool) void {
    if (filled) {
        rasterizePowerlineFilledD(pixels, width, height, left);
    } else {
        rasterizePowerlineRoundedD(pixels, width, height, left);
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
    const cb = CubicBezier{
        .start = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = @floatFromInt(max_x), .y = 0 },
        .c2 = .{ .x = @floatFromInt(max_x), .y = @floatFromInt(height - 1) },
        .end = .{ .x = 0, .y = @floatFromInt(height - 1) },
    };

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const sx: u16 = if (left) x else width - 1 - x;
            const t = findBezierTForX(cb, @floatFromInt(sx));
            if (bezierX(cb, t) > @as(f64, @floatFromInt(width - 1)) + 0.5) continue;
            const upper = bezierY(cb, t);
            const lower = bezierY(cb, 1.0 - t);
            const yf = @as(f64, @floatFromInt(y)) + 0.5;
            if (yf >= upper and yf <= lower) pixels[@as(usize, y) * @as(usize, width) + @as(usize, x)] = 255;
        }
    }
}

fn rasterizePowerlineRoundedD(pixels: []u8, width: u16, height: u16, left: bool) void {
    const gap = @max(height / 12, 1);
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
    var x_gaps: [4]u16 = undefined;
    var y_gaps: [8]u16 = undefined;
    const dot_w = distributeDots(width, 2, x_gaps[0..2], x_gaps[2..4]);
    const dot_h = distributeDots(height, 4, y_gaps[0..4], y_gaps[4..8]);
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
        const x = x_gaps[col] + col * dot_w;
        const y = y_gaps[row] + row * dot_h;
        fillRectAlpha(pixels, width, x, y, @min(dot_w, width - x), @min(dot_h, height - y), 255);
    }
}

fn distributeDots(available_space: u16, dot_count: u16, summed_gaps: []u16, gaps: []u16) u16 {
    const count = @max(dot_count, 1);
    const dot_size: u16 = @max(1, available_space / (2 * count));
    var extra = if (available_space > 2 * count * dot_size) available_space - 2 * count * dot_size else 0;
    for (gaps[0..count]) |*gap| gap.* = dot_size;
    var idx: usize = 0;
    while (extra > 0) : (extra -= 1) {
        gaps[idx] += 1;
        idx = (idx + 1) % count;
    }
    gaps[0] /= 2;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var sum: u16 = 0;
        var j: usize = 0;
        while (j <= i) : (j += 1) sum += gaps[j];
        summed_gaps[i] = sum;
    }
    return dot_size;
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

pub fn rasterizeRequests(allocator: std.mem.Allocator, requests: []const contract.SpriteRasterRequest) !OwnedRasterPlan {
    return rasterizeRequestsWithRasterizer(allocator, defaultRasterizer(), requests);
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
    var out = try placeholderRaster(std.testing.allocator, req);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 16 * 16), out.pixels.len);
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
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
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
    try std.testing.expectEqual(@as(u8, 0), pixels[width - 1]);
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
    try std.testing.expect(lit < pixels.len / 3);
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

test "raster plan creates one output per request" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 5 }, .kind = .emoji };
    const req = requestForGroup(group, .{ .cell_w_px = 10, .cell_h_px = 20, .baseline_px = 15 });
    var plan = try rasterizeRequests(std.testing.allocator, &.{req});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.outputs.len);
    try std.testing.expectEqual(contract.SpriteColorMode.color, plan.outputs[0].color_mode);
    try std.testing.expectEqual(@as(usize, 200), plan.outputs[0].pixels.len);
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
