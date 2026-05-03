//! Responsibility: own shared fallback raster policy for backend owners.
//! Ownership: render-core text stack.
//! Reason: keep fallback raster policy consistent across GL/GLES implementations.

/// Rasterize the fallback placeholder used for unresolved glyphs.
pub fn rasterAsciiOrPlaceholder(dst: []u8, cell_w: u16, codepoint: u21, gw: u16, gh: u16) void {
    _ = codepoint;
    rasterPlaceholder(dst, cell_w, gw, gh);
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
