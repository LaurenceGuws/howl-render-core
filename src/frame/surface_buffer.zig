const std = @import("std");
const Render = @import("../howl_render.zig");
const surface_text = @import("surface_text.zig");

pub fn compose(
    allocator: std.mem.Allocator,
    session: *surface_text.SurfaceText,
    prepared: *const Render.PreparedSurface,
) ![]u8 {
    const width = prepared.render_px.width;
    const height = prepared.render_px.height;
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    const pixels_len: u32 = @as(u32, width) * @as(u32, height) * 4;
    const pixels = try allocator.alloc(u8, @intCast(pixels_len));
    errdefer allocator.free(pixels);
    std.debug.assert(pixels.len == pixels_len);
    clearSurfacePixels(pixels);
    drawColorSpan(
        pixels,
        width,
        height,
        prepared.text_frame.scene.scene.clear_draws,
    );
    drawColorSpan(
        pixels,
        width,
        height,
        prepared.text_frame.scene.scene.background_draws,
    );
    drawDecorationSpan(
        pixels,
        width,
        height,
        prepared.text_frame.scene.scene.decoration_draws,
    );
    try drawSprites(pixels, width, height, session, prepared);
    drawColorSpan(
        pixels,
        width,
        height,
        prepared.text_frame.scene.scene.cursor_draws,
    );
    return pixels;
}

const SpriteRaster = struct {
    pixels: []const u8,
    stride: u16,
    color_mode: Render.SpriteColorMode,
    visual_bounds: Render.Text.Rasterizer.SpriteBounds,
};

fn clearSurfacePixels(pixels: []u8) void {
    var i: u32 = 0;
    const limit: u32 = @intCast(pixels.len);
    while (i + 3 < limit) : (i += 4) {
        pixels[@intCast(i)] = 0;
        pixels[@intCast(i + 1)] = 0;
        pixels[@intCast(i + 2)] = 0;
        pixels[@intCast(i + 3)] = 255;
    }
}

fn drawColorSpan(
    pixels: []u8,
    width: u16,
    height: u16,
    span: anytype,
) void {
    for (span) |draw| {
        drawSolidRect(
            pixels,
            width,
            height,
            draw.x_px,
            draw.y_px,
            draw.width_px,
            draw.height_px,
            draw.color,
        );
    }
}

fn drawDecorationSpan(
    pixels: []u8,
    width: u16,
    height: u16,
    span: []const Render.TextDecorationDraw,
) void {
    for (span) |draw| {
        drawSolidRect(
            pixels,
            width,
            height,
            draw.x_px,
            draw.y_px,
            draw.width_px,
            draw.height_px,
            draw.color,
        );
    }
}

fn drawSprites(
    pixels: []u8,
    width: u16,
    height: u16,
    session: *surface_text.SurfaceText,
    prepared: *const Render.PreparedSurface,
) !void {
    for (prepared.text_frame.scene.scene.sprite_draws) |draw| {
        const sprite = try lookupSprite(session, prepared, draw.sprite.key);
        drawSpriteInstance(pixels, width, height, draw, sprite);
    }
}

fn lookupSprite(
    session: *surface_text.SurfaceText,
    prepared: *const Render.PreparedSurface,
    sprite_key: Render.SpriteKey,
) !SpriteRaster {
    for (prepared.text_frame.raster_plan.outputs) |output| {
        if (output.key.value != sprite_key.value) continue;
        const bounds = output.visualBounds();
        std.debug.assert(output.pixels.len >= packedStrideForOutput(output) * output.height_px);
        return .{
            .pixels = output.pixels,
            .stride = packedStrideForOutput(output),
            .color_mode = output.color_mode,
            .visual_bounds = bounds,
        };
    }
    const cached = session.atlasRaster(sprite_key) orelse return error.MissingSprite;
    const stride: u16 = switch (cached.color_mode) {
        .alpha => cached.width_px,
        .color => @intCast(@as(u32, cached.width_px) * 4),
    };
    std.debug.assert(cached.pixels.len >= @as(u32, stride) * cached.height_px);
    return .{
        .pixels = cached.pixels,
        .stride = stride,
        .color_mode = cached.color_mode,
        .visual_bounds = cached.visual_bounds,
    };
}

fn packedStrideForOutput(output: Render.Text.Rasterizer.RasterSpriteOutput) u16 {
    const channels: u16 = switch (output.color_mode) {
        .alpha => 1,
        .color => 4,
    };
    return @intCast(@as(u32, output.width_px) * @as(u32, channels));
}

