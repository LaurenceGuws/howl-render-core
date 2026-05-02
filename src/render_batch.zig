//! Responsibility: build backend-neutral render batches from frame input.
//! Ownership: render-core batch generation policy.
//! Reason: keep command ordering and glyph slot assignment shared by all backends.

const std = @import("std");

/// Shared backend configuration used for batch generation and validation.
pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    font_path: ?[:0]const u8 = null,
    target_texture: u32 = 0,
};

/// Backend capability flags consumed by render-core policy.
pub const BackendCapability = struct {
    max_atlas_slots: u32,
    supports_fill_rect: bool,
    supports_glyph_quads: bool,
};

/// Pixel dimensions.
pub const PixelSize = struct {
    width: u16,
    height: u16,
};

/// Cell dimensions in pixels.
pub const CellSize = struct {
    width: u16,
    height: u16,
};

/// Grid dimensions in cells.
pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

/// 8-bit RGBA color.
pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// Filled rectangle draw command.
pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: Rgba8,
};

/// Glyph quad draw command.
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

/// Cursor shape vocabulary.
pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

/// Cursor draw command.
pub const CursorDraw = struct {
    cell_col: u16,
    cell_row: u16,
    shape: CursorShape,
    color: Rgba8,
};

/// Atlas upload command.
pub const AtlasUpload = struct {
    slot: u32,
    codepoint: u21,
    width: u16,
    height: u16,
};

/// Render-batch aggregate stats.
pub const RenderBatchStats = struct {
    fills: usize,
    glyphs: usize,
    atlas_uploads: usize,
    has_cursor: bool,
};

/// Backend-neutral render batch payload.
pub const RenderBatch = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    fills: []const FillRect = &.{},
    glyphs: []const GlyphQuad = &.{},
    cursor: ?CursorDraw = null,
    atlas_uploads: []const AtlasUpload = &.{},

    /// Summarize render batch command counts.
    pub fn stats(self: RenderBatch) RenderBatchStats {
        return .{
            .fills = self.fills.len,
            .glyphs = self.glyphs.len,
            .atlas_uploads = self.atlas_uploads.len,
            .has_cursor = self.cursor != null,
        };
    }
};

/// Input cell payload used during batch generation.
pub const CellInput = struct {
    codepoint: u21,
    fg: Rgba8,
    bg: Rgba8,
    continuation: bool = false,
};

/// Input grid payload used during batch generation.
pub const GridInput = struct {
    cells: []const CellInput,
    cols: u16,
    rows: u16,
};

/// Input cursor payload used during batch generation.
pub const CursorInput = struct {
    col: u16,
    row: u16,
    shape: CursorShape,
    color: Rgba8,
};

/// Renderer-facing VT state input.
pub const VtState = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridInput,
    cursor: ?CursorInput = null,
};

/// Owned render batch with allocator-managed buffers.
pub const OwnedRenderBatch = struct {
    batch: RenderBatch,
    _fills: []FillRect,
    _glyphs: []GlyphQuad,
    _uploads: []AtlasUpload,
    _allocator: std.mem.Allocator,

    /// Release owned batch buffers.
    pub fn deinit(self: *OwnedRenderBatch) void {
        self._allocator.free(self._fills);
        self._allocator.free(self._glyphs);
        self._allocator.free(self._uploads);
        self.* = undefined;
    }
};

