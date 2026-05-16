
const std = @import("std");
const Render = @import("howl_render.zig");
const SurfaceText = Render.SurfaceText;
const surface = @import("frame/surface.zig");
const text_support = @import("text/ft_hb_support.zig");

pub const HowlRenderSurfaceText = opaque {};
pub const HowlRenderPreparedSurfaceObject = opaque {};

pub const SurfaceTextHandle = ?*HowlRenderSurfaceText;
pub const PreparedSurfaceHandle = ?*HowlRenderPreparedSurfaceObject;

const SurfaceTextOwner = struct {
    session: SurfaceText,
    config: Render.SurfaceTextConfig,
    font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayList([:0]u8) = .empty,
    clear_draws: std.ArrayList(FfiColorDraw) = .empty,
    background_draws: std.ArrayList(FfiColorDraw) = .empty,
    sprite_draws: std.ArrayList(FfiSpriteDraw) = .empty,
    decoration_draws: std.ArrayList(FfiDecorationDraw) = .empty,
    cursor_draws: std.ArrayList(FfiColorDraw) = .empty,
    raster_uploads: std.ArrayList(FfiRasterUpload) = .empty,

    fn create(config: Render.SurfaceTextConfig) ?*SurfaceTextOwner {
        const owner = std.heap.c_allocator.create(SurfaceTextOwner) catch return null;
        owner.* = .{ .session = SurfaceText.init(), .config = config };
        return owner;
    }

    fn destroy(self: *SurfaceTextOwner) void {
        if (self.font_path) |path| std.heap.c_allocator.free(path);
        self.font_path = null;
        for (self.fallback_font_paths.items) |path| std.heap.c_allocator.free(path);
        self.fallback_font_paths.deinit(std.heap.c_allocator);
        self.clear_draws.deinit(std.heap.c_allocator);
        self.background_draws.deinit(std.heap.c_allocator);
        self.sprite_draws.deinit(std.heap.c_allocator);
        self.decoration_draws.deinit(std.heap.c_allocator);
        self.cursor_draws.deinit(std.heap.c_allocator);
        self.raster_uploads.deinit(std.heap.c_allocator);
        self.session.deinit();
        std.heap.c_allocator.destroy(self);
    }

    fn resetPreparedViews(self: *SurfaceTextOwner) void {
        self.clear_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.sprite_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.raster_uploads.clearRetainingCapacity();
    }

    fn invalidateTextState(self: *SurfaceTextOwner) void {
        text_support.resetLoadedFace(&self.session);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
    }
};

const PreparedSurfaceOwner = struct {
    session_owner: *SurfaceTextOwner,
    prepared: Render.PreparedSurface,
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    required_surface_epoch: u64,
    render_px: FfiPixelSize,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
    prepare_metrics: FfiSurfaceMetrics,
    damage_kind: u8,
    full_redraw: u8,
    scroll_up_px: u16,
    clear_draws: []FfiColorDraw = &.{},
    background_draws: []FfiColorDraw = &.{},
    sprite_batches: []FfiSpriteBatch = &.{},
    sprite_instances: []FfiSpriteInstance = &.{},
    decoration_draws: []FfiDecorationDraw = &.{},
    cursor_draws: []FfiColorDraw = &.{},
    surface_damage_rects: []FfiRect = &.{},
    buffer_damage_rects: []FfiRect = &.{},
    uploads: []FfiUploadOp = &.{},
    pixel_blob: []u8 = &.{},
    missing_glyphs: u64,
    resolve_metrics: FfiSurfaceMetrics,

    fn destroy(self: *PreparedSurfaceOwner) void {
        self.prepared.deinit();
        freeOwnedSlice(FfiColorDraw, &self.clear_draws);
        freeOwnedSlice(FfiColorDraw, &self.background_draws);
        freeOwnedSlice(FfiSpriteBatch, &self.sprite_batches);
        freeOwnedSlice(FfiSpriteInstance, &self.sprite_instances);
        freeOwnedSlice(FfiDecorationDraw, &self.decoration_draws);
        freeOwnedSlice(FfiColorDraw, &self.cursor_draws);
        freeOwnedSlice(FfiRect, &self.surface_damage_rects);
        freeOwnedSlice(FfiRect, &self.buffer_damage_rects);
        freeOwnedSlice(FfiUploadOp, &self.uploads);
        freeOwnedSlice(u8, &self.pixel_blob);
        std.heap.c_allocator.destroy(self);
    }
};

const OwnedSurfaceSource = struct {
    allocator: std.mem.Allocator,
    cells: []Render.SurfaceCell,
    dirty_rows: []bool = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    frame: Render.SurfaceFrameData,

    fn deinit(self: *OwnedSurfaceSource) void {
        self.allocator.free(self.cells);
        if (self.dirty_rows.len > 0) self.allocator.free(self.dirty_rows);
        if (self.dirty_cols_start.len > 0) self.allocator.free(self.dirty_cols_start);
        if (self.dirty_cols_end.len > 0) self.allocator.free(self.dirty_cols_end);
        self.* = undefined;
    }
};

pub const HowlRenderCallStatus = enum(c_int) {
    ok = 0,
    missing_handle = -1,
    invalid_argument = -2,
    failed = -3,
};

