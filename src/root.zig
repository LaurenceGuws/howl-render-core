//! Responsibility: backend-neutral render plan contracts.
//! Ownership: renderer-family policy surface.
//! Reason: keep frame interpretation and plan shape out of backend executors.

const std = @import("std");
const howl_term_surface = @import("howl_term_surface");

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

// --- Frame input types (render-core-owned; surface maps to these before calling the planner) ---

pub const CellInput = struct {
    codepoint: u21,
    fg: Rgba8,
    bg: Rgba8,
    continuation: bool = false,
};

pub const GridInput = struct {
    cells: []const CellInput,
    cols: u16,
    rows: u16,
};

pub const CursorInput = struct {
    col: u16,
    row: u16,
    shape: CursorShape,
    color: Rgba8,
};

pub const FrameInput = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridInput,
    cursor: ?CursorInput = null,
};

pub const FrameTheme = struct {
    default_fg: Rgba8,
    default_bg: Rgba8,
    cursor_color: Rgba8,
    ansi16: [16]Rgba8,
};

pub const linux_mvp_theme = FrameTheme{
    .default_fg = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .default_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .cursor_color = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .ansi16 = .{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 170, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 170, .b = 0, .a = 255 },
        .{ .r = 170, .g = 85, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 170, .a = 255 },
        .{ .r = 170, .g = 0, .b = 170, .a = 255 },
        .{ .r = 0, .g = 170, .b = 170, .a = 255 },
        .{ .r = 170, .g = 170, .b = 170, .a = 255 },
        .{ .r = 85, .g = 85, .b = 85, .a = 255 },
        .{ .r = 255, .g = 85, .b = 85, .a = 255 },
        .{ .r = 85, .g = 255, .b = 85, .a = 255 },
        .{ .r = 255, .g = 255, .b = 85, .a = 255 },
        .{ .r = 85, .g = 85, .b = 255, .a = 255 },
        .{ .r = 255, .g = 85, .b = 255, .a = 255 },
        .{ .r = 85, .g = 255, .b = 255, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    },
};

// --- Owned plan (planner output; caller responsible for deinit) ---

pub const OwnedPlan = struct {
    plan: RenderPlan,
    _fills: []FillRect,
    _glyphs: []GlyphQuad,
    _uploads: []AtlasUpload,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedPlan) void {
        self._allocator.free(self._fills);
        self._allocator.free(self._glyphs);
        self._allocator.free(self._uploads);
        self.* = undefined;
    }
};

// --- Planner ---

pub fn buildPlan(allocator: std.mem.Allocator, frame: FrameInput) !OwnedPlan {
    const cell_count = @as(usize, frame.grid.cols) * @as(usize, frame.grid.rows);
    const visible = @min(cell_count, frame.grid.cells.len);

    var fills = try std.ArrayList(FillRect).initCapacity(allocator, visible);
    errdefer fills.deinit(allocator);

    var glyphs = try std.ArrayList(GlyphQuad).initCapacity(allocator, visible / 2 + 1);
    errdefer glyphs.deinit(allocator);

    var uploads: std.ArrayList(AtlasUpload) = .empty;
    errdefer uploads.deinit(allocator);

    for (0..frame.grid.rows) |row| {
        for (0..frame.grid.cols) |col| {
            const idx = row * @as(usize, frame.grid.cols) + col;
            if (idx >= visible) break;
            const cell = frame.grid.cells[idx];

            const cell_x: i32 = @intCast(col * @as(usize, frame.cell_px.width));
            const cell_y: i32 = @intCast(row * @as(usize, frame.cell_px.height));

            try fills.append(allocator, .{
                .x = cell_x,
                .y = cell_y,
                .width = frame.cell_px.width,
                .height = frame.cell_px.height,
                .color = cell.bg,
            });

            if (cell.codepoint > 0x20 and !cell.continuation) {
                try glyphs.append(allocator, .{
                    .cell_col = @intCast(col),
                    .cell_row = @intCast(row),
                    .atlas_slot = @as(u32, cell.codepoint),
                    .fg = cell.fg,
                });
            }
        }
    }

    var cursor_draw: ?CursorDraw = null;
    if (frame.cursor) |c| {
        cursor_draw = .{
            .cell_col = c.col,
            .cell_row = c.row,
            .shape = c.shape,
            .color = c.color,
        };
    }

    const fills_owned = try fills.toOwnedSlice(allocator);
    errdefer allocator.free(fills_owned);
    const glyphs_owned = try glyphs.toOwnedSlice(allocator);
    errdefer allocator.free(glyphs_owned);
    const uploads_owned = try uploads.toOwnedSlice(allocator);

    return .{
        .plan = .{
            .surface_px = frame.surface_px,
            .cell_px = frame.cell_px,
            .grid = .{ .cols = frame.grid.cols, .rows = frame.grid.rows },
            .fills = fills_owned,
            .glyphs = glyphs_owned,
            .cursor = cursor_draw,
            .atlas_uploads = uploads_owned,
        },
        ._fills = fills_owned,
        ._glyphs = glyphs_owned,
        ._uploads = uploads_owned,
        ._allocator = allocator,
    };
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

// --- Planner tests ---

fn makeCell(cp: u21, fg: Rgba8, bg: Rgba8) CellInput {
    return .{ .codepoint = cp, .fg = fg, .bg = bg };
}

const white = Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
const black = Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
const red = Rgba8{ .r = 200, .g = 0, .b = 0, .a = 255 };

test "planner: empty grid produces zero glyphs and fills equal grid size" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), owned.plan.fills.len);
}

