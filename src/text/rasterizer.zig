
const std = @import("std");
const contract = @import("../text_contract.zig");
const generated_special_raster = @import("generated_special_raster.zig");
const metrics = @import("metrics.zig");

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
        const row = pixelRowOffset(width_px, @intCast(yy));
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
    const width_px = spriteWidthPx(group.cell_span, cell_metrics.cell_w_px);
    return .{
        .key = group.sprite_key,
        .group = group,
        .placement = group.placement,
        .width_px = width_px,
        .height_px = cell_metrics.cell_h_px,
        .baseline_px = cell_metrics.baseline_px,
        .box_drawing = metrics.boxDrawingRasterMetrics(cell_metrics),
        .color_mode = requestColorMode(group.kind),
    };
}

pub fn appendPendingRequest(
    allocator: std.mem.Allocator,
    requests: *std.ArrayList(contract.SpriteRasterRequest),
    pending: bool,
    req: contract.SpriteRasterRequest,
) !void {
    if (!pending) return;
    std.debug.assert(req.width_px > 0);
    std.debug.assert(req.height_px > 0);
    if (hasRequestKey(requests.items, req.key)) return;
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

pub const requestForUndercurl = generated_special_raster.requestForUndercurl;
pub const rasterizeUndercurlAlpha = generated_special_raster.rasterizeUndercurlAlpha;
pub const rasterizeGeneratedSpecialAlpha = generated_special_raster.rasterizeGeneratedSpecialAlpha;
pub const rasterizeGeneratedSpecialAlphaWithMetrics = generated_special_raster.rasterizeGeneratedSpecialAlphaWithMetrics;

fn spriteWidthPx(cell_span: u8, cell_w_px: u16) u16 {
    std.debug.assert(cell_w_px > 0);
    return @intCast(@as(u32, @max(cell_span, 1)) * @as(u32, cell_w_px));
}

fn requestColorMode(kind: contract.GlyphGroupKind) contract.SpriteColorMode {
    return if (kind == .emoji) .color else .alpha;
}

fn appendUniqueRequest(
    allocator: std.mem.Allocator,
    requests: *std.ArrayList(contract.SpriteRasterRequest),
    req: contract.SpriteRasterRequest,
) !void {
    std.debug.assert(req.width_px > 0);
    std.debug.assert(req.height_px > 0);
    if (hasRequestKey(requests.items, req.key)) return;
    try requests.append(allocator, req);
}

fn hasRequestKey(requests: []const contract.SpriteRasterRequest, key: contract.SpriteKey) bool {
    for (requests) |existing| {
        if (existing.key.value == key.value) return true;
    }
    return false;
}

pub fn placeholderRaster(allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) !RasterSpriteOutput {
    const bytes = pixelCount(req.width_px, req.height_px);
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

    var initialized: u32 = 0;
    errdefer {
        for (outputs[0..initialized]) |*out| out.deinit();
    }

    for (requests, 0..) |req, idx| {
        outputs[idx] = try raster.rasterize(allocator, req);
        initialized += 1;
    }

    return .{ .allocator = allocator, .outputs = outputs };
}

fn pixelRowOffset(width: u16, y: u16) usize {
    return @as(usize, width) * @as(usize, y);
}

fn pixelOffset(width: u16, x: u16, y: u16) usize {
    return pixelRowOffset(width, y) + x;
}

fn pixelCount(width: u16, height: u16) usize {
    return @as(usize, width) * @as(usize, height);
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