pub const HowlRenderPrepareStatus = enum(c_int) {
    idle = 0,
    ready = 1,
    failed = -3,
};

pub const HowlRenderSubmitStatus = enum(c_int) {
    idle = 0,
    rendered = 1,
    stale = 2,
    needs_prepare = 3,
    failed = -3,
};

pub const FfiPixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiCellSize = extern struct {
    width: u16,
    height: u16,
};

pub const FfiRgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const FfiGridSize = extern struct {
    cols: u16,
    rows: u16,
};

pub const FfiColorDraw = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiSpriteDraw = extern struct {
    slot: u32,
    key: u64,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiDecorationDraw = extern struct {
    kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: FfiRgba8,
};

pub const FfiRasterBounds = extern struct {
    x_px: u16,
    y_px: u16,
    width_px: u16,
    height_px: u16,
};

pub const FfiRasterUpload = extern struct {
    slot: u32,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    visual_bounds: FfiRasterBounds,
    pixels_ptr: [*c]const u8,
    pixels_len: usize,
};

pub const FfiColorDrawSpan = extern struct {
    ptr: [*c]const FfiColorDraw,
    len: usize,
};

pub const FfiCellSpan = extern struct {
    ptr: [*c]const FfiCell,
    len: usize,
};

pub const FfiSpriteDrawSpan = extern struct {
    ptr: [*c]const FfiSpriteDraw,
    len: usize,
};

pub const FfiDecorationDrawSpan = extern struct {
    ptr: [*c]const FfiDecorationDraw,
    len: usize,
};

pub const FfiRasterUploadSpan = extern struct {
    ptr: [*c]const FfiRasterUpload,
    len: usize,
};

pub const FfiRect = extern struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const FfiRectSpan = extern struct {
    ptr: [*c]const FfiRect,
    len: usize,
};

pub const FfiByteSpan = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

pub const FfiU16Span = extern struct {
    ptr: [*c]const u16,
    len: usize,
};

pub const FfiFrameGridResult = extern struct {
    status: c_int,
    grid: FfiGridSize,
};

pub const FfiFrameLayoutResult = extern struct {
    status: c_int,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
};

pub const FfiCellFlags = extern struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const FfiColor = extern struct {
    kind: u8,
    value: u32,
};

pub const FfiCellAttrs = extern struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
};

pub const FfiCell = extern struct {
    codepoint: u32,
    flags: FfiCellFlags,
    fg_color: FfiColor,
    bg_color: FfiColor,
    underline_color: FfiColor,
    underline_style: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    attrs: FfiCellAttrs,
    link_id: u32,
};

pub const FfiCursor = extern struct {
    row: u16,
    col: u16,
    visible: u8,
    shape: u8,
};

pub const FfiGeometry = extern struct {
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
};

pub const FfiGeometryResponse = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    changed: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    reserved3: u32 = 0,
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
    geometry_epoch: u64,
};

pub const FfiSurfaceQuery = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    render_px: FfiPixelSize,
    grid_px: FfiPixelSize,
    cell_px: FfiCellSize,
    font_size_px: u16,
    reserved0: u16 = 0,
    epoch: u64,
};

pub const FfiPrepareRequest = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    known_target_epoch: u64,
    target_valid: u8,
    damage_kind: u8,
    reserved0: u16 = 0,
};

pub const FfiPreparedFrame = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    required_base_seq: u64,
    required_target_epoch: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiSurfaceMetrics = extern struct {
    sync_us: u64,
    copy_us: u64,
    render_us: u64,
    glyphs: u64,
    fills: u64,
    clear_fills: u64,
    background_fills: u64,
    decoration_fills: u64,
    cursor_fills: u64,
    uploads: u64,
    face_checks: u64,
    face_cache_hits: u64,
    shape_requests: u64,
    shape_cache_hits: u64,
    fallback_hits: u64,
    fallback_misses: u64,
    missing_glyphs: u64,
};

pub const FfiSurfaceHandle = extern struct {
    texture_id: u32,
    width: u16,
    height: u16,
    epoch: u64,
};

pub const FfiPreparedSurfaceInfo = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    required_surface_epoch: u64,
    render_px: FfiPixelSize,
    cell_px: FfiCellSize,
    grid: FfiGridSize,
    prepare_metrics: FfiSurfaceMetrics,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiPreparedSurfaceDamagePlan = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    full_redraw: u8,
    reserved0: u8 = 0,
    scroll_up_px: u16,
    surface_damage_rects: FfiRectSpan,
    buffer_damage_rects: FfiRectSpan,
};

pub const FfiUploadOp = extern struct {
    sprite_key: u64,
    slot: u32,
    atlas_page: u16,
    pixel_format: u8,
    color_mode: u8,
    width_px: u16,
    height_px: u16,
    stride: u16,
    reserved0: u32 = 0,
    blob_offset: u64,
    blob_len: u64,
    visual_bounds: FfiRasterBounds,
};

pub const FfiUploadOpSpan = extern struct {
    ptr: [*c]const FfiUploadOp,
    len: usize,
};