test "planner: space cells produce no glyph quad" {
    const cells = [_]CellInput{
        makeCell(0x20, white, black), makeCell(0x20, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
    });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.fills.len);
}

test "planner: printable cells produce glyph quads matching count" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell(0, white, black),
        makeCell('Z', white, black),
        makeCell(0x20, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), owned.plan.fills.len);
}

test "planner: fill count equals total cell count" {
    const cells = [_]CellInput{
        makeCell('H', white, black), makeCell('i', white, black),
        makeCell(0, white, black),   makeCell(0, white, black),
        makeCell('!', white, black), makeCell(0x20, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 48, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 3, .rows = 2 },
    });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 6), owned.plan.fills.len);
    try std.testing.expectEqual(@as(usize, 3), owned.plan.glyphs.len);
}

test "planner: cursor visible maps to cursor draw" {
    const cells = [_]CellInput{ makeCell(0, white, black) };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .col = 0, .row = 0, .shape = .block, .color = white },
    });
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor != null);
    try std.testing.expectEqual(CursorShape.block, owned.plan.cursor.?.shape);
    try std.testing.expectEqual(@as(u16, 0), owned.plan.cursor.?.cell_col);
}

test "planner: cursor absent produces null cursor entry" {
    const cells = [_]CellInput{ makeCell(0, white, black) };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    });
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor == null);
}

test "planner: same frame produces identical plan" {
    const cells = [_]CellInput{
        makeCell('A', white, black), makeCell('B', red, black),
        makeCell(0, white, black),   makeCell('C', white, black),
    };
    const frame = FrameInput{
        .surface_px = .{ .width = 32, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .col = 1, .row = 0, .shape = .underline, .color = white },
    };

    var a = try buildPlan(std.testing.allocator, frame);
    defer a.deinit();
    var b = try buildPlan(std.testing.allocator, frame);
    defer b.deinit();

    try std.testing.expectEqual(a.plan.fills.len, b.plan.fills.len);
    try std.testing.expectEqual(a.plan.glyphs.len, b.plan.glyphs.len);
    try std.testing.expectEqual(a.plan.cursor != null, b.plan.cursor != null);
    for (a.plan.fills, b.plan.fills) |fa, fb| {
        try std.testing.expectEqual(fa.x, fb.x);
        try std.testing.expectEqual(fa.y, fb.y);
        try std.testing.expectEqual(fa.color.r, fb.color.r);
    }
    for (a.plan.glyphs, b.plan.glyphs) |ga, gb| {
        try std.testing.expectEqual(ga.cell_col, gb.cell_col);
        try std.testing.expectEqual(ga.cell_row, gb.cell_row);
        try std.testing.expectEqual(ga.atlas_slot, gb.atlas_slot);
    }
}

test "planner: continuation cells are skipped for glyph quads" {
    var cont = makeCell('A', white, black);
    cont.continuation = true;
    const cells = [_]CellInput{
        makeCell('A', white, black),
        cont,
        makeCell('B', white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 24, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 3, .rows = 1 },
    });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.plan.glyphs.len);
}

