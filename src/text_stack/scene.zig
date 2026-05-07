//! Responsibility: own renderer-neutral text scene helpers.
//! Ownership: render-core text engine.
//! Reason: separate text decisions from backend draw submission.

const std = @import("std");
const contract = @import("../text_contract.zig");
const atlas_cache = @import("atlas_cache.zig");
const metrics = @import("metrics.zig");
const rasterizer = @import("rasterizer.zig");
const sprite_key = @import("sprite_key.zig");

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

pub const DamageInput = struct {
    full: bool = true,
    scroll_up_rows: u16 = 0,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const BuildOptions = struct {
    cursor: ?CursorInput = null,
    damage: DamageInput = .{},
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
    const damage = normalizedDamage(options.damage, grid_metrics.rows, cell_metrics.cell_h_px);
    const draws = try allocator.alloc(contract.TextSpriteDraw, groups.len);
    errdefer allocator.free(draws);
    var background_draws = std.ArrayList(contract.TextBackgroundDraw).empty;
    errdefer background_draws.deinit(allocator);
    var decoration_draws = std.ArrayList(contract.TextDecorationDraw).empty;
    errdefer decoration_draws.deinit(allocator);
    var raster_requests = std.ArrayList(contract.SpriteRasterRequest).empty;
    errdefer raster_requests.deinit(allocator);
    const missing_owned = try allocator.dupe(contract.MissingGlyph, missing);
    errdefer allocator.free(missing_owned);
    var out_idx: usize = 0;

    for (groups, 0..) |group, group_idx| {
        if (!includeSpan(damage, grid_metrics, group.first_cell, group.cell_span)) continue;
        const cell_w = @as(i32, @intCast(cell_metrics.cell_w_px));
        const cell_h = @as(i32, @intCast(cell_metrics.cell_h_px));
        const cols = @max(@as(u32, grid_metrics.cols), 1);
        const next_group_cell = if (group_idx + 1 < groups.len) groups[group_idx + 1].first_cell else null;
        const scene_group = iconGroupWithAvailableSpace(group, cell_metrics, grid_metrics, next_group_cell);
        const first_cell = @as(u32, scene_group.first_cell);
        const col = first_cell % cols;
        const row = first_cell / cols;
        const width_cells = @max(scene_group.cell_span, 1);
        const residency = cache.ensureDetailed(scene_group.sprite_key, scene_group.kind == .emoji);
        if (residency.created) try raster_requests.append(allocator, rasterizer.requestForGroup(scene_group, cell_metrics));
        draws[out_idx] = .{
            .sprite = residency.position,
            .x_px = @as(i32, @intCast(col)) * cell_w,
            .y_px = @as(i32, @intCast(row)) * cell_h,
            .width_px = @intCast(@as(u32, width_cells) * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .placement = group.placement,
            .color = foregroundForGroup(cells, group.first_cell),
            .first_cell = group.first_cell,
            .cell_span = scene_group.cell_span,
        };
        out_idx += 1;
    }

    const cursor_draws = if (options.cursor) |cursor|
        if (damage.full or rowDirty(damage, cursor.cell_row))
            try cursorDraws(allocator, cursor, cell_metrics)
        else
            try allocator.alloc(contract.TextCursorDraw, 0)
    else
        try allocator.alloc(contract.TextCursorDraw, 0);
    errdefer allocator.free(cursor_draws);

    const sprite_draws = try allocator.realloc(draws, out_idx);

    try appendBackgroundDraws(allocator, &background_draws, cells, cell_metrics, grid_metrics, damage);
    try appendDecorationDraws(allocator, &decoration_draws, cells, cell_metrics, grid_metrics, damage);

    return .{ .allocator = allocator, .scene = .{
        .cells = cells,
        .full_redraw = damage.full,
        .scroll_up_px = damage.scroll_up_px,
        .background_draws = try background_draws.toOwnedSlice(allocator),
        .sprite_draws = sprite_draws,
        .decoration_draws = try decoration_draws.toOwnedSlice(allocator),
        .cursor_draws = cursor_draws,
        .raster_requests = try raster_requests.toOwnedSlice(allocator),
        .missing = missing_owned,
    } };
}

const NormalizedDamage = struct {
    full: bool,
    scroll_up_px: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

fn normalizedDamage(damage: DamageInput, rows: u16, cell_h_px: u16) NormalizedDamage {
    const valid = !damage.full and
        damage.dirty_rows.len == @as(usize, rows) and
        damage.dirty_cols_start.len == @as(usize, rows) and
        damage.dirty_cols_end.len == @as(usize, rows);
    return .{
        .full = !valid,
        .scroll_up_px = if (valid) @intCast(@as(u32, @min(damage.scroll_up_rows, rows)) * @as(u32, cell_h_px)) else 0,
        .dirty_rows = if (valid) damage.dirty_rows else &.{},
        .dirty_cols_start = if (valid) damage.dirty_cols_start else &.{},
        .dirty_cols_end = if (valid) damage.dirty_cols_end else &.{},
    };
}

fn rowDirty(damage: NormalizedDamage, row: u16) bool {
    if (damage.full) return true;
    const idx = @as(usize, row);
    return idx < damage.dirty_rows.len and damage.dirty_rows[idx];
}

fn includeSpan(damage: NormalizedDamage, grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) bool {
    if (damage.full) return true;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row = @as(u16, @intCast(first_cell / cols));
    if (!rowDirty(damage, row)) return false;
    const idx = @as(usize, row);
    const start_col = @as(u16, @intCast(first_cell % cols));
    const end_col = start_col +| (@max(cell_span, 1) - 1);
    const dirty_start = damage.dirty_cols_start[idx];
    const dirty_end = damage.dirty_cols_end[idx];
    return !(end_col < dirty_start or start_col > dirty_end);
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
    damage: NormalizedDamage,
) !void {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (cell.bg.a == 0) continue;
        if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
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
    damage: NormalizedDamage,
) !void {
    const font_metrics = metrics.defaultFontMetrics(cell_metrics);
    const deco = metrics.decorationGeometry(cell_metrics, font_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!cell.underline and !cell.strikethrough) continue;
        if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline) try appendUnderlineDraws(allocator, out, cell, base_x, base_y + deco.underline_y_px, width_px, deco.underline_h_px);
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

fn appendDecorationDraw(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextDecorationDraw), cell: contract.RenderableCell, x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) !void {
    try out.append(allocator, .{ .kind = .underline, .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color, .first_cell = cell.first_cell, .cell_span = cell.cell_span });
}

fn appendUnderlineDraws(allocator: std.mem.Allocator, out: *std.ArrayList(contract.TextDecorationDraw), cell: contract.RenderableCell, x: i32, y: i32, width: u16, height: u16) !void {
    const color = if (cell.underline_color.a == 0) cell.fg else cell.underline_color;
    switch (cell.underline_style) {
        .straight => try appendDecorationDraw(allocator, out, cell, x, y, width, height, color),
        .double => {
            const gap: i32 = @max(@as(i32, @intCast(height)), 1);
            try appendDecorationDraw(allocator, out, cell, x, @max(y - gap - @as(i32, @intCast(height)), 0), width, height, color);
            try appendDecorationDraw(allocator, out, cell, x, y, width, height, color);
        },
        .dotted => {
            const dot: u16 = @max(height, 1);
            const step: u16 = @max(dot * 2, 2);
            var off: u16 = 0;
            while (off < width) : (off += step) try appendDecorationDraw(allocator, out, cell, x + @as(i32, @intCast(off)), y, @min(dot, width - off), height, color);
        },
        .dashed => {
            const dash: u16 = @max(width / 3, @as(u16, 2));
            const step: u16 = @max(dash + 2, 3);
            var off: u16 = 0;
            while (off < width) : (off += step) try appendDecorationDraw(allocator, out, cell, x + @as(i32, @intCast(off)), y, @min(dash, width - off), height, color);
        },
        .curly => {
            const seg: u16 = @max(height * 2, 2);
            const y_high = @max(y - @as(i32, @intCast(height)), 0);
            const y_low = y + @as(i32, @intCast(height));
            var off: u16 = 0;
            var high = true;
            while (off < width) : (off += seg) {
                try appendDecorationDraw(allocator, out, cell, x + @as(i32, @intCast(off)), if (high) y_high else y_low, @min(seg, width - off), height, color);
                high = !high;
            }
        },
    }
}

fn foregroundForGroup(cells: []const contract.RenderableCell, first_cell: u32) contract.Rgba8 {
    const idx = @as(usize, @intCast(first_cell));
    if (idx < cells.len) return cells[idx].fg;
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

fn iconGroupWithAvailableSpace(group: contract.GlyphGroup, cell_metrics: contract.CellMetrics, grid_metrics: contract.GridMetrics, next_group_cell: ?u32) contract.GlyphGroup {
    if (group.kind != .icon) return group;
    if (cell_metrics.cell_w_px == 0) return group;
    const desired = desiredIconCells(group, cell_metrics.cell_w_px);
    if (desired <= group.cell_span) return group;

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row_end = ((group.first_cell / cols) + 1) * cols;
    const next = next_group_cell orelse row_end;
    const available_end = @min(row_end, next);
    if (available_end <= group.first_cell) return group;
    const available_cells: u8 = @intCast(@min(available_end - group.first_cell, std.math.maxInt(u8)));
    const cell_span = @min(desired, available_cells);
    if (cell_span <= group.cell_span) return group;

    var out = group;
    out.cell_span = cell_span;
    out.placement.advance_px = @max(out.placement.advance_px, @as(f32, @floatFromInt(@as(u32, cell_span) * @as(u32, cell_metrics.cell_w_px))));
    if (out.glyphs.len > 0) out.sprite_key = sprite_key.hashGlyphSequence(out.glyphs[0].face_id, out.glyphs, cell_span);
    return out;
}

fn desiredIconCells(group: contract.GlyphGroup, cell_w: u16) u8 {
    const max_cells: u8 = 5;
    const advance = @max(group.placement.advance_px, @as(f32, @floatFromInt(cell_w)));
    const raw = @as(u32, @intFromFloat(std.math.ceil(advance / @as(f32, @floatFromInt(cell_w)))));
    return @intCast(std.math.clamp(raw, @as(u32, @max(group.cell_span, 1)), @as(u32, max_cells)));
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

test "scene damage filters clean rows and carries scroll reuse pixels" {
    const color = contract.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
        .{ .text_id = .{ .value = 3 }, .first_cell = 3, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = color },
    };
    const groups = [_]contract.GlyphGroup{
        .{ .first_cell = 0, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 1 }, .kind = .normal },
        .{ .first_cell = 3, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 2 }, .kind = .normal },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 0, 1 };
    var owned = try buildSceneWithOptions(std.testing.allocator, &cells, &groups, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 2, .rows = 2 }, .{
        .damage = .{
            .full = false,
            .scroll_up_rows = 1,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    });
    defer owned.deinit();
    try std.testing.expect(!owned.scene.full_redraw);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.scroll_up_px);
    try std.testing.expectEqual(@as(usize, 2), owned.scene.background_draws.len);
    try std.testing.expectEqual(@as(usize, 1), owned.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u32, 3), owned.scene.sprite_draws[0].first_cell);
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
        .underline_color = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
        .underline = true,
        .strikethrough = true,
    }};
    var owned = try buildScene(std.testing.allocator, &cells, &.{}, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 }, .{ .cols = 4, .rows = 1 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 2), owned.scene.decoration_draws.len);
    try std.testing.expectEqual(contract.DecorationKind.underline, owned.scene.decoration_draws[0].kind);
    try std.testing.expectEqual(@as(i32, 8), owned.scene.decoration_draws[0].x_px);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.decoration_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 9), owned.scene.decoration_draws[0].color.r);
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
    try std.testing.expectEqual(@as(i32, 8), owned.scene.sprite_draws[0].x_px);
    try std.testing.expectEqual(@as(i32, 0), owned.scene.sprite_draws[0].y_px);
    try std.testing.expectEqual(@as(f32, 8), owned.scene.sprite_draws[0].placement.advance_px);
}

test "scene extends wide icon groups into available blank cells" {
    const color = contract.Rgba8{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const cells = [_]contract.RenderableCell{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .style = .regular, .presentation = .any, .fg = color, .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    };
    const glyph = contract.GlyphInstance{ .face_id = .{ .value = 1 }, .glyph_id = 7, .cluster_index = 0, .x_advance_px = 16 };
    const icon = contract.GlyphGroup{
        .first_cell = 0,
        .cell_span = 1,
        .glyphs = &.{glyph},
        .placement = .{ .advance_px = 16 },
        .sprite_key = .{ .value = 7 },
        .kind = .icon,
    };
    const next = contract.GlyphGroup{ .first_cell = 2, .cell_span = 1, .glyphs = &.{}, .sprite_key = .{ .value = 9 }, .kind = .normal };
    var owned = try buildScene(std.testing.allocator, &cells, &.{ icon, next }, &.{}, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }, .{ .cols = 3, .rows = 1 });
    defer owned.deinit();
    try std.testing.expectEqual(@as(u16, 16), owned.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), owned.scene.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u16, 16), owned.scene.raster_requests[0].width_px);
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
