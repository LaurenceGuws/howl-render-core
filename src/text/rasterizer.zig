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
    if (codepoint < 0x2800 or codepoint > 0x28ff) return false;
    @memset(pixels, 0);
    rasterizeBrailleAlpha(pixels, @max(width_px, 1), @max(height_px, 1), @intCast(codepoint - 0x2800));
    return true;
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
    try std.testing.expect(!rasterizeGeneratedSpecialAlpha(&pixels, width, height, 'A'));
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
