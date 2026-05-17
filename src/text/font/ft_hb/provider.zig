const provider = @import("../provider.zig");
const font_session = @import("../session.zig");
const contract = @import("../../contract.zig");
const pipeline = @import("../../pipeline.zig");
const rasterizer = @import("../../raster/rasterizer.zig");
const shape_run = @import("../../shape/run.zig");

pub const FtHbSource = struct {
    ctx: *anyopaque,
    has_codepoint: *const fn (ctx: *anyopaque, face_id: font_session.FontFaceId, codepoint: u32) bool,
    shaper: shape_run.Shaper = shape_run.defaultShaper(),
    rasterizer: rasterizer.Rasterizer = rasterizer.defaultRasterizer(),
    glyph_lookup: provider.LookupGlyphOp = provider.defaultLookupGlyph(),
    glyph_raster: pipeline.RasterizeGlyphOp = provider.defaultGlyphRaster(),

    pub fn textProvider(self: *FtHbSource) provider.TextProvider {
        return .{
            .face_provider = .{ .ctx = self, .has_cell_text = hasCellText },
            .shaper = self.shaper,
            .rasterizer = self.rasterizer,
            .glyph_lookup = self.glyph_lookup,
            .glyph_raster = self.glyph_raster,
        };
    }

    fn hasCellText(ctx: *anyopaque, face_id: font_session.FontFaceId, text: contract.CellText) bool {
        const self: *FtHbSource = @ptrCast(@alignCast(ctx));
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        for (cps) |cp| {
            if (cp == 0xfe0e or cp == 0xfe0f) continue;
            if (!self.has_codepoint(self.ctx, face_id, cp)) return false;
        }
        return true;
    }
};
