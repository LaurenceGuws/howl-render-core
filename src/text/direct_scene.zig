const std = @import("std");
const contract = @import("contract.zig");
const scene = @import("scene.zig");

pub const Damage = struct {
    full: bool,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,

    pub fn init(damage: scene.DamageInput, rows: u16) Damage {
        const valid = !damage.full and
            damage.dirty_rows.len == @as(usize, rows) and
            damage.dirty_cols_start.len == @as(usize, rows) and
            damage.dirty_cols_end.len == @as(usize, rows);
        return .{
            .full = !valid,
            .dirty_rows = if (valid) damage.dirty_rows else &.{},
            .dirty_cols_start = if (valid) damage.dirty_cols_start else &.{},
            .dirty_cols_end = if (valid) damage.dirty_cols_end else &.{},
        };
    }
};

pub const MergedBuffers = struct {
    clear_draws: []contract.TextClearDraw,
    cursor_draws: []contract.TextCursorDraw,
    background_draws: []contract.TextBackgroundDraw,
    sprite_draws: []contract.TextSpriteDraw,
    decoration_draws: []contract.TextDecorationDraw,
    missing: []contract.MissingGlyph,
};

pub fn rowDirty(damage: Damage, row: u16) bool {
    if (damage.full) return true;
    return @as(usize, row) < damage.dirty_rows.len and damage.dirty_rows[@intCast(row)];
}

pub fn includeSpan(damage: Damage, grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) bool {
    if (damage.full) return true;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row = @as(u16, @intCast(first_cell / cols));
    if (!rowDirty(damage, row)) return false;
    const start_col = @as(u16, @intCast(first_cell % cols));
    const end_col = start_col +| (@max(cell_span, 1) - 1);
    const dirty_start = damage.dirty_cols_start[@intCast(row)];
    const dirty_end = damage.dirty_cols_end[@intCast(row)];
    return !(end_col < dirty_start or start_col > dirty_end);
}

pub fn borrowScene(allocator: std.mem.Allocator, damage: Damage, direct: anytype) scene.OwnedTextScene {
    return .{ .allocator = allocator, .scene = .{
        .full_redraw = damage.full,
        .clear_draws = direct.clear_draws.items,
        .background_draws = direct.background_draws.items,
        .sprite_draws = direct.sprite_draws.items,
        .decoration_draws = direct.decoration_draws.items,
        .cursor_draws = direct.cursor_draws.items,
        .raster_requests = &.{},
        .missing = direct.missing.items,
    }, .owned = false };
}

pub fn installMergedScene(text_scene: *scene.OwnedTextScene, damage: Damage, merged: MergedBuffers) void {
    std.debug.assert(text_scene.owned);
    std.debug.assert(text_scene.scene.raster_requests.len <= text_scene.scene.sprite_draws.len);
    text_scene.allocator.free(text_scene.scene.clear_draws);
    text_scene.allocator.free(text_scene.scene.cursor_draws);
    text_scene.allocator.free(text_scene.scene.background_draws);
    text_scene.allocator.free(text_scene.scene.sprite_draws);
    text_scene.allocator.free(text_scene.scene.decoration_draws);
    text_scene.allocator.free(text_scene.scene.missing);
    text_scene.scene.full_redraw = damage.full;
    text_scene.scene.clear_draws = merged.clear_draws;
    text_scene.scene.cursor_draws = merged.cursor_draws;
    text_scene.scene.background_draws = merged.background_draws;
    text_scene.scene.sprite_draws = merged.sprite_draws;
    text_scene.scene.decoration_draws = merged.decoration_draws;
    text_scene.scene.missing = merged.missing;
}

