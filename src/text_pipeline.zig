//! Responsibility: deterministic resolver/shaper pipeline contract types.
//! Ownership: render-core text pipeline API boundary.
//! Reason: force one explicit resolver order across render variants.

const std = @import("std");
const contract = @import("text_contract.zig");

pub const ResolveStage = enum(u4) {
    style_policy,
    codepoint_override,
    sprite_route,
    loaded_exact_match,
    regular_style_retry,
    discovery_fallback,
    regular_any_presentation,
    missing_glyph,
};

pub const ResolveRequest = struct {
    codepoint: u32,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
};

pub const ResolveHit = struct {
    stage: ResolveStage,
    face_id: u32,
    glyph_id: u32,
};

pub const ResolveMiss = struct {
    stage: ResolveStage,
    missing: contract.MissingGlyph,
};

pub const ResolveResult = union(enum) {
    hit: ResolveHit,
    miss: ResolveMiss,
};

pub const ResolveCounters = struct {
    missing_glyphs: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    shaped_clusters: u64 = 0,
};

pub const ShapeRequest = struct {
    clusters: []const contract.TextCluster,
    font_metrics: contract.FontMetrics,
    cell_metrics: contract.CellMetrics,
};

pub const ShapeOutput = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ShapedRun,
    glyphs: []contract.ShapedGlyph,
    missing: []contract.MissingGlyph,

    pub fn deinit(self: *ShapeOutput) void {
        self.allocator.free(self.runs);
        self.allocator.free(self.glyphs);
        self.allocator.free(self.missing);
        self.* = undefined;
    }
};

pub const RasterizeRequest = struct {
    face_id: u32,
    glyph_id: u32,
    atlas_key: u64,
    cell_metrics: contract.CellMetrics,
};

pub const RasterizeOutput = struct {
    allocator: std.mem.Allocator,
    width_px: u16,
    height_px: u16,
    bearing_x_px: i16,
    bearing_y_px: i16,
    advance_px: f32,
    alpha_mask: []u8,

    pub fn deinit(self: *RasterizeOutput) void {
        self.allocator.free(self.alpha_mask);
        self.* = undefined;
    }
};

pub const ShapeClustersFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput;
pub const RasterizeGlyphFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput;
pub const ResolveFallbackFaceFn = *const fn (ctx: *anyopaque, req: ResolveRequest) ResolveResult;

pub const ShapeClustersOp = struct {
    ctx: *anyopaque,
    call: ShapeClustersFn,

    pub fn shape(self: ShapeClustersOp, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

pub const RasterizeGlyphOp = struct {
    ctx: *anyopaque,
    call: RasterizeGlyphFn,

    pub fn rasterize(self: RasterizeGlyphOp, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

pub const ResolveFallbackFaceOp = struct {
    ctx: *anyopaque,
    call: ResolveFallbackFaceFn,

    pub fn resolve(self: ResolveFallbackFaceOp, req: ResolveRequest) ResolveResult {
        return self.call(self.ctx, req);
    }
};

test "text pipeline ops dispatch and own output buffers" {
    const allocator = std.testing.allocator;

    const Stub = struct {
        hits: usize = 0,

        fn shape(ctx: *anyopaque, gpa: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;

            const glyphs = try gpa.alloc(contract.ShapedGlyph, 1);
            glyphs[0] = .{
                .glyph_id = req.clusters[0].first_cp,
                .atlas_key = 123,
                .x_offset_px = 0,
                .y_offset_px = 0,
                .x_advance_px = @floatFromInt(req.cell_metrics.cell_w_px),
                .face_id = 7,
            };
            const runs = try gpa.alloc(contract.ShapedRun, 1);
            runs[0] = .{
                .cluster_start = 0,
                .cluster_count = @intCast(req.clusters.len),
                .glyphs = glyphs,
            };

            return .{
                .allocator = gpa,
                .runs = runs,
                .glyphs = glyphs,
                .missing = try gpa.alloc(contract.MissingGlyph, 0),
            };
        }

        fn rasterize(ctx: *anyopaque, gpa: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;

            const area = @as(usize, req.cell_metrics.cell_w_px) * @as(usize, req.cell_metrics.cell_h_px);
            const alpha = try gpa.alloc(u8, area);
            @memset(alpha, 0x7f);
            return .{
                .allocator = gpa,
                .width_px = req.cell_metrics.cell_w_px,
                .height_px = req.cell_metrics.cell_h_px,
                .bearing_x_px = 0,
                .bearing_y_px = 0,
                .advance_px = @floatFromInt(req.cell_metrics.cell_w_px),
                .alpha_mask = alpha,
            };
        }

        fn resolve(ctx: *anyopaque, req: ResolveRequest) ResolveResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return .{ .hit = .{
                .stage = if (req.style == .regular) .loaded_exact_match else .regular_style_retry,
                .face_id = 42,
                .glyph_id = req.codepoint,
            } };
        }
    };

    var stub = Stub{};
    const shape_op = ShapeClustersOp{ .ctx = &stub, .call = Stub.shape };
    const raster_op = RasterizeGlyphOp{ .ctx = &stub, .call = Stub.rasterize };
    const resolve_op = ResolveFallbackFaceOp{ .ctx = &stub, .call = Stub.resolve };

    const req = ShapeRequest{
        .clusters = &.{.{ .grapheme_utf8 = "A", .first_cp = 'A' }},
        .font_metrics = .{
            .ascent_px = 10,
            .descent_px = 3,
            .line_gap_px = 2,
            .underline_pos_px = 1,
            .underline_thickness_px = 1,
        },
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    };

    var shaped = try shape_op.shape(allocator, req);
    defer shaped.deinit();
    try std.testing.expectEqual(@as(usize, 1), shaped.runs.len);
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
    try std.testing.expectEqual(@as(u32, 'A'), shaped.glyphs[0].glyph_id);

    var raster = try raster_op.rasterize(allocator, .{
        .face_id = 7,
        .glyph_id = shaped.glyphs[0].glyph_id,
        .atlas_key = shaped.glyphs[0].atlas_key,
        .cell_metrics = req.cell_metrics,
    });
    defer raster.deinit();
    try std.testing.expectEqual(@as(usize, 8 * 16), raster.alpha_mask.len);
    try std.testing.expectEqual(@as(u8, 0x7f), raster.alpha_mask[0]);

    const resolved = resolve_op.resolve(.{
        .codepoint = 'A',
        .style = .bold,
        .presentation = .any,
    });
    switch (resolved) {
        .hit => |hit| {
            try std.testing.expectEqual(.regular_style_retry, hit.stage);
            try std.testing.expectEqual(@as(u32, 42), hit.face_id);
        },
        .miss => return error.UnexpectedResolveMiss,
    }

    try std.testing.expectEqual(@as(usize, 3), stub.hits);
}
