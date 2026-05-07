//! Responsibility: build backend-neutral render batches from frame input.
//! Ownership: render-core batch generation policy.
//! Reason: keep command ordering shared while atlas residency stays backend-owned.

const std = @import("std");
const rgba = @import("rgba.zig");
const text_contract = @import("text_contract.zig");
const metrics = @import("text_stack/metrics.zig");

/// Shared backend configuration used for batch generation and validation.
pub const BackendConfig = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    font_size_px: u16 = 16,
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
pub const Rgba8 = rgba.Rgba8;

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
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
    full_redraw: bool,
};

/// Backend-neutral render batch payload.
pub const RenderBatch = struct {
    surface_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    full_redraw: bool = true,
    scroll_up_rows: u16 = 0,
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
            .full_redraw = self.full_redraw,
        };
    }
};

/// Input cell payload used during batch generation.
pub const CellInput = struct {
    codepoint: u21,
    fg: Rgba8,
    bg: Rgba8,
    underline_color: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    underline_style: UnderlineStyle = .straight,
    underline: bool = false,
    strikethrough: bool = false,
    continuation: bool = false,
};

pub const CellDecorations = struct {
    rects: [16]FillRect = undefined,
    len: usize = 0,
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
    damage: Damage = .{},
};

pub const Damage = struct {
    full: bool = true,
    scroll_up_rows: u16 = 0,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
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
            try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2510 => { // ┐
            try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2514 => { // └
            try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2518 => { // ┘
            try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x251C => { // ├
            try appendHRight(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2524 => { // ┤
            try appendHLeft(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendV(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x252C => { // ┬
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVBottom(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x2534 => { // ┴
            try appendH(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_h, cell.fg);
            try appendVTop(fills, allocator, cell_x, cell_y, cell_w, cell_h, th_v, cell.fg);
            return true;
        },
        0x253C => { // ┼
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

fn appendHLeft(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const yy = y + @as(i32, @intCast((h - t) / 2));
    const ww = @max(@divFloor(w + t, 2), 1);
    try fills.append(allocator, .{ .x = x, .y = yy, .width = ww, .height = t, .color = color });
}

fn appendHRight(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const yy = y + @as(i32, @intCast((h - t) / 2));
    const xx = x + @as(i32, @intCast((w - t) / 2));
    const ww = w - @as(u16, @intCast((w - t) / 2));
    try fills.append(allocator, .{ .x = xx, .y = yy, .width = ww, .height = t, .color = color });
}

fn appendHBottom(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    try fills.append(allocator, .{ .x = x, .y = y + @as(i32, @intCast(h - t)), .width = w, .height = t, .color = color });
}

fn appendV(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const xx = x + @as(i32, @intCast((w - t) / 2));
    try fills.append(allocator, .{ .x = xx, .y = y, .width = t, .height = h, .color = color });
}

fn appendVTop(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const xx = x + @as(i32, @intCast((w - t) / 2));
    const hh = @max(@divFloor(h + t, 2), 1);
    try fills.append(allocator, .{ .x = xx, .y = y, .width = t, .height = hh, .color = color });
}

fn appendVBottom(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    const xx = x + @as(i32, @intCast((w - t) / 2));
    const yy = y + @as(i32, @intCast((h - t) / 2));
    const hh = h - @as(u16, @intCast((h - t) / 2));
    try fills.append(allocator, .{ .x = xx, .y = yy, .width = t, .height = hh, .color = color });
}

fn appendVRight(fills: *std.ArrayList(FillRect), allocator: std.mem.Allocator, x: i32, y: i32, w: u16, h: u16, t: u16, color: Rgba8) !void {
    try fills.append(allocator, .{ .x = x + @as(i32, @intCast(w - t)), .y = y, .width = t, .height = h, .color = color });
}

fn sameColor(a: Rgba8, b: Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

pub fn cellDecorations(cell: CellInput, cell_x: i32, cell_y: i32, cell_px: CellSize) CellDecorations {
    var out = CellDecorations{};
    if (!cell.underline and !cell.strikethrough) return out;

    const cell_metrics = text_contract.CellMetrics{
        .cell_w_px = cell_px.width,
        .cell_h_px = cell_px.height,
        .baseline_px = @intCast(@max(cell_px.height - @divFloor(cell_px.height, 5), 1)),
    };
    const font_metrics = metrics.defaultFontMetrics(cell_metrics);
    const deco = metrics.decorationGeometry(cell_metrics, font_metrics);

    if (cell.underline) {
        const underline_color = if (cell.underline_color.a == 0) cell.fg else cell.underline_color;
        appendUnderlineDecorations(&out, cell_x, cell_y + deco.underline_y_px, cell_px.width, deco.underline_h_px, underline_color, cell.underline_style);
    }
    if (cell.strikethrough) {
        out.rects[out.len] = .{
            .x = cell_x,
            .y = cell_y + deco.strikethrough_y_px,
            .width = cell_px.width,
            .height = deco.strikethrough_h_px,
            .color = cell.fg,
        };
        out.len += 1;
    }
    return out;
}

fn appendDecoration(out: *CellDecorations, x: i32, y: i32, width: u16, height: u16, color: Rgba8) void {
    if (out.len >= out.rects.len) return;
    out.rects[out.len] = .{ .x = x, .y = y, .width = width, .height = height, .color = color };
    out.len += 1;
}

fn appendUnderlineDecorations(out: *CellDecorations, x: i32, y: i32, width: u16, height: u16, color: Rgba8, style: UnderlineStyle) void {
    switch (style) {
        .straight => appendDecoration(out, x, y, width, height, color),
        .double => {
            const gap: i32 = @max(@as(i32, @intCast(height)), 1);
            appendDecoration(out, x, @max(y - gap - @as(i32, @intCast(height)), 0), width, height, color);
            appendDecoration(out, x, y, width, height, color);
        },
        .dotted => {
            const dot: u16 = @max(height, 1);
            const step: u16 = @max(dot * 2, 2);
            var off: u16 = 0;
            while (off < width) : (off += step) appendDecoration(out, x + @as(i32, @intCast(off)), y, @min(dot, width - off), height, color);
        },
        .dashed => {
            const dash: u16 = @max(width / 3, @as(u16, 2));
            const step: u16 = @max(dash + 2, 3);
            var off: u16 = 0;
            while (off < width) : (off += step) appendDecoration(out, x + @as(i32, @intCast(off)), y, @min(dash, width - off), height, color);
        },
        .curly => {
            const seg: u16 = @max(height * 2, 2);
            const y_high = @max(y - @as(i32, @intCast(height)), 0);
            const y_low = y + @as(i32, @intCast(height));
            var off: u16 = 0;
            var high = true;
            while (off < width) : (off += seg) {
                appendDecoration(out, x + @as(i32, @intCast(off)), if (high) y_high else y_low, @min(seg, width - off), height, color);
                high = !high;
            }
        },
    }
}

fn appendBackgroundSpans(
    fills: *std.ArrayList(FillRect),
    allocator: std.mem.Allocator,
    frame: VtState,
    row: usize,
    col_start: usize,
    col_end_exclusive: usize,
    visible: usize,
) !void {
    var span_start = col_start;
    while (span_start < col_end_exclusive) {
        const first_idx = row * @as(usize, frame.grid.cols) + span_start;
        if (first_idx >= visible) break;
        const bg = frame.grid.cells[first_idx].bg;
        var span_end = span_start + 1;
        while (span_end < col_end_exclusive) : (span_end += 1) {
            const idx = row * @as(usize, frame.grid.cols) + span_end;
            if (idx >= visible or !sameColor(frame.grid.cells[idx].bg, bg)) break;
        }
        try fills.append(allocator, .{
            .x = @intCast(span_start * @as(usize, frame.cell_px.width)),
            .y = @intCast(row * @as(usize, frame.cell_px.height)),
            .width = @intCast((span_end - span_start) * @as(usize, frame.cell_px.width)),
            .height = frame.cell_px.height,
            .color = bg,
        });
        span_start = span_end;
    }
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
    const full_redraw = frame.damage.full or frame.damage.dirty_rows.len != @as(usize, frame.grid.rows) or frame.damage.dirty_cols_start.len != @as(usize, frame.grid.rows) or frame.damage.dirty_cols_end.len != @as(usize, frame.grid.rows);
    const scroll_up_rows = if (full_redraw) 0 else @min(frame.damage.scroll_up_rows, frame.grid.rows);

    var fills = try std.ArrayList(FillRect).initCapacity(allocator, visible);
    errdefer fills.deinit(allocator);

    var glyphs = try std.ArrayList(GlyphQuad).initCapacity(allocator, visible);
    errdefer glyphs.deinit(allocator);

    var uploads = try std.ArrayList(AtlasUpload).initCapacity(allocator, visible);
    errdefer uploads.deinit(allocator);

    var uploaded_codepoints = std.AutoHashMap(u21, void).init(allocator);
    defer uploaded_codepoints.deinit();

    const glyphs_enabled = capability.supports_glyph_quads and capability.max_atlas_slots > 0;

    for (0..frame.grid.rows) |row| {
        if (!full_redraw and !frame.damage.dirty_rows[row]) continue;
        const col_start: usize = if (full_redraw) 0 else @as(usize, frame.damage.dirty_cols_start[row]);
        const col_end_exclusive: usize = if (full_redraw) frame.grid.cols else @min(@as(usize, frame.damage.dirty_cols_end[row]) + 1, @as(usize, frame.grid.cols));
        if (col_start >= col_end_exclusive) continue;
        try appendBackgroundSpans(&fills, allocator, frame, row, col_start, col_end_exclusive, visible);
        for (col_start..col_end_exclusive) |col| {
            const idx = row * @as(usize, frame.grid.cols) + col;
            if (idx >= visible) break;
            const cell = frame.grid.cells[idx];

            const cell_x: i32 = @intCast(col * @as(usize, frame.cell_px.width));
            const cell_y: i32 = @intCast(row * @as(usize, frame.cell_px.height));

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
            const decorations = cellDecorations(cell, cell_x, cell_y, frame.cell_px);
            for (decorations.rects[0..decorations.len]) |rect| {
                try fills.append(allocator, rect);
            }
            if (procedural) continue;

            if (glyphs_enabled and cell.codepoint > 0x20 and !cell.continuation) {
                if (!uploaded_codepoints.contains(cell.codepoint)) {
                    try uploaded_codepoints.put(cell.codepoint, {});
                    try uploads.append(allocator, .{
                        .codepoint = cell.codepoint,
                        .width = frame.cell_px.width,
                        .height = frame.cell_px.height,
                    });
                }
                try glyphs.append(allocator, .{
                    .x = cell_x,
                    .y = cell_y,
                    .width = frame.cell_px.width,
                    .height = frame.cell_px.height,
                    .codepoint = cell.codepoint,
                    .fg = cell.fg,
                });
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
            .full_redraw = full_redraw,
            .scroll_up_rows = scroll_up_rows,
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
    AtlasCapacityExceeded,
    CursorOutOfBounds,
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
    if (batch.scroll_up_rows > 0 and batch.scroll_up_rows >= batch.grid.rows) {
        return error.CellMismatch;
    }
    if (!capability.supports_fill_rect and batch.fills.len > 0) {
        return error.FillUnsupported;
    }
    if (!capability.supports_glyph_quads and batch.glyphs.len > 0) {
        return error.GlyphUnsupported;
    }
    if (batch.glyphs.len > 0 and capability.max_atlas_slots == 0) {
        return error.AtlasCapacityExceeded;
    }
    if (batch.atlas_uploads.len > capability.max_atlas_slots) {
        return error.AtlasCapacityExceeded;
    }
    if (batch.cursor) |cursor| {
        if (cursor.cell_col >= batch.grid.cols or cursor.cell_row >= batch.grid.rows) {
            return error.CursorOutOfBounds;
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

test "render_batch: empty grid produces zero glyphs and row background spans" {
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
    try std.testing.expectEqual(@as(usize, 2), owned.batch.fills.len);
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
    try std.testing.expectEqual(@as(usize, 1), owned.batch.fills.len);
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
    try std.testing.expectEqual(@as(usize, 1), owned.batch.fills.len);
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

test "render_batch: exactly at capacity keeps all unique glyph uploads" {
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
}

test "render_batch: over capacity still emits glyphs and deduped uploads" {
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

    try std.testing.expectEqual(@as(usize, 4), owned.batch.glyphs.len);
    try std.testing.expectEqual(@as(usize, 3), owned.batch.atlas_uploads.len);
    try std.testing.expectEqual(@as(u21, 'A'), owned.batch.glyphs[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), owned.batch.glyphs[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), owned.batch.glyphs[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), owned.batch.glyphs[3].codepoint);
}

test "render_batch: same-background cells merge into row spans" {
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

    try std.testing.expectEqual(@as(usize, 2), owned.batch.fills.len);
    try std.testing.expectEqual(@as(usize, 3), owned.batch.glyphs.len);
}

test "render_batch: background spans split on color changes" {
    const cells = [_]CellInput{
        makeCell(0, white, black), makeCell(0, white, black),
        makeCell(0, white, red),   makeCell(0, white, black),
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 32, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 4, .rows = 1 },
    }, testCapability(8));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 3), owned.batch.fills.len);
    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[0].x);
    try std.testing.expectEqual(@as(u16, 16), owned.batch.fills[0].width);
    try std.testing.expectEqual(@as(i32, 16), owned.batch.fills[1].x);
    try std.testing.expectEqual(@as(u16, 8), owned.batch.fills[1].width);
    try std.testing.expectEqual(@as(i32, 24), owned.batch.fills[2].x);
    try std.testing.expectEqual(@as(u16, 8), owned.batch.fills[2].width);
}

test "render_batch: underline and strikethrough produce decoration fills" {
    const underline_color = Rgba8{ .r = 220, .g = 40, .b = 60, .a = 255 };
    const cells = [_]CellInput{.{
        .codepoint = 'A',
        .fg = white,
        .bg = black,
        .underline_color = underline_color,
        .underline = true,
        .strikethrough = true,
    }};
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
    }, testCapability(4));
    defer owned.deinit();

    const cell_metrics = text_contract.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13 };
    const deco = metrics.decorationGeometry(cell_metrics, metrics.defaultFontMetrics(cell_metrics));

    try std.testing.expectEqual(@as(usize, 3), owned.batch.fills.len);
    try std.testing.expectEqual(deco.underline_y_px, owned.batch.fills[1].y);
    try std.testing.expectEqual(underline_color.r, owned.batch.fills[1].color.r);
    try std.testing.expectEqual(deco.strikethrough_y_px, owned.batch.fills[2].y);
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

test "validation rejects glyphs without atlas capacity" {
    const config = BackendConfig{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = BackendCapability{
        .max_atlas_slots = 0,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const glyphs = [_]GlyphQuad{.{
        .x = 0,
        .y = 0,
        .width = 8,
        .height = 16,
        .codepoint = 'A',
        .fg = white,
    }};
    const batch = RenderBatch{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .glyphs = &glyphs,
    };

    try std.testing.expectError(error.AtlasCapacityExceeded, validateRenderBatch(config, cap, batch));
}

test "validation rejects atlas uploads over capacity" {
    const config = BackendConfig{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = BackendCapability{
        .max_atlas_slots = 1,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const uploads = [_]AtlasUpload{
        .{ .codepoint = 'A', .width = 8, .height = 16 },
        .{ .codepoint = 'B', .width = 8, .height = 16 },
    };
    const batch = RenderBatch{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .atlas_uploads = &uploads,
    };

    try std.testing.expectError(error.AtlasCapacityExceeded, validateRenderBatch(config, cap, batch));
}

test "validation rejects cursor outside grid" {
    const config = BackendConfig{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = BackendCapability{
        .max_atlas_slots = 4,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const batch = RenderBatch{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .cell_col = 2, .cell_row = 0, .shape = .block, .color = white },
    };

    try std.testing.expectError(error.CursorOutOfBounds, validateRenderBatch(config, cap, batch));
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
        try std.testing.expectEqual(ga.codepoint, gb.codepoint);
    }
    for (a.batch.atlas_uploads, b.batch.atlas_uploads) |ua, ub| {
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

test "render_batch: tee glyphs only draw vertical half stems" {
    const cells = [_]CellInput{
        makeCell(0x252C, white, black), // ┬
        makeCell(0x2534, white, black), // ┴
        makeCell(0x253C, white, black), // ┼
    };
    var owned = try renderBatch(std.testing.allocator, .{
        .surface_px = .{ .width = 24, .height = 24 },
        .cell_px = .{ .width = 8, .height = 8 },
        .grid = .{ .cells = &cells, .cols = 3, .rows = 1 },
    }, testCapability(8));
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 7), owned.batch.fills.len);
    const tee_down_v = owned.batch.fills[2];
    const tee_up_v = owned.batch.fills[4];
    const cross_v = owned.batch.fills[6];

    try std.testing.expectEqual(@as(i32, 3), tee_down_v.x);
    try std.testing.expectEqual(@as(i32, 3), tee_down_v.y);
    try std.testing.expectEqual(@as(c_int, 5), tee_down_v.height);
    try std.testing.expectEqual(@as(i32, 11), tee_up_v.x);
    try std.testing.expectEqual(@as(i32, 0), tee_up_v.y);
    try std.testing.expectEqual(@as(c_int, 4), tee_up_v.height);
    try std.testing.expectEqual(@as(i32, 19), cross_v.x);
    try std.testing.expectEqual(@as(i32, 0), cross_v.y);
    try std.testing.expectEqual(@as(c_int, 8), cross_v.height);
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
    try std.testing.expectEqual(@as(u16, 16), owned.batch.fills[0].width);
    try std.testing.expectEqual(@as(i32, 0), owned.batch.fills[1].x);
    try std.testing.expectEqual(@as(i32, 16), owned.batch.fills[1].y);
    try std.testing.expectEqual(@as(u16, 16), owned.batch.fills[1].width);
}
