//! Responsibility: own renderer-neutral text scene helpers.
//! Ownership: render-core text engine.
//! Reason: separate text decisions from backend draw submission.

const std = @import("std");
const contract = @import("../text_contract.zig");
const atlas_cache = @import("atlas_cache.zig");
const metrics = @import("metrics.zig");
const rasterizer = @import("rasterizer.zig");

pub const TextScene = contract.TextScene;
pub const TextSpriteDraw = contract.TextSpriteDraw;

pub fn empty(cells: []const contract.RenderableCell) TextScene {
    return .{ .cells = cells, .background_draws = &.{}, .sprite_draws = &.{}, .decoration_draws = &.{}, .cursor_draws = &.{}, .missing = &.{} };
}

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInput = struct {
    cell_col: u16,
    cell_row: u16,
    shape: CursorShape,
    color: contract.Rgba8,
};

pub const BuildOptions = struct {
    cursor: ?CursorInput = null,
};

pub const OwnedTextScene = struct {
    allocator: std.mem.Allocator,
    scene: contract.TextScene,

    pub fn deinit(self: *OwnedTextScene) void {
        self.allocator.free(self.scene.background_draws);
        self.allocator.free(self.scene.sprite_draws);
        self.allocator.free(self.scene.decoration_draws);
        self.allocator.free(self.scene.cursor_draws);
        self.allocator.free(self.scene.raster_requests);
        self.allocator.free(self.scene.missing);
        self.* = undefined;
    }
};

pub fn buildScene(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
) !OwnedTextScene {
    var cache = try atlas_cache.OwnedAtlasCache.init(allocator, groups.len);
    defer cache.deinit();
    return buildSceneWithAtlasCacheOptions(allocator, cells, groups, missing, cell_metrics, grid_metrics, &cache, .{});
}

pub fn buildSceneWithOptions(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    options: BuildOptions,
) !OwnedTextScene {
    var cache = try atlas_cache.OwnedAtlasCache.init(allocator, groups.len);
    defer cache.deinit();
    return buildSceneWithAtlasCacheOptions(allocator, cells, groups, missing, cell_metrics, grid_metrics, &cache, options);
}

pub fn buildSceneWithAtlasCache(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    cache: *atlas_cache.OwnedAtlasCache,
) !OwnedTextScene {
    return buildSceneWithAtlasCacheOptions(allocator, cells, groups, missing, cell_metrics, grid_metrics, cache, .{});
}

pub fn buildSceneWithAtlasCacheOptions(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    groups: []const contract.GlyphGroup,
    missing: []const contract.MissingGlyph,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    cache: *atlas_cache.OwnedAtlasCache,
    options: BuildOptions,
) !OwnedTextScene {
    const draws = try allocator.alloc(contract.TextSpriteDraw, groups.len);
    errdefer allocator.free(draws);
    var background_draws = std.ArrayList(contract.TextBackgroundDraw).empty;
    errdefer background_draws.deinit(allocator);
    var decoration_draws = std.ArrayList(contract.TextDecorationDraw).empty;
    errdefer decoration_draws.deinit(allocator);
    const cursor_draws = if (options.cursor) |cursor| try cursorDraws(allocator, cursor, cell_metrics) else try allocator.alloc(contract.TextCursorDraw, 0);
    errdefer allocator.free(cursor_draws);
    var raster_requests = std.ArrayList(contract.SpriteRasterRequest).empty;
    errdefer raster_requests.deinit(allocator);
    const missing_owned = try allocator.dupe(contract.MissingGlyph, missing);
    errdefer allocator.free(missing_owned);

    for (groups, draws) |group, *draw| {
        const cell_w = @as(i32, @intCast(cell_metrics.cell_w_px));
        const cell_h = @as(i32, @intCast(cell_metrics.cell_h_px));
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const first_cell = @as(u32, group.first_cell);
        const col = first_cell % cols;
        const row = first_cell / cols;
        const width_cells = @max(group.cell_span, 1);
        const residency = cache.ensureDetailed(group.sprite_key, group.kind == .emoji);
        if (residency.created) try raster_requests.append(allocator, rasterizer.requestForGroup(group, cell_metrics));
        draw.* = .{
            .sprite = residency.position,
            .x_px = @as(i32, @intCast(col)) * cell_w + @as(i32, @intFromFloat(std.math.floor(group.placement.x_offset_px))),
            .y_px = @as(i32, @intCast(row)) * cell_h + @as(i32, @intFromFloat(std.math.floor(group.placement.y_offset_px))),
            .width_px = @intCast(@as(u32, width_cells) * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .placement = group.placement,
            .color = foregroundForGroup(cells, group.first_cell),
            .first_cell = group.first_cell,
            .cell_span = group.cell_span,
        };
    }

    try appendBackgroundDraws(allocator, &background_draws, cells, cell_metrics, grid_metrics);
    try appendDecorationDraws(allocator, &decoration_draws, cells, cell_metrics, grid_metrics);

    return .{ .allocator = allocator, .scene = .{
        .cells = cells,
        .background_draws = try background_draws.toOwnedSlice(allocator),
        .sprite_draws = draws,
        .decoration_draws = try decoration_draws.toOwnedSlice(allocator),
        .cursor_draws = cursor_draws,
        .raster_requests = try raster_requests.toOwnedSlice(allocator),
        .missing = missing_owned,
    } };
}

pub fn cursorDraws(
    allocator: std.mem.Allocator,
    cursor: CursorInput,
    cell_metrics: contract.CellMetrics,
) ![]contract.TextCursorDraw {
    const base_x: i32 = @as(i32, @intCast(cursor.cell_col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor.cell_row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const geom = metrics.cursorGeometry(cell_metrics);
    const count: usize = if (cursor.shape == .hollow_block) 4 else 1;
    const draws = try allocator.alloc(contract.TextCursorDraw, count);
    errdefer allocator.free(draws);
    switch (cursor.shape) {
        .block => draws[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor.color },
        .beam => draws[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor.color },
        .underline => draws[0] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - geom.underline_h_px)), .width_px = cell_metrics.cell_w_px, .height_px = geom.underline_h_px, .color = cursor.color },
        .hollow_block => {
            const stroke = geom.hollow_stroke_px;
            draws[0] = .{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor.color };
            draws[1] = .{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - stroke)), .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor.color };
            draws[2] = .{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor.color };
            draws[3] = .{ .x_px = base_x + @as(i32, @intCast(cell_metrics.cell_w_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor.color };
        },
    }
    return draws;
}