pub fn appendBackgrounds(
    out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    var idx: usize = 0;
    while (idx < cells.len) {
        const cell = cells[idx];
        if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span) or cell.bg.a == 0) {
            idx += 1;
            continue;
        }
        const row = cell.first_cell / cols;
        var span_cell_count: u32 = @max(cell.cell_span, 1);
        var span_end = cell.first_cell + span_cell_count;
        var next = idx + 1;
        while (next < cells.len) : (next += 1) {
            const other = cells[next];
            if (!includeSpan(damage, grid_metrics, other.first_cell, other.cell_span)) break;
            if (!sameRgba8(cell.bg, other.bg)) break;
            if (other.first_cell / cols != row) break;
            if (other.first_cell != span_end) break;
            const other_span = @max(other.cell_span, 1);
            span_cell_count += other_span;
            span_end += other_span;
        }
        const col = cell.first_cell % cols;
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cell_count * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = cell.bg,
            .first_cell = cell.first_cell,
            .cell_span = @intCast(@min(span_cell_count, @as(u32, std.math.maxInt(u8)))),
        });
        idx = next;
    }
}

pub fn appendClears(
    out: *std.ArrayListUnmanaged(contract.TextClearDraw),
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    if (damage.full) return;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    var row: usize = 0;
    while (row < grid_metrics.rows and row < damage.dirty_rows.len) : (row += 1) {
        if (!damage.dirty_rows[row]) continue;
        const start_col = @min(damage.dirty_cols_start[row], @as(u16, @intCast(cols - 1)));
        const end_col = @min(damage.dirty_cols_end[row], @as(u16, @intCast(cols - 1)));
        if (end_col < start_col) continue;
        const span_cells = @as(u32, end_col - start_col) + 1;
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(start_col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cells * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .first_cell = @as(u32, @intCast(row)) * cols + @as(u32, start_col),
            .cell_span = @intCast(@min(span_cells, @as(u32, std.math.maxInt(u8)))),
        });
    }
}

pub fn appendCursor(
    out: *std.ArrayListUnmanaged(contract.TextCursorDraw),
    cursor: ?scene.CursorInput,
    cell_metrics: contract.CellMetrics,
    damage: Damage,
) void {
    const cursor_value = cursor orelse return;
    if (classifyCursorLead(damage, cursor_value) != .draw) return;
    const base_x: i32 = @as(i32, @intCast(cursor_value.cell_col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor_value.cell_row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const geom = cursorGeometry(cell_metrics);
    switch (cursorRoute(cursor_value.shape)) {
        .block => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color }),
        .beam => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color }),
        .underline => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - geom.underline_h_px)), .width_px = cell_metrics.cell_w_px, .height_px = geom.underline_h_px, .color = cursor_value.color }),
        .hollow_block => {
            const stroke = geom.hollow_stroke_px;
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - stroke)), .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x + @as(i32, @intCast(cell_metrics.cell_w_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color });
        },
    }
}

pub fn appendDecorations(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: Damage,
) void {
    const font_metrics = defaultFontMetrics(cell_metrics);
    const deco = decorationGeometry(cell_metrics, font_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (classifyDecorationLead(damage, grid_metrics, cell) != .draw) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline) {
            const color = if (cell.underline_color.a == 0) cell.fg else cell.underline_color;
            switch (cell.underline_style) {
                .straight => appendDecoration(out, .underline, cell, base_x, base_y + deco.underline_y_px, width_px, deco.underline_h_px, color),
                .double => {
                    const gap: i32 = @max(@as(i32, @intCast(deco.underline_h_px)), 1);
                    appendDecoration(out, .underline, cell, base_x, @max(base_y + deco.underline_y_px - gap - @as(i32, @intCast(deco.underline_h_px)), 0), width_px, deco.underline_h_px, color);
                    appendDecoration(out, .underline, cell, base_x, base_y + deco.underline_y_px, width_px, deco.underline_h_px, color);
                },
                .dotted => {
                    const dot: u16 = @max(deco.underline_h_px, 1);
                    const step: u16 = @max(dot * 2, 2);
                    var off: u16 = 0;
                    while (off < width_px) : (off += step) {
                        appendDecoration(out, .underline_dotted, cell, base_x + @as(i32, @intCast(off)), base_y + deco.underline_y_px, @min(dot, width_px - off), deco.underline_h_px, color);
                    }
                },
                .dashed => {
                    const dash: u16 = @max(width_px / 3, @as(u16, 2));
                    const step: u16 = @max(dash + 2, 3);
                    var off: u16 = 0;
                    while (off < width_px) : (off += step) {
                        appendDecoration(out, .underline_dashed, cell, base_x + @as(i32, @intCast(off)), base_y + deco.underline_y_px, @min(dash, width_px - off), deco.underline_h_px, color);
                    }
                },
                .curly => unreachable,
            }
        }
        if (cell.strikethrough) appendDecoration(out, .strikethrough, cell, base_x, base_y + deco.strikethrough_y_px, width_px, deco.strikethrough_h_px, cell.fg);
    }
}

