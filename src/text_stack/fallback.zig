//! Responsibility: glyph fallback raster helpers.
//! Ownership: render-core text stack.
//! Reason: keep fallback raster policy consistent across GL/GLES implementations.

const ascii = @import("../ascii8x8.zig");

pub fn rasterAsciiOrPlaceholder(dst: []u8, cell_w: u16, codepoint: u21, gw: u16, gh: u16) void {
    if (codepoint < 128) {
        rasterAscii(dst, cell_w, @intCast(codepoint), gw, gh);
        return;
    }
    rasterPlaceholder(dst, cell_w, gw, gh);
}

fn rasterAscii(dst: []u8, cell_w: u16, codepoint: u8, gw: u16, gh: u16) void {
    const rows = ascii.ascii8x8[codepoint];
    const draw_w: usize = @intCast(@max(gw, 1));
    const draw_h: usize = @intCast(@max(gh, 1));
    for (0..draw_h) |yy| {
        const src_y = (yy * 8) / draw_h;
        const row_bits = rows[src_y];
        for (0..draw_w) |xx| {
            const src_x = (xx * 8) / draw_w;
            const bit = (row_bits >> @as(u3, @intCast(src_x))) & 1;
            if (bit == 0) continue;
            const idx = yy * @as(usize, cell_w) + xx;
            dst[idx] = 255;
        }
    }
}

fn rasterPlaceholder(dst: []u8, cell_w: u16, gw: u16, gh: u16) void {
    const w = @max(gw, 1);
    const h = @max(gh, 1);
    for (0..h) |yy| {
        for (0..w) |xx| {
            const border = xx == 0 or yy == 0 or xx + 1 == w or yy + 1 == h;
            const diagonal = xx == yy or xx + yy + 1 == w;
            const idx = yy * @as(usize, cell_w) + xx;
            dst[idx] = if (border or diagonal) 255 else 0;
        }
    }
}
