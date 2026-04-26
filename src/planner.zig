//! Responsibility: build backend-neutral render plans from frame input.
//! Ownership: render-core planning policy.
//! Reason: keep command ordering and glyph slot assignment shared by all backends.

const std = @import("std");
const types = @import("types.zig");

/// Build an owned backend-neutral draw plan from a complete frame input.
pub fn buildPlan(
    allocator: std.mem.Allocator,
    frame: types.FrameInput,
    capability: types.BackendCapability,
) !types.OwnedPlan {
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

test "planner: empty grid produces zero glyphs and fills equal grid size" {
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{makeCell(0, white, black)};
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .col = 0, .row = 0, .shape = .block, .color = white },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor != null);
    try std.testing.expectEqual(types.CursorShape.block, owned.plan.cursor.?.shape);
    try std.testing.expectEqual(@as(u16, 0), owned.plan.cursor.?.cell_col);
    try std.testing.expectEqual(@as(usize, 0), owned.plan.glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), owned.plan.atlas_uploads.len);
}

test "planner: cursor absent produces null cursor entry" {
    const cells = [_]types.CellInput{makeCell(0, white, black)};
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    }, testCapability(1));
    defer owned.deinit();

    try std.testing.expect(owned.plan.cursor == null);
}

test "planner: same frame produces identical plan" {
    const cells = [_]types.CellInput{
        makeCell('A', white, black), makeCell('B', red, black),
        makeCell(0, white, black),   makeCell('C', white, black),
    };
    const frame = types.FrameInput{
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
    const cells = [_]types.CellInput{
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
    const cells = [_]types.CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, black), makeCell(0, white, black),
    };
    var owned = try buildPlan(std.testing.allocator, .{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
    }, testCapability(4));
    defer owned.deinit();

    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[0].x);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[0].y);
    try std.testing.expectEqual(@as(i32, 8), owned.plan.fills[1].x);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[1].y);
    try std.testing.expectEqual(@as(i32, 0), owned.plan.fills[2].x);
    try std.testing.expectEqual(@as(i32, 16), owned.plan.fills[2].y);
}