fn tryAppendProceduralGlyph(
    fills: *std.ArrayList(FillRect),
    allocator: std.mem.Allocator,
    cell: CellInput,
    codepoint: u21,
    cell_x: i32,
    cell_y: i32,
    cell_w: u16,
    cell_h: u16,
) !bool {
    if (codepoint < 0x2500 or codepoint > 0x259F) return false;
    const th_h: u16 = @max(1, cell_h / 8);
    const th_v: u16 = @max(1, cell_w / 8);

    switch (codepoint) {
        0x2500 => { // ─
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            return true;
        },
        0x2502 => { // │
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x250C => { // ┌
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2510 => { // ┐
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2514 => { // └
            try appendHBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2518 => { // ┘
            try appendHBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x251C => { // ├
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2524 => { // ┤
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x252C, 0x2534, 0x253C => { // ┬ ┴ ┼
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2580 => { // ▀
            try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = cell_w, .height = @max(1, cell_h / 2), .color = cell.fg });
            return true;
        },
        0x2584 => { // ▄
            const hh: u16 = @max(1, cell_h / 2);
            try fills.append(allocator, .{ .x = cell_x, .y = cell_y + @as(i32, @intCast(cell_h - hh)), .width = cell_w, .height = hh, .color = cell.fg });
            return true;
        },
        0x2588 => { // █
            try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = cell_w, .height = cell_h, .color = cell.fg });
            return true;
        },
        0x258C => { // ▌
            try fills.append(allocator, .{ .x = cell_x, .y = cell_y, .width = @max(1, cell_w / 2), .height = cell_h, .color = cell.fg });
            return true;
        },
        0x2590 => { // ▐
            const hw: u16 = @max(1, cell_w / 2);
            try fills.append(allocator, .{ .x = cell_x + @as(i32, @intCast(cell_w - hw)), .y = cell_y, .width = hw, .height = cell_h, .color = cell.fg });
            return true;
        },
        else => return false,
    }
}

fn appendH(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const yy = y + @as(i32, @intCast((h - t) / 2));
    try fills.append(allocator, .{ .x = x, .y = yy, .width = w, .height = t, .color = color });
}

fn appendHBottom(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    try fills.append(allocator, .{ .x = x, .y = y + @as(i32, @intCast(h - t)), .width = w, .height = t, .color = color });
}

fn appendV(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const xx = x + @as(i32, @intCast((w - t) / 2));
    try fills.append(allocator, .{ .x = xx, .y = y, .width = t, .height = h, .color = color });
}

fn appendVRight(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    try fills.append(allocator, .{ .x = x + @as(i32, @intCast(w - t)), .y = y, .width = t, .height = h, .color = color });
}

pub const RenderBatchBuildError = error{
    OutOfMemory,
};

/// Build an owned backend-neutral draw batch from a complete frame input.
pub fn renderBatch(
    allocator: std.mem.Allocator,
    frame: VtState,
    capability: BackendCapability,
) RenderBatchBuildError!OwnedRenderBatch {
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

            const procedural = try tryAppendProceduralGlyph(
                &fills,
                allocator,
                cell,
                cell.codepoint,
                cell_x,
                cell_y,
                frame.cell_px.width,
                frame.cell_px.height,
            );
            if (procedural) continue;

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

    const cursor_draw: ?CursorDraw = if (frame.cursor) |c| .{
        .cell_col = c.col,
        .cell_row = c.row,
        .shape = c.shape,
        .color = c.color,
    } else null;

    const fills_owned = try fills.toOwnedSlice(allocator);
    errdefer allocator.free(fills_owned);
    const glyphs_owned = try glyphs.toOwnedSlice(allocator);
    errdefer allocator.free(glyphs_owned);
    const uploads_owned = try uploads.toOwnedSlice(allocator);

    return .{
        .batch = .{
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

/// Errors returned when a backend validates a render batch before render.
pub const RenderBatchValidationError = error{
    SurfaceMismatch,
    CellMismatch,
    FillUnsupported,
    GlyphUnsupported,
    AtlasSlotOutOfRange,
};

/// Validate a render batch against backend config and capability declarations.
pub fn validateRenderBatch(
    config: BackendConfig,
    capability: BackendCapability,
    batch: RenderBatch,
) RenderBatchValidationError!void {
    if (batch.surface_px.width != config.surface_px.width or batch.surface_px.height != config.surface_px.height) {
        return error.SurfaceMismatch;
    }
    if (batch.cell_px.width != config.cell_px.width or batch.cell_px.height != config.cell_px.height) {
        return error.CellMismatch;
    }
    if (!capability.supports_fill_rect and batch.fills.len > 0) {
        return error.FillUnsupported;
    }
    if (!capability.supports_glyph_quads and batch.glyphs.len > 0) {
        return error.GlyphUnsupported;
    }
    for (batch.atlas_uploads) |upload| {
        if (upload.slot >= capability.max_atlas_slots) {
            return error.AtlasSlotOutOfRange;
        }
    }
}

/// Summarize command counts in a render batch for backend reporting.
pub fn summarizeRenderBatch(batch: RenderBatch) RenderBatchStats {
    return batch.stats();
}

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

test "render_batch: empty grid produces zero glyphs and fills equal grid size" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), owned.batch.fills.len);
}

test "render_batch: space cells produce no glyph quad" {
    const cells = [_]CellInput{
        makeCell(0x20, white, black), makeCell(0x20, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.fills.len);
}

test "render_batch: printable cells produce glyph quads matching count" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell(0, white, black),
        makeCell('Z', white, black),
        makeCell(0x20, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 4), owned.batch.fills.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.atlas_uploads.len);
}

test "render_batch: repeated codepoints dedupe atlas uploads per slot" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('A', white, black),
        makeCell('A', white, black),
        makeCell('B', white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 4), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.atlas_uploads.len);
}

test "render_batch: exactly at capacity keeps all unique glyph slots" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('B', white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.atlas_uploads.len);
    try std.testing.expectEqual(@as(u32, 0), owned.batch.glyphs[0].atlas_slot);
    try std.testing.expectEqual(@as(u32, 1), owned.batch.glyphs[1].atlas_slot);
}

