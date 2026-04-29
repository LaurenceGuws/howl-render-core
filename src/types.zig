//! Responsibility: define backend-neutral render data apis.
//! Ownership: render-core public API.
//! Reason: keep shared plan types independent from planning and backend execution.

const std = @import("std");

/// Configuration shared by renderer backend implementations at initialization.
pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    font_path: ?[:0]const u8 = null,
    target_texture: u32 = 0,
};

/// Runtime capability report used by render-core planning.
pub const BackendCapability = struct {
    max_atlas_slots: u32,
    supports_fill_rect: bool,
    supports_glyph_quads: bool,
};

/// Pixel dimensions for a drawable surface.
pub const PixelSize = struct {
    width: u16,
    height: u16,
};

/// Pixel dimensions for one terminal grid cell.
pub const CellSize = struct {
    width: u16,
    height: u16,
};

/// Terminal grid dimensions in cells.
pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

/// Eight-bit RGBA color used in render plans.
pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// Solid rectangle command emitted before glyph drawing.
pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: Rgba8,
};

/// Textured glyph rectangle with its atlas slot and foreground color.
pub const GlyphQuad = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    atlas_slot: u32,
    codepoint: u21,
    fg: Rgba8,
    bg: ?Rgba8 = null,
};

/// Cursor shape variants supported by the shared plan api.
pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

/// Cursor command positioned in grid coordinates.
pub const CursorDraw = struct {
    cell_col: u16,
    cell_row: u16,
    shape: CursorShape,
    color: Rgba8,
};

/// Glyph upload request keyed by atlas slot and codepoint.
pub const AtlasUpload = struct {
    slot: u32,
    codepoint: u21,
    width: u16,
    height: u16,
};

/// Summary counts for a render plan.
pub const PlanStats = struct {
    fills: usize,
    glyphs: usize,
    atlas_uploads: usize,
    has_cursor: bool,
};

/// Backend-neutral draw plan produced by render-core.
pub const RenderPlan = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    fills: []const FillRect = &.{},
    glyphs: []const GlyphQuad = &.{},
    cursor: ?CursorDraw = null,
    atlas_uploads: []const AtlasUpload = &.{},

    /// Count the draw commands and cursor presence without mutating the plan.
    pub fn stats(self: RenderPlan) PlanStats {
        return .{
            .fills = self.fills.len,
            .glyphs = self.glyphs.len,
            .atlas_uploads = self.atlas_uploads.len,
            .has_cursor = self.cursor != null,
        };
    }
};

/// Backend-neutral terminal cell input consumed by the planner.
pub const CellInput = struct {
    codepoint: u21,
    fg: Rgba8,
    bg: Rgba8,
    continuation: bool = false,
};

/// Row-major terminal cell buffer and dimensions consumed by the planner.
pub const GridInput = struct {
    cells: []const CellInput,
    cols: u16,
    rows: u16,
};

/// Cursor input from the surface-facing frame api.
pub const CursorInput = struct {
    col: u16,
    row: u16,
    shape: CursorShape,
    color: Rgba8,
};

/// Complete frame input consumed by render-core planning.
pub const FrameInput = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridInput,
    cursor: ?CursorInput = null,
};

/// Color theme used when converting frame colors before planning.
pub const FrameTheme = struct {
    default_fg: Rgba8,
    default_bg: Rgba8,
    cursor_color: Rgba8,
    ansi16: [16]Rgba8,
};

/// Owned render plan with buffers that must be released by the caller.
pub const OwnedPlan = struct {
    plan: RenderPlan,
    _fills: []FillRect,
    _glyphs: []GlyphQuad,
    _uploads: []AtlasUpload,
    _allocator: std.mem.Allocator,

    /// Release all buffers owned by this plan.
    pub fn deinit(self: *OwnedPlan) void {
        self._allocator.free(self._fills);
        self._allocator.free(self._glyphs);
        self._allocator.free(self._uploads);
        self.* = undefined;
    }
};

test "render plan stats summarize backend-neutral command counts" {
    const fills = [_]FillRect{
        .{ .x = 0, .y = 0, .width = 8, .height = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    };
    const glyphs = [_]GlyphQuad{
        .{ .x = 8, .y = 32, .width = 8, .height = 16, .atlas_slot = 7, .codepoint = 'A', .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    };
    const uploads = [_]AtlasUpload{
        .{ .slot = 7, .codepoint = 'A', .width = 8, .height = 16 },
        .{ .slot = 8, .codepoint = 'B', .width = 8, .height = 16 },
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