fn drawSpriteInstance(
    pixels: []u8,
    width: u16,
    height: u16,
    draw: Render.TextSpriteDraw,
    sprite: SpriteRaster,
) void {
    const bounds = if (sprite.visual_bounds.width_px != 0 and
        sprite.visual_bounds.height_px != 0)
        sprite.visual_bounds
    else
        Render.Text.Rasterizer.SpriteBounds{
            .x_px = 0,
            .y_px = 0,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
        };
    const dst_origin_x = draw.x_px + bounds.x_px;
    const dst_origin_y = draw.y_px + bounds.y_px;
    const max_w = @min(draw.width_px, bounds.width_px);
    const max_h = @min(draw.height_px, bounds.height_px);
    std.debug.assert(bounds.x_px + max_w <= sprite.stride);
    var yy: u16 = 0;
    while (yy < max_h) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < max_w) : (xx += 1) {
            const dst_x = dst_origin_x + @as(i32, xx);
            const dst_y = dst_origin_y + @as(i32, yy);
            if (dst_x < 0 or dst_y < 0) continue;
            if (dst_x >= @as(i32, width) or dst_y >= @as(i32, height)) continue;
            const src_x = bounds.x_px + xx;
            const src_y = bounds.y_px + yy;
            const src_index = spriteIndex(sprite, src_x, src_y);
            const dst_index: u32 = (
                @as(u32, @intCast(dst_y)) * @as(u32, width) + @as(u32, @intCast(dst_x))
            ) * 4;
            switch (sprite.color_mode) {
                .alpha => {
                    if (src_index >= sprite.pixels.len) continue;
                    const alpha = sprite.pixels[@intCast(src_index)];
                    if (alpha == 0) continue;
                    const out_alpha: u8 = @intCast(
                        (@as(u16, draw.color.a) * @as(u16, alpha)) / 255,
                    );
                    blendPixel(
                        pixels,
                        dst_index,
                        draw.color.r,
                        draw.color.g,
                        draw.color.b,
                        out_alpha,
                    );
                },
                .color => {
                    if (src_index + 3 >= sprite.pixels.len) continue;
                    blendPixel(
                        pixels,
                        dst_index,
                        sprite.pixels[@intCast(src_index)],
                        sprite.pixels[@intCast(src_index + 1)],
                        sprite.pixels[@intCast(src_index + 2)],
                        sprite.pixels[@intCast(src_index + 3)],
                    );
                },
            }
        }
    }
}

fn spriteIndex(sprite: SpriteRaster, src_x: u16, src_y: u16) u32 {
    const row_offset = @as(u32, src_y) * @as(u32, sprite.stride);
    return switch (sprite.color_mode) {
        .alpha => row_offset + src_x,
        .color => row_offset + @as(u32, src_x) * 4,
    };
}

fn drawSolidRect(
    pixels: []u8,
    width: u16,
    height: u16,
    x: i32,
    y: i32,
    rect_w: u16,
    rect_h: u16,
    color: Render.Rgba8,
) void {
    var yy: u16 = 0;
    while (yy < rect_h) : (yy += 1) {
        const dst_y = y + @as(i32, yy);
        if (dst_y < 0 or dst_y >= @as(i32, height)) continue;
        var xx: u16 = 0;
        while (xx < rect_w) : (xx += 1) {
            const dst_x = x + @as(i32, xx);
            if (dst_x < 0 or dst_x >= @as(i32, width)) continue;
            const dst_index: u32 = (
                @as(u32, @intCast(dst_y)) * @as(u32, width) + @as(u32, @intCast(dst_x))
            ) * 4;
            blendPixel(pixels, dst_index, color.r, color.g, color.b, color.a);
        }
    }
}

fn blendPixel(pixels: []u8, dst_index: u32, r: u8, g: u8, b: u8, a: u8) void {
    const limit: u32 = @intCast(pixels.len);
    if (dst_index + 3 >= limit) return;
    const src_a: u32 = a;
    const inv_a: u32 = 255 - src_a;
    pixels[@intCast(dst_index)] = @intCast(
        (@as(u32, r) * src_a + @as(u32, pixels[@intCast(dst_index)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 1)] = @intCast(
        (@as(u32, g) * src_a + @as(u32, pixels[@intCast(dst_index + 1)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 2)] = @intCast(
        (@as(u32, b) * src_a + @as(u32, pixels[@intCast(dst_index + 2)]) * inv_a) / 255,
    );
    pixels[@intCast(dst_index + 3)] = @intCast(@min(
        @as(u32, 255),
        src_a + (@as(u32, pixels[@intCast(dst_index + 3)]) * inv_a) / 255,
    ));
}