pub const FfiPreparedSurfaceUploadPlan = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    uploads: FfiUploadOpSpan,
    pixel_blob: FfiByteSpan,
};

pub const FfiSpriteBatch = extern struct {
    atlas_page: u16,
    pass_kind: u8,
    reserved0: u8 = 0,
    first_instance: u32,
    instance_count: u32,
};

pub const FfiSpriteBatchSpan = extern struct {
    ptr: [*c]const FfiSpriteBatch,
    len: usize,
};

pub const FfiSpriteInstance = extern struct {
    slot: u32,
    sprite_key: u64,
    dst_x_px: i32,
    dst_y_px: i32,
    dst_width_px: u16,
    dst_height_px: u16,
    src_x_px: u16,
    src_y_px: u16,
    src_width_px: u16,
    src_height_px: u16,
    color: FfiRgba8,
};

pub const FfiSpriteInstanceSpan = extern struct {
    ptr: [*c]const FfiSpriteInstance,
    len: usize,
};

pub const FfiPreparedSurfaceDrawPlan = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    clear_draws: FfiColorDrawSpan,
    background_draws: FfiColorDrawSpan,
    sprite_batches: FfiSpriteBatchSpan,
    sprite_instances: FfiSpriteInstanceSpan,
    decoration_draws: FfiDecorationDrawSpan,
    cursor_draws: FfiColorDrawSpan,
};

pub const FfiPreparedSurfaceDiagnostics = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    missing_glyphs: u64,
    resolve_metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceExecutionInput = extern struct {
    surface: FfiSurfaceHandle,
    uploads_committed: u64,
    render_us: u64,
    scroll_reuse_applied: u8,
    content_valid: u8,
    reserved0: u16 = 0,
};

pub const FfiSurfaceSource = extern struct {
    cells: FfiCellSpan,
    cols: u16,
    rows: u16,
    scroll_row: u64,
    is_alternate_screen: u8,
    full_damage: u8,
    scroll_up_rows: u16,
    dirty_rows: FfiByteSpan,
    dirty_cols_start: FfiU16Span,
    dirty_cols_end: FfiU16Span,
    cursor: FfiCursor,
};

pub const FfiSurfaceFeedback = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    surface: FfiSurfaceHandle,
    metrics: FfiSurfaceMetrics,
};

pub const FfiSurfaceTextConfig = extern struct {
    surface_px: FfiPixelSize,
    font_size_px: u16,
    reserved0: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FfiPixelSize) == 4);
    std.debug.assert(@sizeOf(FfiCellSize) == 4);
    std.debug.assert(@sizeOf(FfiGridSize) == 4);
    std.debug.assert(@sizeOf(FfiRect) == 16);
    std.debug.assert(@sizeOf(FfiByteSpan) == 16);
    std.debug.assert(@sizeOf(FfiColor) == 8);
    std.debug.assert(@sizeOf(FfiCursor) == 6);
}

fn pixelIn(value: FfiPixelSize) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn rgba8Out(value: Render.Rgba8) FfiRgba8 {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
}

fn cellIn(value: FfiCellSize) surface.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn gridOut(value: surface.GridSize) FfiGridSize {
    return .{ .cols = value.cols, .rows = value.rows };
}

fn boolByte(value: bool) u8 {
    return if (value) 1 else 0;
}

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
}

fn colorIn(value: FfiColor) Render.SurfaceColor {
    return .{
        .kind = switch (value.kind) {
            0 => .default,
            1 => .indexed,
            else => .rgb,
        },
        .value = @truncate(value.value),
    };
}

fn cellValueIn(value: FfiCell) Render.SurfaceCell {
    return .{
        .codepoint = @intCast(value.codepoint),
        .flags = .{ .continuation = value.flags.continuation != 0 },
        .fg_color = colorIn(value.fg_color),
        .bg_color = colorIn(value.bg_color),
        .underline_color = colorIn(value.underline_color),
        .underline_style = underlineStyleIn(value.underline_style),
        .attrs = .{
            .bold = value.attrs.bold != 0,
            .dim = value.attrs.dim != 0,
            .italic = value.attrs.italic != 0,
            .underline = value.attrs.underline != 0,
            .underline_color_set = value.attrs.underline_color_set != 0,
            .blink = value.attrs.blink != 0,
            .inverse = value.attrs.inverse != 0,
            .invisible = value.attrs.invisible != 0,
            .strikethrough = value.attrs.strikethrough != 0,
        },
        .link_id = value.link_id,
    };
}

fn cursorIn(value: FfiCursor) Render.SurfaceCursorInfo {
    return .{
        .row = value.row,
        .col = value.col,
        .visible = value.visible != 0,
        .shape = switch (value.shape) {
            1 => .underline,
            2 => .beam,
            3 => .hollow_block,
            else => .block,
        },
    };
}

fn geometryIn(value: FfiGeometry) Render.Geometry {
    return .{
        .render_px = pixelIn(value.render_px),
        .grid_px = pixelIn(value.grid_px),
        .cell_px = cellInSize(value.cell_px),
    };
}

