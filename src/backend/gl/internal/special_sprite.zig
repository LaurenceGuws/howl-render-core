
const std = @import("std");
const render = @import("../../../render.zig").Render;

const AlphaSegment = enum { full, left, right, top, bottom };
const AlphaCorner = enum { top_left, top_right, bottom_left, bottom_right };
const PointF = struct { x: f64, y: f64 };

pub fn rasterizeSpecialSpriteAlpha(dst: []u8, width: u16, height: u16, codepoint: u32) void {
    const w = @max(width, 1);
    const h = @max(height, 1);
    const th_h: u16 = @max(1, h / 8);
    const th_v: u16 = th_h;
    switch (codepoint) {
        0x2500, 0x2501, 0x2574, 0x2576 => drawAlphaH(dst, w, h, th_h, .full),
        0x2502, 0x2503, 0x2575, 0x2577 => drawAlphaV(dst, w, h, th_v, .full),
        0x250c, 0x250d, 0x250e, 0x250f => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2510, 0x2511, 0x2512, 0x2513 => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2514, 0x2515, 0x2516, 0x2517 => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x2518, 0x2519, 0x251a, 0x251b => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x251c...0x2523 => {
            drawAlphaH(dst, w, h, th_h, .right);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x2524...0x252b => {
            drawAlphaH(dst, w, h, th_h, .left);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x252c...0x2533 => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .bottom);
        },
        0x2534...0x253b => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .top);
        },
        0x253c...0x254b => {
            drawAlphaH(dst, w, h, th_h, .full);
            drawAlphaV(dst, w, h, th_v, .full);
        },
        0x256d => drawAlphaRoundedCorner(dst, w, h, .top_left, @max(th_h, th_v)),
        0x256e => drawAlphaRoundedCorner(dst, w, h, .top_right, @max(th_h, th_v)),
        0x2570 => drawAlphaRoundedCorner(dst, w, h, .bottom_left, @max(th_h, th_v)),
        0x256f => drawAlphaRoundedCorner(dst, w, h, .bottom_right, @max(th_h, th_v)),
        0x2580 => drawAlphaRect(dst, w, 0, 0, w, @max(1, h / 2), 255),
        0x2584 => {
            const hh = @max(1, h / 2);
            drawAlphaRect(dst, w, 0, h - hh, w, hh, 255);
        },
        0x2588 => drawAlphaRect(dst, w, 0, 0, w, h, 255),
        0x258c => drawAlphaRect(dst, w, 0, 0, @max(1, w / 2), h, 255),
        0x2590 => {
            const hw = @max(1, w / 2);
            drawAlphaRect(dst, w, w - hw, 0, hw, h, 255);
        },
        0x2591 => fillAlphaChecker(dst, w, h, 0x33),
        0x2592 => fillAlphaChecker(dst, w, h, 0x77),
        0x2593 => fillAlphaChecker(dst, w, h, 0xbb),
        else => {},
    }
}

pub fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn drawAlphaH(dst: []u8, w: u16, h: u16, t: u16, segment: AlphaSegment) void {
    const y = (h - t) / 2;
    const mid = (w - @min(t, w)) / 2;
    const x: u16 = switch (segment) {
        .full, .top, .bottom => 0,
        .left => 0,
        .right => mid,
    };
    const width: u16 = switch (segment) {
        .full, .top, .bottom => w,
        .left => @max(mid + t, 1),
        .right => w - mid,
    };
    drawAlphaRect(dst, w, x, y, width, t, 255);
}

fn drawAlphaV(dst: []u8, w: u16, h: u16, t: u16, segment: AlphaSegment) void {
    const x = (w - t) / 2;
    const mid = (h - @min(t, h)) / 2;
    const y: u16 = switch (segment) {
        .full, .left, .right => 0,
        .top => 0,
        .bottom => mid,
    };
    const height: u16 = switch (segment) {
        .full, .left, .right => h,
        .top => @max(mid + t, 1),
        .bottom => h - mid,
    };
    drawAlphaRect(dst, w, x, y, t, height, 255);
}

fn drawAlphaRect(dst: []u8, stride: u16, x: u16, y: u16, width: u16, height: u16, alpha: u8) void {
    const stride_usize = @as(usize, stride);
    const x_usize = @as(usize, x);
    const y_usize = @as(usize, y);
    const width_usize = @as(usize, width);
    const height_usize = @as(usize, height);
    std.debug.assert(x_usize + width_usize <= stride_usize);
    std.debug.assert((y_usize + height_usize) * stride_usize <= dst.len);
    for (y..y + height) |yy| {
        const row = yy * stride_usize;
        for (x..x + width) |xx| dst[row + xx] = alpha;
    }
}

fn fillAlphaChecker(target: []u8, width: u16, height: u16, alpha: u8) void {
    std.debug.assert(@as(usize, width) * @as(usize, height) <= target.len);
    for (0..height) |yy| {
        for (0..width) |xx| {
            if (((xx + yy) & 1) == 0) target[yy * @as(usize, width) + xx] = alpha;
        }
    }
}

fn drawAlphaRoundedCorner(dst: []u8, w: u16, h: u16, corner: AlphaCorner, thickness: u16) void {
    const wf = @as(f64, @floatFromInt(w));
    const hf = @as(f64, @floatFromInt(h));
    const mid_x = wf / 2.0;
    const mid_y = hf / 2.0;
    const t = @max(@as(f64, @floatFromInt(thickness)), 1.0);
    const p0 = switch (corner) {
        .top_left, .bottom_left => PointF{ .x = wf, .y = mid_y },
        .top_right, .bottom_right => PointF{ .x = 0.0, .y = mid_y },
    };
    const p1 = PointF{ .x = mid_x, .y = mid_y };
    const p2 = switch (corner) {
        .top_left, .top_right => PointF{ .x = mid_x, .y = hf },
        .bottom_left, .bottom_right => PointF{ .x = mid_x, .y = 0.0 },
    };
    drawAlphaQuadraticStroke(dst, w, h, p0, p1, p2, t);
}

fn drawAlphaQuadraticStroke(dst: []u8, w: u16, h: u16, p0: PointF, p1: PointF, p2: PointF, thickness: f64) void {
    const half = thickness / 2.0;
    const samples = 48;
    for (0..h) |yy| {
        for (0..w) |xx| {
            const px = @as(f64, @floatFromInt(xx)) + 0.5;
            const py = @as(f64, @floatFromInt(yy)) + 0.5;
            var min_d2: f64 = std.math.floatMax(f64);
            var i: usize = 0;
            while (i <= samples) : (i += 1) {
                const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples));
                const inv = 1.0 - u;
                const cx = inv * inv * p0.x + 2.0 * inv * u * p1.x + u * u * p2.x;
                const cy = inv * inv * p0.y + 2.0 * inv * u * p1.y + u * u * p2.y;
                const dx = px - cx;
                const dy = py - cy;
                min_d2 = @min(min_d2, dx * dx + dy * dy);
            }
            const dist = @sqrt(min_d2);
            const coverage = std.math.clamp(half - dist + 0.5, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            const alpha: u8 = @intFromFloat(@round(coverage * 255.0));
            const off = yy * @as(usize, w) + xx;
            dst[off] = @max(dst[off], alpha);
        }
    }
}
