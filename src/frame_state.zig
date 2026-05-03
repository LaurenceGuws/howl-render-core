//! Responsibility: define shared frame/surface model types for render conversion.
//! Ownership: render-core surface data model.
//! Reason: keep frame shape canonical across modules.

pub const SurfaceState = enum {
    idle,
    running,
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
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    attrs: CellAttrs = .{},
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
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
};