fn cellInSize(value: FfiCellSize) surface.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn geometryOut(value: surface.GeometryResponse) FfiGeometryResponse {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .changed = boolByte(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn surfaceQueryOut(value: Render.SurfaceQuery) FfiSurfaceQuery {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn surfaceQueryIn(value: FfiSurfaceQuery) Render.SurfaceQuery {
    return .{
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn surfaceSourceIn(allocator: std.mem.Allocator, value: FfiSurfaceSource) !OwnedSurfaceSource {
    const cell_count = @as(usize, value.cols) * @as(usize, value.rows);
    if (value.cells.len < cell_count) return error.InvalidSurfaceSource;
    const cells = try allocator.alloc(Render.SurfaceCell, cell_count);
    errdefer allocator.free(cells);
    for (cells, 0..) |*dst, idx| dst.* = cellValueIn(value.cells.ptr[idx]);
    const dirty_rows = try dirtyRowsIn(allocator, value.rows, value.dirty_rows);
    errdefer if (dirty_rows.len > 0) allocator.free(dirty_rows);
    const dirty_cols_start = try dirtyColsIn(allocator, value.rows, value.dirty_cols_start);
    errdefer if (dirty_cols_start.len > 0) allocator.free(dirty_cols_start);
    const dirty_cols_end = try dirtyColsIn(allocator, value.rows, value.dirty_cols_end);
    errdefer if (dirty_cols_end.len > 0) allocator.free(dirty_cols_end);
    return .{
        .allocator = allocator,
        .cells = cells,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
        .frame = .{
            .viewport = .{
                .cols = value.cols,
                .rows = value.rows,
                .scroll_row = @intCast(value.scroll_row),
                .is_alternate_screen = value.is_alternate_screen != 0,
            },
            .grid = .{ .cells = cells, .cols = value.cols, .rows = value.rows },
            .cursor = cursorIn(value.cursor),
            .damage = .{
                .full = value.full_damage != 0,
                .scroll_up_rows = value.scroll_up_rows,
                .dirty_rows = dirty_rows,
                .dirty_cols_start = dirty_cols_start,
                .dirty_cols_end = dirty_cols_end,
            },
        },
    };
}

fn dirtyRowsIn(allocator: std.mem.Allocator, rows: u16, span: FfiByteSpan) ![]bool {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    const out = try allocator.alloc(bool, rows);
    for (out, 0..) |*dst, idx| dst.* = span.ptr[idx] != 0;
    return out;
}

fn dirtyColsIn(allocator: std.mem.Allocator, rows: u16, span: FfiU16Span) ![]u16 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    return try allocator.dupe(u16, span.ptr[0..rows]);
}

fn surfaceMetricsOut(value: Render.RenderMetrics) FfiSurfaceMetrics {
    return .{
        .sync_us = value.sync_us,
        .copy_us = value.copy_us,
        .render_us = value.render_us,
        .glyphs = value.glyphs,
        .fills = value.fills,
        .clear_fills = value.clear_fills,
        .background_fills = value.background_fills,
        .decoration_fills = value.decoration_fills,
        .cursor_fills = value.cursor_fills,
        .uploads = value.uploads,
        .face_checks = value.face_checks,
        .face_cache_hits = value.face_cache_hits,
        .shape_requests = value.shape_requests,
        .shape_cache_hits = value.shape_cache_hits,
        .fallback_hits = value.fallback_hits,
        .fallback_misses = value.fallback_misses,
        .missing_glyphs = value.missing_glyphs,
    };
}

fn surfaceOut(value: Render.SurfaceHandle) FfiSurfaceHandle {
    return .{ .texture_id = value.texture_id, .width = value.width, .height = value.height, .epoch = value.epoch };
}

fn colorDrawSpanOut(items: []const FfiColorDraw) FfiColorDrawSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn spriteDrawSpanOut(items: []const FfiSpriteDraw) FfiSpriteDrawSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn decorationDrawSpanOut(items: []const FfiDecorationDraw) FfiDecorationDrawSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn rasterUploadSpanOut(items: []const FfiRasterUpload) FfiRasterUploadSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn rectSpanOut(items: []const FfiRect) FfiRectSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn byteSpanOut(items: []const u8) FfiByteSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn u16SpanOut(items: []const u16) FfiU16Span {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn uploadOpSpanOut(items: []const FfiUploadOp) FfiUploadOpSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn spriteBatchSpanOut(items: []const FfiSpriteBatch) FfiSpriteBatchSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn spriteInstanceSpanOut(items: []const FfiSpriteInstance) FfiSpriteInstanceSpan {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}

fn preparePreparedViews(owner: *SurfaceTextOwner, value: Render.PreparedSurface) !void {
    owner.resetPreparedViews();
    try owner.clear_draws.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.scene.scene.clear_draws.len);
    try owner.background_draws.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.scene.scene.background_draws.len);
    try owner.sprite_draws.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.scene.scene.sprite_draws.len);
    try owner.decoration_draws.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.scene.scene.decoration_draws.len);
    try owner.cursor_draws.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.scene.scene.cursor_draws.len);
    try owner.raster_uploads.ensureTotalCapacity(std.heap.c_allocator, value.text_frame.raster_plan.outputs.len);

    for (value.text_frame.scene.scene.clear_draws) |draw| {
        owner.clear_draws.appendAssumeCapacity(.{
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .color = rgba8Out(draw.color),
        });
    }
    for (value.text_frame.scene.scene.background_draws) |draw| {
        owner.background_draws.appendAssumeCapacity(.{
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .color = rgba8Out(draw.color),
        });
    }
    for (value.text_frame.scene.scene.sprite_draws) |draw| {
        owner.sprite_draws.appendAssumeCapacity(.{
            .slot = draw.sprite.slot,
            .key = draw.sprite.key.value,
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .color = rgba8Out(draw.color),
        });
    }
    for (value.text_frame.scene.scene.decoration_draws) |draw| {
        owner.decoration_draws.appendAssumeCapacity(.{
            .kind = @intFromEnum(draw.kind),
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .color = rgba8Out(draw.color),
        });
    }
    for (value.text_frame.scene.scene.cursor_draws) |draw| {
        owner.cursor_draws.appendAssumeCapacity(.{
            .x_px = draw.x_px,
            .y_px = draw.y_px,
            .width_px = draw.width_px,
            .height_px = draw.height_px,
            .color = rgba8Out(draw.color),
        });
    }
    for (value.text_frame.raster_plan.outputs) |output| {
        const slot = findSceneSpriteSlot(value.text_frame.scene.scene, output.key) orelse continue;
        const bounds = output.visualBounds();
        owner.raster_uploads.appendAssumeCapacity(.{
            .slot = slot,
            .key = output.key.value,
            .width_px = output.width_px,
            .height_px = output.height_px,
            .color_mode = @intFromEnum(output.color_mode),
            .visual_bounds = .{
                .x_px = bounds.x_px,
                .y_px = bounds.y_px,
                .width_px = bounds.width_px,
                .height_px = bounds.height_px,
            },
            .pixels_ptr = if (output.pixels.len == 0) null else output.pixels.ptr,
            .pixels_len = output.pixels.len,
        });
    }
}

