//! Responsibility: backend-neutral render plan contracts.
//! Ownership: renderer-family policy surface.
//! Reason: keep frame interpretation and plan shape out of backend executors.

const std = @import("std");

// --- Backend lifecycle contract types ---

pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    font_path: ?[:0]const u8 = null,
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
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    atlas_slot: u32,
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
    slot: u32,
    codepoint: u21,
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

pub fn buildPlan(
    allocator: std.mem.Allocator,
    frame: FrameInput,
    capability: BackendCapability,
) !OwnedPlan {
    const cell_count = @as(usize, frame.grid.cols) * @as(usize, frame.grid.rows);
    const visible = @min(cell_count, frame.grid.cells.len);

    var fills = try std.ArrayList(FillRect).initCapacity(allocator, visible);
    errdefer fills.deinit(allocator);

    var glyphs = try std.ArrayList(GlyphQuad).initCapacity(allocator, visible);
    errdefer glyphs.deinit(allocator);

    var uploads = try std.ArrayList(AtlasUpload).initCapacity(allocator, visible);
    errdefer uploads.deinit(allocator);
    var glyph_slots = std.AutoHashMap(u21, u32).init(allocator);
    defer glyph_slots.deinit();
    const glyphs_enabled = capability.supports_glyph_quads and capability.max_atlas_slots > 0;
    var next_slot: u32 = 0;

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

            if (glyphs_enabled and cell.codepoint > 0x20 and !cell.continuation) {
                const slot = if (glyph_slots.get(cell.codepoint)) |existing| existing else blk: {
                    if (next_slot >= capability.max_atlas_slots) break :blk null;
                    const assigned = next_slot;
                    try glyph_slots.put(cell.codepoint, assigned);
                    next_slot += 1;
                    try uploads.append(allocator, .{
                        .slot = assigned,
                        .codepoint = cell.codepoint,
                        .width = frame.cell_px.width,
                        .height = frame.cell_px.height,
                    });
                    break :blk assigned;
                };
                if (slot) |assigned_slot| {
                    try glyphs.append(allocator, .{
                        .x = cell_x,
                        .y = cell_y,
                        .width = frame.cell_px.width,
                        .height = frame.cell_px.height,
                        .atlas_slot = assigned_slot,
                        .codepoint = cell.codepoint,
                        .fg = cell.fg,
                    });
                }
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

fn testCapability(max_atlas_slots: u32) BackendCapability {
    return .{
        .max_atlas_slots = max_atlas_slots,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
}

test "planner: empty grid produces zero glyphs and fills equal grid size" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    }, testCapability(4));
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
    }, testCapability(4));
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
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), owned.plan.fills.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.atlas_uploads.len);
}

test "planner: repeated codepoints dedupe atlas uploads per slot" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('A', white, black),
        makeCell('A', white, black),
        makeCell('B', white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 4), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.atlas_uploads.len);
}

test "planner: exactly at capacity keeps all unique glyph slots" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('B', white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.atlas_uploads.len);
    try std.testing.expectEqual(@as(u32, 0), owned.plan.glyphs[0].atlas_slot);
    try std.testing.expectEqual(@as(u32, 1), owned.plan.glyphs[1].atlas_slot);
}

test "planner: over capacity drops new codepoints deterministically" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('B', white, black),
        makeCell('C', white, black),
        makeCell('A', white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 3), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.atlas_uploads.len);
    try std.testing.expectEqual(@as(u21, 'A'), owned.plan.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), owned.plan.glyphs[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), owned.plan.glyphs[2].codepoint);
    try std.testing.expectEqual(@as(u32, 0), owned.plan.glyphs[0].atlas_slot);
    try std.testing.expectEqual(@as(u32, 1), owned.plan.glyphs[1].atlas_slot);
    try std.testing.expectEqual(@as(u32, 0), owned.plan.glyphs[2].atlas_slot);
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
    }, testCapability(8));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 6), owned.plan.fills.len);
    try std.testing.expectEqual(@as(usize, 3), owned.plan.glyphs.len);
}

test "planner: cursor visible maps to cursor draw" {
    const cells = [_]CellInput{makeCell(0, white, black)};
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .col = 0, .row = 0, .shape = .block, .color = white },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor != null);
    try std.testing.expectEqual(CursorShape.block, owned.plan.cursor.?.shape);
    try std.testing.expectEqual(@as(u16, 0), owned.plan.cursor.?.cell_col);
    try std.testing.expectEqual(@as(usize, 0), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), owned.plan.atlas_uploads.len);
}

test "planner: cursor absent produces null cursor entry" {
    const cells = [_]CellInput{makeCell(0, white, black)};
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    }, testCapability(1));
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

    var a = try buildPlan(std.testing.allocator, frame, testCapability(4));
    defer a.deinit();
    var b = try buildPlan(std.testing.allocator, frame, testCapability(4));
    defer b.deinit();

    try std.testing.expectEqual(a.plan.fills.len, b.plan.fills.len);
    try std.testing.expectEqual(a.plan.glyphs.len, b.plan.glyphs.len);
    try std.testing.expectEqual(a.plan.atlas_uploads.len, b.plan.atlas_uploads.len);
    try std.testing.expectEqual(a.plan.cursor != null, b.plan.cursor != null);
    for (a.plan.fills, b.plan.fills) |fa, fb| {
        try std.testing.expectEqual(fa.x, fb.x);
        try std.testing.expectEqual(fa.y, fb.y);
        try std.testing.expectEqual(fa.color.r, fb.color.r);
    }
    for (a.plan.glyphs, b.plan.glyphs) |ga, gb| {
        try std.testing.expectEqual(ga.x, gb.x);
        try std.testing.expectEqual(ga.y, gb.y);
        try std.testing.expectEqual(ga.atlas_slot, gb.atlas_slot);
        try std.testing.expectEqual(ga.codepoint, gb.codepoint);
    }
    for (a.plan.atlas_uploads, b.plan.atlas_uploads) |ua, ub| {
        try std.testing.expectEqual(ua.slot, ub.slot);
        try std.testing.expectEqual(ua.codepoint, ub.codepoint);
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
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.plan.atlas_uploads.len);
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
    }, testCapability(4));
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