test "render_batch: over capacity drops new codepoints deterministically" {
    const cells = [_]CellInput{
        makeCell('A', white, black),
        makeCell('B', white, black),
        makeCell('C', white, black),
        makeCell('A', white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(2));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 3), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.atlas_uploads.len);
    try std.testing.expectEqual(@as(u21, 'A'), owned.batch.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), owned.batch.glyphs[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), owned.batch.glyphs[2].codepoint);
    try std.testing.expectEqual(@as(u32, 0), owned.batch.glyphs[0].atlas_slot);
    try std.testing.expectEqual(@as(u32, 1), owned.batch.glyphs[1].atlas_slot);
    try std.testing.expectEqual(@as(u32, 0), owned.batch.glyphs[2].atlas_slot);
}

test "render_batch: fill count equals total cell count" {
    const cells = [_]CellInput{
        makeCell('H', white, black), makeCell('i', white, black),
        makeCell(0, white, black),   makeCell(0, white, black),
        makeCell('!', white, black), makeCell(0x20, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 48, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 3, .rows = 2 },
    }, testCapability(8));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 6), owned.batch.fills.len);
    try std.testing.expectEqual(@as(usize, 3), owned.batch.glyphs.len);
}

test "render_batch: cursor visible maps to cursor draw" {
    const cells = [_]CellInput{makeCell(0, white, black)};
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .col = 0, .row = 0, .shape = .block, .color = white },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.batch.cursor != null);
    try std.testing.expectEqual(CursorShape.block, owned.batch.cursor.?.shape);
    try std.testing.expectEqual(@as(u16, 0), owned.batch.cursor.?.cell_col);
    try std.testing.expectEqual(@as(usize, 0), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), owned.batch.atlas_uploads.len);
}