fn packedStrideForOutput(output: Render.Text.Rasterizer.RasterSpriteOutput) u16 {
    const channels: u16 = if (output.color_mode == .color) 4 else 1;
    return @intCast(@as(u32, output.width_px) * @as(u32, channels));
}

fn pixelFormatForOutput(output: Render.Text.Rasterizer.RasterSpriteOutput) u8 {
    return switch (output.color_mode) {
        .alpha => 0,
        .color => 1,
    };
}

fn findUploadOp(uploads: []const FfiUploadOp, sprite_key: u64, slot: u32) ?FfiUploadOp {
    for (uploads) |upload| {
        if (upload.sprite_key == sprite_key and upload.slot == slot) return upload;
    }
    return null;
}

fn prepareInfoOut(owner: *PreparedSurfaceOwner) FfiPreparedSurfaceInfo {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .snapshot_seq = owner.snapshot_seq,
        .dirty_epoch = owner.dirty_epoch,
        .geometry_epoch = owner.geometry_epoch,
        .required_base_seq = owner.required_base_seq,
        .required_surface_epoch = owner.required_surface_epoch,
        .render_px = owner.render_px,
        .cell_px = owner.cell_px,
        .grid = owner.grid,
        .prepare_metrics = owner.prepare_metrics,
        .damage_kind = owner.damage_kind,
    };
}

fn prepareDamagePlanOut(owner: *PreparedSurfaceOwner) FfiPreparedSurfaceDamagePlan {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .full_redraw = owner.full_redraw,
        .scroll_up_px = owner.scroll_up_px,
        .surface_damage_rects = rectSpanOut(owner.surface_damage_rects),
        .buffer_damage_rects = rectSpanOut(owner.buffer_damage_rects),
    };
}

fn prepareUploadPlanOut(owner: *PreparedSurfaceOwner) FfiPreparedSurfaceUploadPlan {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .uploads = uploadOpSpanOut(owner.uploads),
        .pixel_blob = byteSpanOut(owner.pixel_blob),
    };
}

fn prepareDrawPlanOut(owner: *PreparedSurfaceOwner) FfiPreparedSurfaceDrawPlan {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .clear_draws = colorDrawSpanOut(owner.clear_draws),
        .background_draws = colorDrawSpanOut(owner.background_draws),
        .sprite_batches = spriteBatchSpanOut(owner.sprite_batches),
        .sprite_instances = spriteInstanceSpanOut(owner.sprite_instances),
        .decoration_draws = decorationDrawSpanOut(owner.decoration_draws),
        .cursor_draws = colorDrawSpanOut(owner.cursor_draws),
    };
}

fn prepareDiagnosticsOut(owner: *PreparedSurfaceOwner) FfiPreparedSurfaceDiagnostics {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .missing_glyphs = owner.missing_glyphs,
        .resolve_metrics = owner.resolve_metrics,
    };
}

fn executionInputIn(value: FfiSurfaceExecutionInput) SurfaceText.SurfaceExecutionInput {
    return .{
        .surface = .{
            .texture_id = value.surface.texture_id,
            .width = value.surface.width,
            .height = value.surface.height,
            .epoch = value.surface.epoch,
        },
        .uploads_committed = value.uploads_committed,
        .render_us = value.render_us,
        .content_valid = value.content_valid != 0,
    };
}

