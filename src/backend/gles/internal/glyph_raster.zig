const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../../render.zig").Render;
const provider_mod = @import("provider.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

const FtFace = c_api.FtFace;
const HbFont = c_api.HbFont;
const PixelIndex = @TypeOf(@as([]const u8, &.{}).len);

pub const ResolvedGlyphKey = struct {
    codepoint: u21,
    face_id: u32,
    glyph_id: u32,
};

fn lockFt(self: anytype) void {
    self.ft_mutex.lock();
}

fn unlockFt(self: anytype) void {
    self.ft_mutex.unlock();
}

pub fn providerRasterizeSprite(
    comptime Backend: type,
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: render.SpriteRasterRequest,
) anyerror!render.Text.Rasterizer.RasterSpriteOutput {
    const backend: *Backend = @ptrCast(@alignCast(ctx));
    const width = @max(req.width_px, 1);
    const height = @max(req.height_px, 1);
    const pixels = try allocator.alloc(u8, rasterPixelCount(width, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    if (tryRasterizeProviderSpecialCase(backend, pixels, width, height, req)) {
        return providerSpriteOutput(allocator, req, width, height, pixels);
    }

    var pen_x: f32 = 0;
    for (req.group.glyphs, 0..) |glyph, glyph_idx| {
        const x_px = @as(i32, @intFromFloat(std.math.floor(pen_x + glyph.x_offset_px)));
        const y_px = @as(i32, @intFromFloat(std.math.floor(glyph.y_offset_px)));
        _ = rasterizeProviderGlyph(backend, pixels, width, height, req.baseline_px, glyph.face_id, glyph.glyph_id, x_px, y_px, @intCast(glyph_idx));
        pen_x += glyph.x_advance_px;
    }

    return providerSpriteOutput(allocator, req, width, height, pixels);
}

pub fn rasterizeProviderGlyph(self: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face_id: render.FontFaceId, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (useDeterministicTestTextFallback(self)) {
        rasterizeFallbackGlyph(dst, width, height, @intCast(glyph_id), width, height);
        return true;
    }
    if (!provider_mod.ensureFont(self)) return false;
    lockFt(self);
    defer unlockFt(self);
    const shaped_face = provider_mod.acquireShapingFaceLocked(self, face_id) orelse return false;
    return rasterizeProviderGlyphFromFace(self, dst, width, height, baseline_px, shaped_face.face, glyph_id, x_origin_px, y_origin_px, glyph_index);
}

fn rasterizeProviderGlyphFromFace(_: anytype, dst: []u8, width: u16, height: u16, baseline_px: i16, face: FtFace, glyph_id: u32, x_origin_px: i32, y_origin_px: i32, glyph_index: u32) bool {
    if (glyph_id == 0) return false;
    if (c.FT_Load_Glyph(face, glyph_id, c.FT_LOAD_RENDER) != 0) return false;
    const glyph = face.*.glyph;
    if (glyph == null) return false;
    const bitmap = glyph.*.bitmap;
    if (bitmap.buffer == null or bitmap.width <= 0 or bitmap.rows <= 0) return false;
    const bw: u16 = @intCast(bitmap.width);
    const bh: u16 = @intCast(bitmap.rows);
    const visual_w = bitmapVisualWidth(bitmap.pixel_mode, bw);
    const visual_h = bitmapVisualHeight(bitmap.pixel_mode, bh);
    const pitch_abs: u16 = @intCast(@abs(bitmap.pitch));
    const pitch_is_negative = bitmap.pitch < 0;
    const baseline: i32 = if (baseline_px > 0) baseline_px else provider_mod.computeBaselineFromFace(face, height);
    const origin = cellBitmapOrigin(width, baseline, glyph.*.bitmap_left, glyph.*.bitmap_top, visual_w, x_origin_px, y_origin_px, glyph_index);

    for (0..visual_h) |yy| {
        for (0..visual_w) |xx| {
            const dx_i = origin.x_px + @as(i32, @intCast(xx));
            const dy_i = origin.y_px + @as(i32, @intCast(yy));
            if (dx_i < 0 or dy_i < 0) continue;
            const dx: u16 = @intCast(dx_i);
            const dy: u16 = @intCast(dy_i);
            if (dx >= width or dy >= height) continue;
            dst[rasterPixelOffset(width, dx, dy)] = bitmapAlpha(
                bitmap.buffer[0 .. @as(PixelIndex, pitch_abs) * @as(PixelIndex, bh)],
                bitmap.pixel_mode,
                pitch_abs,
                pitch_is_negative,
                bw,
                bh,
                @as(u16, @intCast(xx)),
                @as(u16, @intCast(yy)),
            );
        }
    }
    return true;
}

fn tryRasterizeProviderSpecialCase(backend: anytype, pixels: []u8, width: u16, height: u16, req: render.SpriteRasterRequest) bool {
    if (req.kind == .undercurl) {
        render.Text.Rasterizer.rasterizeUndercurlAlpha(pixels, width, height, req.decoration);
        return true;
    }
    if (req.group.kind == .box_fallback) {
        if (!render.Text.Rasterizer.rasterizeGeneratedSpecialAlphaWithMetrics(pixels, width, height, req.group.first_cp, req.box_drawing)) {
            rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
        }
        return true;
    }
    if (!useDeterministicTestTextFallback(backend)) return false;
    rasterizeFallbackGlyph(pixels, width, height, @intCast(req.group.first_cp), width, height);
    return true;
}

fn providerSpriteOutput(
    allocator: std.mem.Allocator,
    req: render.SpriteRasterRequest,
    width: u16,
    height: u16,
    pixels: []u8,
) render.Text.Rasterizer.RasterSpriteOutput {
    return .{ .allocator = allocator, .key = req.key, .width_px = width, .height_px = height, .color_mode = req.color_mode, .pixels = pixels };
}

fn rasterPixelCount(width: u16, height: u16) PixelIndex {
    return @as(PixelIndex, width) * @as(PixelIndex, height);
}

fn rasterPixelOffset(width: u16, x: u16, y: u16) PixelIndex {
    return @as(PixelIndex, y) * @as(PixelIndex, width) + x;
}

fn bitmapVisualWidth(pixel_mode: anytype, bitmap_width: u16) u16 {
    return switch (pixelModeValue(pixel_mode)) {
        5 => @max(bitmap_width / 3, 1),
        else => bitmap_width,
    };
}

fn bitmapVisualHeight(pixel_mode: anytype, bitmap_height: u16) u16 {
    return switch (pixelModeValue(pixel_mode)) {
        6 => @max(bitmap_height / 3, 1),
        else => bitmap_height,
    };
}

fn bitmapAlpha(buffer: []const u8, pixel_mode: anytype, pitch_abs: u16, pitch_is_negative: bool, bitmap_width: u16, bitmap_height: u16, x: u16, y: u16) u8 {
    _ = bitmap_width;
    const src_y = switch (pixelModeValue(pixel_mode)) {
        6 => @min(y * 3, bitmap_height - 1),
        else => y,
    };
    const row_y = if (pitch_is_negative) bitmap_height - 1 - src_y else src_y;
    const row = buffer[@as(PixelIndex, row_y) * @as(PixelIndex, pitch_abs) ..][0..pitch_abs];
    return switch (pixelModeValue(pixel_mode)) {
        1 => if ((row[x / 8] & (@as(u8, 0x80) >> @intCast(x & 7))) != 0) 255 else 0,
        2 => row[x],
        3 => unpackPackedGray(row, x, 2),
        4 => unpackPackedGray(row, x, 4),
        5 => average3(row, @as(PixelIndex, x) * 3),
        6 => average3(row, x),
        7 => row[x * 4 + 3],
        else => row[x],
    };
}

fn unpackPackedGray(row: []const u8, x: u16, bits: u3) u8 {
    const per_byte = 8 / @as(PixelIndex, bits);
    const idx = @as(PixelIndex, x);
    const shift: u3 = @intCast(8 - @as(PixelIndex, bits) - (idx % per_byte) * @as(PixelIndex, bits));
    const mask: u8 = (@as(u8, 1) << bits) - 1;
    const value = (row[idx / per_byte] >> shift) & mask;
    return @intCast((@as(u16, value) * 255) / @as(u16, mask));
}

fn average3(row: []const u8, off: PixelIndex) u8 {
    if (off + 2 >= row.len) return 0;
    return @intCast((@as(u16, row[off]) + @as(u16, row[off + 1]) + @as(u16, row[off + 2])) / 3);
}

fn pixelModeValue(pixel_mode: anytype) u32 {
    const T = @TypeOf(pixel_mode);
    return switch (@typeInfo(T)) {
        .@"enum" => @intFromEnum(pixel_mode),
        else => @intCast(pixel_mode),
    };
}

test "gles provider decodes packed monochrome bitmap alpha" {
    const row = [_]u8{0b1010_0000};
    try std.testing.expectEqual(@as(u8, 255), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 1, 0));
    try std.testing.expectEqual(@as(u8, 255), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 2, 0));
    try std.testing.expectEqual(@as(u8, 0), bitmapAlpha(&row, @as(u8, 1), 1, false, 4, 1, 3, 0));
}

fn cellBitmapOrigin(cell_width: u16, baseline: i32, bitmap_left: i32, bitmap_top: i32, bitmap_width: u16, x_offset: i32, y_offset: i32, glyph_index: u32) struct { x_px: i32, y_px: i32 } {
    var x_px = x_offset + bitmap_left;
    if (glyph_index < 4 and x_px > 0 and x_px + @as(i32, @intCast(bitmap_width)) > @as(i32, @intCast(cell_width))) {
        const extra = x_px + @as(i32, @intCast(bitmap_width)) - @as(i32, @intCast(cell_width));
        x_px = if (extra > x_px) 0 else x_px - extra;
    }
    const yoff = y_offset + bitmap_top;
    const y_px = if (yoff > 0 and yoff > baseline) 0 else baseline - yoff;
    return .{ .x_px = x_px, .y_px = y_px };
}

fn rasterizeFallbackGlyph(dst: []u8, cell_w: u16, cell_h: u16, codepoint: u21, gw: u16, gh: u16) void {
    render.Text.Fallback.rasterAsciiOrPlaceholder(dst, cell_w, codepoint, gw, gh);
    _ = cell_h;
}

fn useDeterministicTestTextFallback(self: anytype) bool {
    return builtin.is_test and self.config.font_path == null and self.fallback_font_paths_len == 0;
}
