
pub const SurfaceState = enum {
    idle,
    running,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const PixelSize = struct {
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

pub const GeometryResponse = struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
};

pub const Color = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    value: u24 = 0,
};

pub const CellFlags = packed struct {
    continuation: bool = false,
    _pad: u7 = 0,
};

pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    underline_color_set: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    underline_color: Color = .{ .kind = .default, .value = 0 },
    underline_style: UnderlineStyle = .straight,
    attrs: CellAttrs = .{},
    link_id: u32 = 0,
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
};

pub const DamageInfo = struct {
    full: bool = true,
    scroll_up_rows: u16 = 0,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const ViewportInfo = struct {
    cols: u16,
    rows: u16,
    scroll_row: usize = 0,
    is_alternate_screen: bool = false,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
};

pub const FrameData = struct {
    viewport: ViewportInfo,
    grid: GridModel,
    cursor: CursorInfo,
    damage: DamageInfo = .{},
};