fn prepareRequestIn(value: FfiPrepareRequest) SurfaceText.PrepareInput {
    return .{
        .config = undefined,
        .request = .{
            .token = .{
                .snapshot_seq = value.snapshot_seq,
                .dirty_epoch = value.dirty_epoch,
                .geometry_epoch = value.geometry_epoch,
                .damage_base_seq = value.damage_base_seq,
                .damage_kind = @enumFromInt(value.damage_kind),
            },
            .known_target_epoch = value.known_target_epoch,
            .allow_retained_reuse = true,
            .priority = .opportunistic,
        },
        .query = undefined,
        .state = undefined,
        .target_valid = value.target_valid != 0,
    };
}

fn preparedFrameIn(value: FfiPreparedFrame) Render.FramePipeline.PreparedFrame {
    return .{
        .token = .{
            .snapshot_seq = value.snapshot_seq,
            .dirty_epoch = value.dirty_epoch,
            .geometry_epoch = value.geometry_epoch,
            .damage_base_seq = value.damage_base_seq,
            .damage_kind = @enumFromInt(value.damage_kind),
        },
        .required_base_seq = value.required_base_seq,
        .required_target_epoch = value.required_target_epoch,
    };
}

fn atlasPageForPrepared(slot: u32, atlas_page_slots: u32) u16 {
    if (atlas_page_slots == 0) return 0;
    return @intCast(slot / atlas_page_slots);
}

fn preparedSurfaceOwnerCreate(session_owner: *SurfaceTextOwner, value: Render.PreparedSurface) !*PreparedSurfaceOwner {
    var owner = try std.heap.c_allocator.create(PreparedSurfaceOwner);
    errdefer std.heap.c_allocator.destroy(owner);
    owner.* = .{
        .session_owner = session_owner,
        .prepared = value,
        .snapshot_seq = value.request.token.snapshot_seq,
        .dirty_epoch = value.request.token.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .required_base_seq = value.pipelineFrame().required_base_seq,
        .required_surface_epoch = value.required_surface_epoch,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .grid = .{ .cols = value.grid.cols, .rows = value.grid.rows },
        .prepare_metrics = .{
            .sync_us = value.prepare_metrics.sync_us,
            .copy_us = value.prepare_metrics.copy_us,
            .render_us = value.prepare_metrics.surface_us,
            .glyphs = 0,
            .fills = 0,
            .clear_fills = 0,
            .background_fills = 0,
            .decoration_fills = 0,
            .cursor_fills = 0,
            .uploads = 0,
            .face_checks = 0,
            .face_cache_hits = 0,
            .shape_requests = 0,
            .shape_cache_hits = 0,
            .fallback_hits = 0,
            .fallback_misses = 0,
            .missing_glyphs = 0,
        },
        .damage_kind = @intFromEnum(value.damageKind()),
        .full_redraw = boolByte(value.text_frame.scene.scene.full_redraw),
        .scroll_up_px = value.text_frame.scene.scene.scroll_up_px,
        .missing_glyphs = value.text_frame.scene.scene.missing.len,
        .resolve_metrics = .{
            .sync_us = 0,
            .copy_us = 0,
            .render_us = 0,
            .glyphs = 0,
            .fills = 0,
            .clear_fills = 0,
            .background_fills = 0,
            .decoration_fills = 0,
            .cursor_fills = 0,
            .uploads = 0,
            .face_checks = value.resolve.counters.face_checks,
            .face_cache_hits = value.resolve.counters.face_cache_hits,
            .shape_requests = value.resolve.counters.shape_requests,
            .shape_cache_hits = value.resolve.counters.shape_cache_hits,
            .fallback_hits = value.resolve.counters.fallback_hits,
            .fallback_misses = value.resolve.counters.fallback_misses,
            .missing_glyphs = value.resolve.counters.missing_glyphs,
        },
    };
    errdefer owner.destroy();

    owner.clear_draws = try std.heap.c_allocator.dupe(FfiColorDraw, session_owner.clear_draws.items);
    owner.background_draws = try std.heap.c_allocator.dupe(FfiColorDraw, session_owner.background_draws.items);
    owner.decoration_draws = try std.heap.c_allocator.dupe(FfiDecorationDraw, session_owner.decoration_draws.items);
    owner.cursor_draws = try std.heap.c_allocator.dupe(FfiColorDraw, session_owner.cursor_draws.items);

    owner.surface_damage_rects = try std.heap.c_allocator.alloc(FfiRect, value.surface_damage_rects.len);
    for (value.surface_damage_rects, 0..) |rect, idx| {
        owner.surface_damage_rects[idx] = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    }
    owner.buffer_damage_rects = try std.heap.c_allocator.alloc(FfiRect, value.buffer_damage_rects.len);
    for (value.buffer_damage_rects, 0..) |rect, idx| {
        owner.buffer_damage_rects[idx] = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    }

    owner.uploads = try std.heap.c_allocator.alloc(FfiUploadOp, session_owner.raster_uploads.items.len);
    var blob_len: usize = 0;
    for (session_owner.raster_uploads.items) |upload| blob_len += upload.pixels_len;
    owner.pixel_blob = try std.heap.c_allocator.alloc(u8, blob_len);
    var blob_offset: usize = 0;
    for (session_owner.raster_uploads.items, 0..) |upload, idx| {
        const pixels = if (upload.pixels_len == 0 or upload.pixels_ptr == null) &.{} else upload.pixels_ptr[0..upload.pixels_len];
        if (pixels.len > 0) std.mem.copyForwards(u8, owner.pixel_blob[blob_offset .. blob_offset + pixels.len], pixels);
        owner.uploads[idx] = .{
            .sprite_key = upload.key,
            .slot = upload.slot,
            .atlas_page = atlasPageForPrepared(upload.slot, value.atlas_page_slots),
            .pixel_format = if (upload.color_mode == 0) 0 else 1,
            .color_mode = upload.color_mode,
            .width_px = upload.width_px,
            .height_px = upload.height_px,
            .stride = if (upload.color_mode == 0) upload.width_px else @intCast(@as(u32, upload.width_px) * 4),
            .blob_offset = blob_offset,
            .blob_len = pixels.len,
            .visual_bounds = upload.visual_bounds,
        };
        blob_offset += pixels.len;
    }

    owner.sprite_instances = try std.heap.c_allocator.alloc(FfiSpriteInstance, session_owner.sprite_draws.items.len);
    for (session_owner.sprite_draws.items, 0..) |draw, idx| {
        const upload = findUploadOp(owner.uploads, draw.key, draw.slot);
        const src_width_px = if (upload) |op| op.visual_bounds.width_px else draw.width_px;
        const src_height_px = if (upload) |op| op.visual_bounds.height_px else draw.height_px;
        owner.sprite_instances[idx] = .{
            .slot = draw.slot,
            .sprite_key = draw.key,
            .dst_x_px = draw.x_px,
            .dst_y_px = draw.y_px,
            .dst_width_px = draw.width_px,
            .dst_height_px = draw.height_px,
            .src_x_px = if (upload) |op| op.visual_bounds.x_px else 0,
            .src_y_px = if (upload) |op| op.visual_bounds.y_px else 0,
            .src_width_px = src_width_px,
            .src_height_px = src_height_px,
            .color = draw.color,
        };
    }
    owner.sprite_batches = try std.heap.c_allocator.alloc(FfiSpriteBatch, value.sprite_batches.len);
    for (value.sprite_batches, 0..) |batch, idx| {
        owner.sprite_batches[idx] = .{
            .atlas_page = batch.atlas_page,
            .pass_kind = @intFromEnum(batch.pass_kind),
            .first_instance = batch.first_instance,
            .instance_count = batch.instance_count,
        };
    }
    return owner;
}

