//! Responsibility: wrap backend FreeType/HarfBuzz callbacks as TextProvider.
//! Ownership: render text engine boundary.
//! Reason: keep FT/HB integration behind one provider shape while preserving pure render tests.

const std = @import("std");
const contract = @import("../text_contract.zig");
const pipeline = @import("../text_pipeline.zig");
const font_session = @import("font_session.zig");
const provider = @import("provider.zig");
const rasterizer = @import("rasterizer.zig");
const shape_run = @import("shape_run.zig");

pub const HasCodepointFn = *const fn (ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32) bool;

pub const FtHbSource = struct {
    ctx: *anyopaque,
    has_codepoint: HasCodepointFn,
    shaper: shape_run.Shaper = shape_run.defaultShaper(),
    rasterizer: rasterizer.Rasterizer = rasterizer.defaultRasterizer(),
    glyph_lookup: provider.LookupGlyphOp = provider.defaultLookupGlyph(),
    glyph_raster: pipeline.RasterizeGlyphOp = provider.defaultGlyphRaster(),

    pub fn textProvider(self: *FtHbSource) provider.TextProvider {
        return .{
            .face_provider = .{ .ctx = self, .has_cell_text = hasCellTextThunk },
            .shaper = self.shaper,
            .rasterizer = self.rasterizer,
            .glyph_lookup = self.glyph_lookup,
            .glyph_raster = self.glyph_raster,
        };
    }
};

fn hasCellTextThunk(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
    const self: *FtHbSource = @ptrCast(@alignCast(ctx));
    for (text.codepoints) |cp| {
        if (isNonRenderingCodepoint(cp)) continue;
        if (!self.has_codepoint(self.ctx, face_id, cp)) return false;
    }
    return true;
}

fn isNonRenderingCodepoint(cp: u32) bool {
    return cp == 0xfe0e or cp == 0xfe0f;
}

test "ft hb source validates full cell text through codepoint callback" {
    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var ft_hb = FtHbSource{ .ctx = &dummy, .has_codepoint = Backend.has };
    const session = ft_hb.textProvider().applyToSession(.{ .faces = &.{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    } });
    const combining = contract.CellText{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    try std.testing.expect(session.findStyle(.regular, .any, combining) == null);
    try std.testing.expectEqual(@as(u32, 2), session.findFallback(.regular, .any, combining).?.id.value);
}

test "ft hb source carries injected shaper and rasterizer" {
    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            _ = face_id;
            _ = cp;
            return true;
        }

        fn shape(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, metrics: contract.CellMetrics) anyerror!shape_run.OwnedShapedRun {
            const hits: *usize = @ptrCast(@alignCast(ctx));
            hits.* += 1;
            return shape_run.shapeRun(allocator, run, text_cache, clusters, metrics);
        }

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
            const hits: *usize = @ptrCast(@alignCast(ctx));
            hits.* += 1;
            return rasterizer.placeholderRaster(allocator, req);
        }
    };
    var shape_hits: usize = 0;
    var raster_hits: usize = 0;
    var dummy: u8 = 0;
    var ft_hb = FtHbSource{
        .ctx = &dummy,
        .has_codepoint = Backend.has,
        .shaper = .{ .ctx = &shape_hits, .shape_run = Backend.shape },
        .rasterizer = .{ .ctx = &raster_hits, .rasterize_sprite = Backend.raster },
    };
    const text_provider = ft_hb.textProvider();
    const clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any }};
    const text_cache = contract.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} }} };
    const run = contract.ResolvedRun{ .run = .{ .cluster_start = 0, .cluster_count = 1, .font = .{ .face_id = .{ .value = 1 }, .style = .regular, .presentation = .any } } };
    var shaped = try text_provider.shaper.shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = shaped.glyphs, .sprite_key = .{ .value = 1 }, .kind = .normal };
    var out = try text_provider.rasterizer.rasterize(std.testing.allocator, rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), shape_hits);
    try std.testing.expectEqual(@as(usize, 1), raster_hits);
}