const CursorLead = enum(u2) { skip, draw };
const CursorRoute = enum(u2) { block, beam, underline, hollow_block };
const DecorationLead = enum(u2) { skip, draw };

fn classifyCursorLead(damage: Damage, cursor: scene.CursorInput) CursorLead {
    if (!damage.full and !rowDirty(damage, cursor.cell_row)) return .skip;
    return .draw;
}

fn cursorRoute(shape: scene.CursorShape) CursorRoute {
    return switch (shape) {
        .block => .block,
        .beam => .beam,
        .underline => .underline,
        .hollow_block => .hollow_block,
    };
}

fn classifyDecorationLead(damage: Damage, grid_metrics: contract.GridMetrics, cell: contract.RenderableCell) DecorationLead {
    if (!cell.underline and !cell.strikethrough) return .skip;
    if (!includeSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) return .skip;
    return .draw;
}

fn appendDecoration(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    kind: contract.DecorationKind,
    cell: contract.RenderableCell,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: contract.Rgba8,
) void {
    out.appendAssumeCapacity(.{
        .kind = kind,
        .x_px = x_px,
        .y_px = y_px,
        .width_px = width_px,
        .height_px = height_px,
        .color = color,
        .first_cell = cell.first_cell,
        .cell_span = cell.cell_span,
    });
}

fn sameRgba8(a: contract.Rgba8, b: contract.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn defaultFontMetrics(cell_metrics: contract.CellMetrics) contract.FontMetrics {
    const thickness: f32 = @floatFromInt(scaledDecorationThickness(cell_metrics.cell_h_px));
    const baseline: f32 = @floatFromInt(cell_metrics.baseline_px);
    return .{
        .ascent_px = baseline,
        .descent_px = @floatFromInt(@as(i32, cell_metrics.cell_h_px) - @as(i32, cell_metrics.baseline_px)),
        .line_gap_px = 0,
        .underline_pos_px = baseline + thickness,
        .underline_thickness_px = thickness,
        .strikethrough_pos_px = baseline / 2.0,
        .strikethrough_thickness_px = thickness,
    };
}

fn decorationGeometry(cell_metrics: contract.CellMetrics, font_metrics: contract.FontMetrics) contract.DecorationGeometry {
    return .{
        .underline_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.underline_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .underline_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.underline_thickness_px))), 1),
        .strikethrough_y_px = std.math.clamp(@as(i32, @intFromFloat(@round(font_metrics.strikethrough_pos_px))), 0, @as(i32, @intCast(cell_metrics.cell_h_px - 1))),
        .strikethrough_h_px = @max(@as(u16, @intFromFloat(@round(font_metrics.strikethrough_thickness_px))), 1),
    };
}

fn cursorGeometry(cell_metrics: contract.CellMetrics) contract.CursorGeometry {
    return .{
        .beam_w_px = @max(cell_metrics.cell_w_px / 8, 1),
        .underline_h_px = scaledDecorationThickness(cell_metrics.cell_h_px),
        .hollow_stroke_px = 2,
    };
}

fn scaledDecorationThickness(cell_h_px: u16) u16 {
    return @intCast(@max(@divTrunc(@as(u32, @max(cell_h_px, 1)) + 15, 16), 1));
}