fn findSceneSpriteSlot(scene: Render.TextScene, key: Render.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn surfaceFeedbackOut(value: Render.SurfaceFeedback) FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = surfaceOut(value.surface),
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

fn underlineStyleIn(value: u8) Render.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn surfaceTextOwnerFromHandle(handle: SurfaceTextHandle) ?*SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

fn preparedSurfaceOwnerFromHandle(handle: PreparedSurfaceHandle) ?*PreparedSurfaceOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn deriveGridSize(grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiGridSize {
    return gridOut(Render.deriveGridSize(pixelIn(grid_px), cellIn(cell_px)));
}

pub fn deriveFrameGridSize(render_px: FfiPixelSize, grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiFrameGridResult {
    const grid = Render.deriveGridForFrame(pixelIn(render_px), pixelIn(grid_px), cellIn(cell_px)) catch |err| {
        return .{
            .status = switch (err) {
                error.InvalidSurfaceSize => -1,
                error.InvalidGridSize => -2,
            },
            .grid = .{ .cols = 0, .rows = 0 },
        };
    };
    return .{ .status = 0, .grid = gridOut(grid) };
}

pub fn surfaceTextDeriveFrameLayout(handle: SurfaceTextHandle, render_px: FfiPixelSize, grid_px: FfiPixelSize) callconv(.c) FfiFrameLayoutResult {
    const owner = surfaceTextOwnerFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlRenderCallStatus.missing_handle), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = @intFromEnum(HowlRenderCallStatus.invalid_argument), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = gridOut(layout.grid) };
}

pub fn surfaceTextInit(config: FfiSurfaceTextConfig) callconv(.c) SurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    const owner = SurfaceTextOwner.create(.{
        .surface_px = pixelIn(config.surface_px),
        .font_size_px = @max(config.font_size_px, 1),
    }) orelse return null;
    return @ptrCast(owner);
}

pub fn surfaceTextDeinit(handle: SurfaceTextHandle) callconv(.c) void {
    const owner = surfaceTextOwnerFromHandle(handle) orelse return;
    owner.destroy();
}

