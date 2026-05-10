//! Responsibility: shared render geometry and cell payload types.
//! Ownership: renderer-neutral type vocabulary.
//! Reason: keep active text-rendering code free of batch-planner machinery.

const rgba = @import("rgba.zig");

pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
    target_texture: u32 = 0,
};

pub const BackendCapability = struct {
    max_atlas_slots: u32,
    supports_fill_rect: bool,
    supports_glyph_quads: bool,
};

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

pub const FramePixels = struct {
    render_width: i32,
    render_height: i32,
    grid_width: i32,
    grid_height: i32,

    pub fn renderWidth(self: FramePixels) u16 {
        return @intCast(@max(self.render_width, 1));
    }

    pub fn renderHeight(self: FramePixels) u16 {
        return @intCast(@max(self.render_height, 1));
    }

    pub fn gridWidth(self: FramePixels) u16 {
        return @intCast(@max(self.grid_width, 1));
    }

    pub fn gridHeight(self: FramePixels) u16 {
        return @intCast(@max(self.grid_height, 1));
    }
};

pub const Rgba8 = rgba.Rgba8;

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: Rgba8,
};

pub const GlyphQuad = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    codepoint: u21,
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
    codepoint: u21,
    width: u16,
    height: u16,
};

pub const RenderStats = struct {
    fills: usize,
    glyphs: usize,
    atlas_uploads: usize,
    has_cursor: bool,
    full_redraw: bool,
};

pub const CellInput = struct {
    codepoint: u21,
    fg: Rgba8,
    bg: Rgba8,
    underline_color: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    underline_style: UnderlineStyle = .straight,
    underline: bool = false,
    strikethrough: bool = false,
    continuation: bool = false,
    empty: bool = false,
};