fn appendBackgroundDraws(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(contract.TextBackgroundDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
) !void {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (cell.continuation) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        try out.append(allocator, .{
            .x_px = base_x,
            .y_px = base_y,
            .width_px = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = cell.bg,
            .first_cell = cell.first_cell,
            .cell_span = cell.cell_span,
        });
    }
}

fn appendDecorationDraws(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(contract.TextDecorationDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
) !void {
    const font_metrics = metrics.defaultFontMetrics(cell_metrics);
    const deco = metrics.decorationGeometry(cell_metrics, font_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!cell.underline and !cell.strikethrough) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline) try out.append(allocator, .{
            .kind = .underline,
            .x_px = base_x,
            .y_px = base_y + deco.underline_y_px,
            .width_px = width_px,
            .height_px = deco.underline_h_px,
            .color = cell.fg,
            .first_cell = cell.first_cell,
            .cell_span = cell.cell_span,
        });
        if (cell.strikethrough) try out.append(allocator, .{
            .kind = .strikethrough,
            .x_px = base_x,
            .y_px = base_y + deco.strikethrough_y_px,
            .width_px = width_px,
            .height_px = deco.strikethrough_h_px,
            .color = cell.fg,
            .first_cell = cell.first_cell,
            .cell_span = cell.cell_span,
        });
    }
}

fn foregroundForGroup(cells: []const contract.RenderableCell, first_cell: u32) contract.Rgba8 {
    const idx = @as(usize, @intCast(first_cell));
    if (idx < cells.len) return cells[idx].fg;
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

test "scene builds ordered sprite draws from groups" {
    const cell = contract.RenderableCell{
        .text_id = .{ .value = 0 },
        .first_cell = 3,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const group = contract.GlyphGroup{
        .first_cell = 0,
        .cell_span = 2,
        .glyphs = &.{},
        .sprite_key = .{ .value = 99 },
        .kind = .normal,
    };
    var owned = try buildScene(std.testing.allocator, &.{cell}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 1), owned.scene.raster_requests.len);
    try std.testing.expectEqual(@as(usize, 1), owned.scene.background_draws.len);
    try std.testing.expectEqual(@as(usize, 0), owned.scene.decoration_draws.len);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u64, 99), owned.scene.sprite_draws[0].sprite.key.value);
}