pub fn surfaceTextSetFontSizePx(handle: SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = surfaceTextOwnerFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    owner.config.font_size_px = @max(font_size_px, 1);
    owner.invalidateTextState();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSetFontPath(handle: SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = surfaceTextOwnerFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    if (owner.font_path) |path| {
        std.heap.c_allocator.free(path);
        owner.font_path = null;
    }
    if (len == 0 or ptr == null) {
        owner.config.font_path = null;
        owner.invalidateTextState();
        return @intFromEnum(HowlRenderCallStatus.ok);
    }
    const owned = std.heap.c_allocator.dupeZ(u8, ptr.?[0..len]) catch return @intFromEnum(HowlRenderCallStatus.failed);
    owner.font_path = owned;
    owner.config.font_path = owned;
    owner.invalidateTextState();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSetFallbackFontPaths(handle: SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = surfaceTextOwnerFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    for (owner.fallback_font_paths.items) |path| std.heap.c_allocator.free(path);
    owner.fallback_font_paths.clearRetainingCapacity();
    if (count == 0) {
        owner.session.text_state.fallback_font_paths_len = 0;
        for (0..text_support.max_fallback_fonts) |i| owner.session.text_state.fallback_font_paths[i] = null;
        owner.invalidateTextState();
        return @intFromEnum(HowlRenderCallStatus.ok);
    }
    const raw_paths = ptrs orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const raw = raw_paths[i] orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
        const owned = std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch return @intFromEnum(HowlRenderCallStatus.failed);
        owner.fallback_font_paths.append(std.heap.c_allocator, owned) catch return @intFromEnum(HowlRenderCallStatus.failed);
    }
    const n: u8 = @intCast(@min(owner.fallback_font_paths.items.len, text_support.max_fallback_fonts));
    owner.session.text_state.fallback_font_paths_len = n;
    for (0..n) |slot| owner.session.text_state.fallback_font_paths[slot] = owner.fallback_font_paths.items[slot];
    for (@as(usize, n)..text_support.max_fallback_fonts) |slot| owner.session.text_state.fallback_font_paths[slot] = null;
    owner.invalidateTextState();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextPrepareHandle(surface_text_handle: SurfaceTextHandle, surface_source_in: ?*const FfiSurfaceSource, prepare_request: FfiPrepareRequest, query: FfiSurfaceQuery, prepared_handle_out: ?*PreparedSurfaceHandle) callconv(.c) HowlRenderPrepareStatus {
    const owner = surfaceTextOwnerFromHandle(surface_text_handle) orelse return .failed;
    const surface_source_value = surface_source_in orelse return .failed;
    var prepare = prepareRequestIn(prepare_request);
    prepare.config = owner.config;
    prepare.query = surfaceQueryIn(query);
    var surface_source = surfaceSourceIn(std.heap.c_allocator, surface_source_value.*) catch return .failed;
    defer surface_source.deinit();
    prepare.state = surface_source.frame;
    const prepared = owner.session.prepareSurface(std.heap.c_allocator, prepare) catch return .failed;
    preparePreparedViews(owner, prepared) catch {
        var failed_prepared = prepared;
        failed_prepared.deinit();
        return .failed;
    };
    if (prepared_handle_out) |out| {
        const prepared_owner = preparedSurfaceOwnerCreate(owner, prepared) catch return .failed;
        out.* = @ptrCast(prepared_owner);
    }
    return .ready;
}

pub fn preparedSurfaceRelease(prepared_surface_handle: PreparedSurfaceHandle) callconv(.c) void {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn preparedSurfaceDescribe(prepared_surface_handle: PreparedSurfaceHandle, info_out: ?*FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepareInfoOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDamagePlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceDamagePlan) callconv(.c) c_int {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepareDamagePlanOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceUploadPlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceUploadPlan) callconv(.c) c_int {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepareUploadPlanOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDrawPlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceDrawPlan) callconv(.c) c_int {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepareDrawPlanOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDiagnostics(prepared_surface_handle: PreparedSurfaceHandle, diagnostics_out: ?*FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepareDiagnosticsOut(owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSubmit(surface_text_handle: SurfaceTextHandle, prepared_surface_handle: PreparedSurfaceHandle, prepared_frame_in: FfiPreparedFrame, execution_in: ?*const FfiSurfaceExecutionInput, feedback_out: ?*FfiSurfaceFeedback) callconv(.c) HowlRenderSubmitStatus {
    const owner = surfaceTextOwnerFromHandle(surface_text_handle) orelse return .failed;
    const prepared_owner = preparedSurfaceOwnerFromHandle(prepared_surface_handle) orelse return .failed;
    if (prepared_owner.session_owner != owner) return .failed;
    const execution = execution_in orelse return .failed;
    const prepared_frame = preparedFrameIn(prepared_frame_in);
    if (!samePreparedFrame(prepared_owner.prepared.pipelineFrame(), prepared_frame)) return .needs_prepare;
    const submitted = owner.session.submitSurface(&prepared_owner.prepared, executionInputIn(execution.*)) catch return .failed;
    if (feedback_out) |out| out.* = surfaceFeedbackOut(submitted);
    prepared_owner.destroy();
    return .rendered;
}

fn samePreparedFrame(a: Render.FramePipeline.PreparedFrame, b: Render.FramePipeline.PreparedFrame) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq and
        a.required_target_epoch == b.required_target_epoch;
}

test "ffi surface session rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), surfaceTextSetFontSizePx(null, 12));
}

test "ffi surface session initializes" {
    const handle = surfaceTextInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .font_size_px = 8,
    });
    defer surfaceTextDeinit(handle);
    try std.testing.expect(handle != null);
}