test "planner: fill pixel positions match cell geometry" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    });
    defer owned.deinit();

    // Cell (0,0): pixel (0,0)
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[0].x);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[0].y);
    // Cell (1,0): pixel (8,0)
    try std.testing.expectEqual(@as(i32, 8), owned.plan.fills[1].x);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[1].y);
    // Cell (0,1): pixel (0,16)
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[2].x);
    try std.testing.expectEqual(@as(i32, 16), owned.plan.fills[2].y);
}

// --- Surface frame adapter ---

fn indexed256(idx: u8, theme: FrameTheme) Rgba8 {
    if (idx < 16) return theme.ansi16[idx];
    if (idx < 232) {
        const i: u32 = idx - 16;
        const r: u8 = @intCast((i / 36) * 51);
        const g: u8 = @intCast(((i / 6) % 6) * 51);
        const b: u8 = @intCast((i % 6) * 51);
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    const gray: u8 = @intCast((@as(u32, idx) - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray, .a = 255 };
}

fn colorToRgba8(color: howl_term_surface.Color, is_fg: bool, theme: FrameTheme) Rgba8 {
    return switch (color.kind) {
        .default => if (is_fg) theme.default_fg else theme.default_bg,
        .indexed => indexed256(@intCast(color.value & 0xFF), theme),
        .rgb => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
    };
}

fn mapCursorShape(shape: howl_term_surface.CursorShape) CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

pub fn buildPlanFromFrame(
    allocator: std.mem.Allocator,
    frame: howl_term_surface.FrameData,
    surface_px: PixelSize,
    cell_px: CellSize,
) !OwnedPlan {
    return buildPlanFromFrameWithTheme(allocator, frame, surface_px, cell_px, linux_mvp_theme);
}

pub fn buildPlanFromFrameWithTheme(
    allocator: std.mem.Allocator,
    frame: howl_term_surface.FrameData,
    surface_px: PixelSize,
    cell_px: CellSize,
    theme: FrameTheme,
) !OwnedPlan {
    const cell_inputs = try allocator.alloc(CellInput, frame.grid.cells.len);
    defer allocator.free(cell_inputs);
    for (frame.grid.cells, cell_inputs) |src, *dst| {
        dst.* = .{
            .codepoint = src.codepoint,
            .fg = colorToRgba8(src.fg_color, true, theme),
            .bg = colorToRgba8(src.bg_color, false, theme),
            .continuation = src.flags.continuation,
        };
    }
    const cursor_input: ?CursorInput = if (frame.cursor.visible) .{
        .col = frame.cursor.col,
        .row = frame.cursor.row,
        .shape = mapCursorShape(frame.cursor.shape),
        .color = theme.cursor_color,
    } else null;
    return buildPlan(allocator, .{
        .surface_px = surface_px,
        .cell_px = cell_px,
        .grid = .{ .cells = cell_inputs, .cols = frame.grid.cols, .rows = frame.grid.rows },
        .cursor = cursor_input,
    });
}

// --- Adapter tests ---

fn makeFrameCell(cp: u21, fg_kind: anytype, fg_val: u24, bg_kind: anytype, bg_val: u24) howl_term_surface.Cell {
    return .{
        .codepoint = cp,
        .flags = .{},
        .fg_color = .{ .kind = fg_kind, .value = fg_val },
        .bg_color = .{ .kind = bg_kind, .value = bg_val },
        .attrs = .{},
    };
}

test "adapter: default-color cells map to default fill color" {
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell(0, .default, 0, .default, 0),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 1), owned.plan.fills.len);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.g, owned.plan.fills[0].color.g);
    try std.testing.expectEqual(linux_mvp_theme.default_bg.b, owned.plan.fills[0].color.b);
}

test "adapter: rgb color cells map to exact rgb values" {
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell('A', .rgb, 0xFF8000, .rgb, 0x001020),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer owned.deinit();

    try std.testing.expectEqual(@as(u8, 0x00), owned.plan.fills[0].color.r);
    try std.testing.expectEqual(@as(u8, 0x10), owned.plan.fills[0].color.g);
    try std.testing.expectEqual(@as(u8, 0x20), owned.plan.fills[0].color.b);
    try std.testing.expectEqual(@as(u8, 0xFF), owned.plan.glyphs[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0x80), owned.plan.glyphs[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0x00), owned.plan.glyphs[0].fg.b);
}

