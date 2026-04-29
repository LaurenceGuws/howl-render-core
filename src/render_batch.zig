//! Responsibility: build backend-neutral render batches from frame input.
//! Ownership: render-core batch generation policy.
//! Reason: keep command ordering and glyph slot assignment shared by all backends.

const std = @import("std");
const types = @import("types.zig");

/// Build an owned backend-neutral draw batch from a complete frame input.
pub fn renderBatch(
    allocator: std.mem.Allocator,
    frame: types.VtState,
    capability: types.BackendCapability,
) !types.OwnedRenderBatch {
    const cell_count = @as(usize, frame.grid.cols) * @as(usize, frame.grid.rows);
    const visible = @min(cell_count, frame.grid.cells.len);

    var fills = try std.ArrayList(types.FillRect).initCapacity(allocator, visible);
    errdefer fills.deinit(allocator);

    var glyphs = try std.ArrayList(types.GlyphQuad).initCapacity(allocator, visible);
    errdefer glyphs.deinit(allocator);

    var uploads = try std.ArrayList(types.AtlasUpload).initCapacity(allocator, visible);
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

    const cursor_draw: ?types.CursorDraw = if (frame.cursor) |c| .{
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
    config: types.BackendConfig,
    capability: types.BackendCapability,
    batch: types.RenderBatch,
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
pub fn summarizeRenderBatch(batch: types.RenderBatch) types.RenderBatchStats {
    return batch.stats();
}

fn makeCell(cp: u21, fg: types.Rgba8, bg: types.Rgba8) types.CellInput {
    return .{ .codepoint = cp, .fg = fg, .bg = bg };
}

const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
const red = types.Rgba8{ .r = 200, .g = 0, .b = 0, .a = 255 };

fn testCapability(max_atlas_slots: u32) types.BackendCapability {
    return .{
        .max_atlas_slots = max_atlas_slots,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
}

test "render_batch: empty grid produces zero glyphs and fills equal grid size" {
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{makeCell(0, white, black)};
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .col = 0, .row = 0, .shape = .block, .color = white },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.batch.cursor != null);
    try std.testing.expectEqual(types.CursorShape.block, owned.batch.cursor.?.shape);
    try std.testing.expectEqual(@as(u16, 0), owned.batch.cursor.?.cell_col);
    try std.testing.expectEqual(@as(usize, 0), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), owned.batch.atlas_uploads.len);
}

test "validation rejects surface mismatch" {
    const config = types.BackendConfig{
        .surface_px = .{ .width = 1280, .height = 720 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = types.BackendCapability{
        .max_atlas_slots = 32,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const batch = types.RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    try std.testing.expectError(error.SurfaceMismatch, validateRenderBatch(config, cap, batch));
}

test "validation rejects atlas slots outside capability range" {
    const uploads = [_]types.AtlasUpload{
        .{ .slot = 1, .codepoint = 'A', .width = 8, .height = 16 },
        .{ .slot = 2, .codepoint = 'B', .width = 8, .height = 16 },
    };
    const config = types.BackendConfig{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = types.BackendCapability{
        .max_atlas_slots = 2,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const batch = types.RenderBatch{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
        .atlas_uploads = &uploads,
    };

    try std.testing.expectError(error.AtlasSlotOutOfRange, validateRenderBatch(config, cap, batch));
}

test "summary mirrors render-batch stats" {
    const batch = types.RenderBatch{
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
    const cells = [_]types.CellInput{makeCell(0, white, black)};
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.batch.cursor == null);
}

test "render_batch: same frame produces identical batch" {
    const cells = [_]types.CellInput{
        makeCell('A', white, black), makeCell('B', red, black),
        makeCell(0, white, black),   makeCell('C', white, black),
    };
    const frame = types.VtState{
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
    const cells = [_]types.CellInput{
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

test "render_batch: fill pixel positions match cell geometry" {
    const cells = [_]types.CellInput{
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