test "validation rejects surface mismatch" {
    const config = BackendConfig{
        .surface_px = .{ .width = 1280, .height = 720 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = BackendCapability{
        .max_atlas_slots = 32,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const batch = RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    try std.testing.expectError(error.SurfaceMismatch, validateRenderBatch(config, cap, batch));
}

test "validation rejects atlas slots outside capability range" {
    const uploads = [_]AtlasUpload{
        .{ .slot = 1, .codepoint = 'A', .width = 8, .height = 16 },
        .{ .slot = 2, .codepoint = 'B', .width = 8, .height = 16 },
    };
    const config = BackendConfig{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = BackendCapability{
        .max_atlas_slots = 2,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const batch = RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
        .atlas_uploads = &uploads,
    };

    try std.testing.expectError(error.AtlasSlotOutOfRange, validateRenderBatch(config, cap, batch));
}

test "summary mirrors render-batch stats" {
    const batch = RenderBatch{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 100, .rows = 37 },
        .cursor = .{
            .cell_col = 0,
            .cell_row = 0,
            .shape = .beam,
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        },
    };
    const stats = summarizeRenderBatch(batch);
    try std.testing.expect(stats.has_cursor);
}

test "render_batch: cursor absent produces null cursor entry" {
    const cells = [_]CellInput{makeCell(0, white, black)};
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.batch.cursor == null);
}

test "render_batch: same frame produces identical batch" {
    const cells = [_]CellInput{
        makeCell('A', white, black), makeCell('B', red, black),
        makeCell(0, white, black),   makeCell('C', white, black),
    };
    const frame = VtState{
        .surface_px = .{ .width = 32, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .col = 1, .row = 0, .shape = .underline, .color = white },
    };

    var a = try renderBatch(std.testing.allocator, frame, testCapability(4));
    defer a.deinit();
    var b = try renderBatch(std.testing.allocator, frame, testCapability(4));
    defer b.deinit();

    try std.testing.expectEqual(a.batch.fills.len, b.batch.fills.len);
    try std.testing.expectEqual(a.batch.glyphs.len, b.batch.glyphs.len);
    try std.testing.expectEqual(a.batch.atlas_uploads.len, b.batch.atlas_uploads.len);
    try std.testing.expectEqual(a.batch.cursor != null, b.batch.cursor != null);
    for (a.batch.fills, b.batch.fills) |fa, fb| {
        try std.testing.expectEqual(fa.x, fb.x);
        try std.testing.expectEqual(fa.y, fb.y);
        try std.testing.expectEqual(fa.color.r, fb.color.r);
    }
    for (a.batch.glyphs, b.batch.glyphs) |ga, gb| {
        try std.testing.expectEqual(ga.x, gb.x);
        try std.testing.expectEqual(ga.y, gb.y);
        try std.testing.expectEqual(ga.atlas_slot, gb.atlas_slot);
        try std.testing.expectEqual(ga.codepoint, gb.codepoint);
    }
    for (a.batch.atlas_uploads, b.batch.atlas_uploads) |ua, ub| {
        try std.testing.expectEqual(ua.slot, ub.slot);
        try std.testing.expectEqual(ua.codepoint, ub.codepoint);
    }
}

test "render_batch: continuation cells are skipped for glyph quads" {
    var cont = makeCell('A', white, black);
    cont.continuation = true;
    const cells = [_]CellInput{
        makeCell('A', white, black),
        cont,
        makeCell('B', white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 24, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 3, .rows = 1 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 2), owned.batch.atlas_uploads.len);
}

test "render_batch: box drawing chars render procedurally without atlas upload" {
    const cells = [_]CellInput{
        makeCell(0x2500, white, black), // ─
        makeCell(0x2502, white, black), // │
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 8 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
    }, testCapability(8));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), owned.batch.atlas_uploads.len);
    try std.testing.expect(owned.batch.fills.len > 2);
}

test "render_batch: fill pixel positions match cell geometry" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[0].x);
    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[0].y);
    try std.testing.expectEqual(@as(i32, 8), owned.batch.fills[1].x);
    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[1].y);
    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[2].x);
    try std.testing.expectEqual(@as(i32, 16), owned.batch.fills[2].y);
}
