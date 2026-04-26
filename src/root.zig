//! Responsibility: backend-neutral render plan contracts.
//! Ownership: renderer-family policy surface.
//! Reason: keep frame interpretation and plan shape out of backend executors.

const std = @import("std");

// --- Backend lifecycle contract types ---

pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
};

pub const BackendCapability = struct {
    max_atlas_slots: u32,
    supports_fill_rect: bool,
    supports_glyph_quads: bool,
};

// --- Geometry types ---

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: Rgba8,
};

pub const GlyphQuad = struct {
    cell_col: u16,
    cell_row: u16,
    atlas_slot: u32,
    fg: Rgba8,
    bg: ?Rgba8 = null,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorDraw = struct {
    cell_col: u16,
    cell_row: u16,
    shape: CursorShape,
    color: Rgba8,
};

pub const AtlasUpload = struct {
    slot: u32,
    width: u16,
    height: u16,
};

pub const PlanStats = struct {
    fills: usize,
    glyphs: usize,
    atlas_uploads: usize,
    has_cursor: bool,
};

pub const RenderPlan = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    fills: []const FillRect = &.{},
    glyphs: []const GlyphQuad = &.{},
    cursor: ?CursorDraw = null,
    atlas_uploads: []const AtlasUpload = &.{},

    pub fn stats(self: RenderPlan) PlanStats {
        return .{
            .fills = self.fills.len,
            .glyphs = self.glyphs.len,
            .atlas_uploads = self.atlas_uploads.len,
            .has_cursor = self.cursor != null,
        };
    }
};

test "render plan stats summarize backend-neutral command counts" {
    const fills = [_]FillRect{
        .{ .x = 0, .y = 0, .width = 8, .height = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    };
    const glyphs = [_]GlyphQuad{
        .{ .cell_col = 1, .cell_row = 2, .atlas_slot = 7, .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    };
    const uploads = [_]AtlasUpload{
        .{ .slot = 7, .width = 8, .height = 16 },
        .{ .slot = 8, .width = 8, .height = 16 },
    };

    const plan = RenderPlan{
        .surface_px = .{ .width = 1280, .height = 720 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 160, .rows = 45 },
        .fills = &fills,
        .glyphs = &glyphs,
        .cursor = .{ .cell_col = 1, .cell_row = 2, .shape = .block, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
        .atlas_uploads = &uploads,
    };

    const stats = plan.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.fills);
    try std.testing.expectEqual(@as(usize, 1), stats.glyphs);
    try std.testing.expectEqual(@as(usize, 2), stats.atlas_uploads);
    try std.testing.expect(stats.has_cursor);
}

test "render plan stats handle empty command sets" {
    const plan = RenderPlan{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    const stats = plan.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.fills);
    try std.testing.expectEqual(@as(usize, 0), stats.glyphs);
    try std.testing.expectEqual(@as(usize, 0), stats.atlas_uploads);
    try std.testing.expect(!stats.has_cursor);
}