test "scene emits background draws from non-continuation cells" {
    const cells = [_]contract.RenderableCell{
        .{
            .text_id = .{ .value = 0 },
            .first_cell = 0,
            .cell_span = 2,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        },
        .{
            .text_id = .{ .value = 1 },
            .first_cell = 1,
            .cell_span = 1,
            .style = .regular,
            .presentation = .any,
            .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
            .continuation = true,
        },
    };
    var owned = try buildScene(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 2 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.scene.background_draws.len);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.background_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 1), owned.scene.background_draws[0].color.r);
}

test "scene cursor helper emits shared cursor geometry" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cell_metrics = contract.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    const underline = try cursorDraws(std.testing.allocator, .{ .cell_col = 2, .cell_row = 1, .shape = .underline, .color = color }, cell_metrics);
    defer std.testing.allocator.free(underline);
    try std.testing.expectEqual(@as(usize, 1), underline.len);
    try std.testing.expectEqual(@as(i32, 16), underline[0].x_px);
    try std.testing.expectEqual(@as(u16, 8), underline[0].width_px);
    try std.testing.expectEqual(color.r, underline[0].color.r);

    const hollow = try cursorDraws(std.testing.allocator, .{ .cell_col = 0, .cell_row = 0, .shape = .hollow_block, .color = color }, cell_metrics);
    defer std.testing.allocator.free(hollow);
    try std.testing.expectEqual(@as(usize, 4), hollow.len);
}

test "scene build options include cursor draws" {
    const color = contract.Rgba8{ .r = 7, .g = 8, .b = 9, .a = 255 };
    var owned = try buildSceneWithOptions(std.testing.allocator, &.{}, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 4 }, .{
        .cursor = .{ .cell_col = 3, .cell_row = 2, .shape = .beam, .color = color },
    });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.scene.cursor_draws.len);
    try std.testing.expectEqual(@as(i32, 24), owned.scene.cursor_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 32), owned.scene.cursor_draws[0].y_px);
    try std.testing.expectEqual(color.g, owned.scene.cursor_draws[0].color.g);
}

test "scene emits shared-geometry decoration draws from cells" {
    const cells = [_]contract.RenderableCell{.{
        .text_id = .{ .value = 0 },
        .first_cell = 1,
        .cell_span = 2,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .underline = true,
        .strikethrough = true,
    }};
    var owned = try buildScene(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 4, .rows = 1 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.scene.decoration_draws.len);
    try std.testing.expectEqual(contract.DecorationKind.underline, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(@as(i32, 8), owned.scene.decoration_draws[0].x_px);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(contract.DecorationKind.strikethrough, owned.scene.decoration_draws[1].kind);
}

test "scene carries group placement offsets into sprite draw" {
    const group = contract.GlyphGroup{
        .first_cell = 1,
        .cell_span = 1,
        .glyphs = &.{},
        .placement = .{ .x_offset_px = -1, .y_offset_px = 2, .advance_px = 8 },
        .sprite_key = .{ .value = 77 },
        .kind = .normal,
    };
    var owned = try buildScene(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 10 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(i32, 7), owned.scene.sprite_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 2), owned.scene.sprite_draws[0].y_px);
    try std.testing.expectEqual(@as(f32, 8), owned.scene.sprite_draws[0].placement.advance_px);
}

test "scene positions sprite draws by grid columns" {
    const group = contract.GlyphGroup{
        .first_cell = 7,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 1 },
        .kind = .normal,
    };
    var owned = try buildScene(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 9, .cell_h_px = 17, .baseline_px = 13 }, .{ .cols = 5, .rows = 2 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(i32, 18), owned.scene.sprite_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 17), owned.scene.sprite_draws[0].y_px);
}

test "scene reuses atlas slots for repeated sprite keys" {
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 7 }, .kind = .normal },
        .{ .first_cell = 1, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 7 }, .kind = .normal },
    };
    var cache = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 8);
    defer cache.deinit();
    var owned = try buildSceneWithAtlasCache(std.testing.allocator, &.{}, &groups, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 8 }, &cache);
    defer owned.deinit();
    try std.testing.expectEqual(owned.scene.sprite_draws[0].sprite.slot, owned.scene.sprite_draws[1].sprite.slot);
    try std.testing.expectEqual(@as(usize, 1), owned.scene.raster_requests.len);
    try std.testing.expectEqual(@as(usize, 1), cache.len);
}

test "scene does not request raster for cache hit" {
    const group = contract.GlyphGroup{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 21 }, .kind = .normal };
    var cache = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 8);
    defer cache.deinit();
    _ = cache.ensure(group.sprite_key, false);
    var owned = try buildSceneWithAtlasCache(std.testing.allocator, &.{}, &.{group}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 8 }, &cache);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.scene.raster_requests.len);
}