test "adapter: cursor visible maps to cursor draw at correct position" {
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell(0, .default, 0, .default, 0),
        makeFrameCell(0, .default, 0, .default, 0),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 2, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 1, .visible = true, .shape = .underline },
    };
    var owned = try buildPlanFromFrame(std.testing.allocator, frame, .{ .width = 16, .height = 16 }, .{ .width = 8, .height = 16 });
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor != null);
    try std.testing.expectEqual(@as(u16, 1), owned.plan.cursor.?.cell_col);
    try std.testing.expectEqual(@as(u16, 0), owned.plan.cursor.?.cell_row);
    try std.testing.expectEqual(CursorShape.underline, owned.plan.cursor.?.shape);
}

test "adapter: cursor hidden maps to null cursor draw" {
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell(0, .default, 0, .default, 0),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor == null);
}

test "adapter: ansi16 indexed color maps to palette entry" {
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell(0, .default, 0, .indexed, 1),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false, .shape = .block },
    };
    var owned = try buildPlanFromFrame(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer owned.deinit();

    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].g, owned.plan.fills[0].color.g);
    try std.testing.expectEqual(linux_mvp_theme.ansi16[1].b, owned.plan.fills[0].color.b);
}

// --- 256-color tests ---

test "indexed256: ansi range 0-15 matches palette" {
    for (0..16) |i| {
        const got = indexed256(@intCast(i), linux_mvp_theme);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].r, got.r);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].g, got.g);
        try std.testing.expectEqual(linux_mvp_theme.ansi16[i].b, got.b);
    }
}

test "indexed256: color cube index 16 is black (0,0,0)" {
    const c = indexed256(16, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "indexed256: color cube index 231 is white (255,255,255)" {
    const c = indexed256(231, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 255), c.g);
    try std.testing.expectEqual(@as(u8, 255), c.b);
}

test "indexed256: color cube index 196 is red (255,0,0)" {
    // index 196 = 16 + 36*5 + 6*0 + 0 = 16+180 = 196
    const c = indexed256(196, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "indexed256: color cube index 46 is green (0,255,0)" {
    // index 46 = 16 + 36*0 + 6*5 + 0 = 16+30 = 46
    const c = indexed256(46, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 255), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "indexed256: color cube index 21 is blue (0,0,255)" {
    // index 21 = 16 + 36*0 + 6*0 + 5 = 16+5 = 21
    const c = indexed256(21, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 255), c.b);
}

test "indexed256: grayscale index 232 is darkest gray (8,8,8)" {
    const c = indexed256(232, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 8), c.r);
    try std.testing.expectEqual(@as(u8, 8), c.g);
    try std.testing.expectEqual(@as(u8, 8), c.b);
}

test "indexed256: grayscale index 255 is lightest gray (238,238,238)" {
    const c = indexed256(255, linux_mvp_theme);
    try std.testing.expectEqual(@as(u8, 238), c.r);
    try std.testing.expectEqual(@as(u8, 238), c.g);
    try std.testing.expectEqual(@as(u8, 238), c.b);
}

test "indexed256: grayscale ramp is monotonically increasing" {
    var prev: u8 = 0;
    for (232..256) |i| {
        const c = indexed256(@intCast(i), linux_mvp_theme);
        try std.testing.expect(c.r >= prev);
        prev = c.r;
    }
}

test "adapter: explicit theme overrides default and cursor colors" {
    const custom_theme = FrameTheme{
        .default_fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .default_bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
        .cursor_color = .{ .r = 7, .g = 8, .b = 9, .a = 255 },
        .ansi16 = linux_mvp_theme.ansi16,
    };
    const cells = [_]howl_term_surface.Cell{
        makeFrameCell('A', .default, 0, .default, 0),
    };
    const frame = howl_term_surface.FrameData{
        .viewport = .{ .cols = 1, .rows = 1, .scroll_row = 0, .is_alternate_screen = false },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = true, .shape = .block },
    };
    var owned = try buildPlanFromFrameWithTheme(std.testing.allocator, frame, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, custom_theme);
    defer owned.deinit();

    try std.testing.expectEqual(custom_theme.default_bg.r, owned.plan.fills[0].color.r);
    try std.testing.expectEqual(custom_theme.default_fg.g, owned.plan.glyphs[0].fg.g);
    try std.testing.expectEqual(custom_theme.cursor_color.b, owned.plan.cursor.?.color.b);
}
