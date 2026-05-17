
const std = @import("std");
const Render = @import("howl_render.zig");
const SurfaceText = Render.SurfaceText;
const surface = @import("frame/surface.zig");
const text_support = @import("text/font/ft_hb/support.zig");
const prepared_surface = @import("ffi_prepared_surface.zig");

pub const HowlRenderSurfaceText = opaque {};
pub const HowlRenderPreparedSurfaceObject = opaque {};

pub const SurfaceTextHandle = ?*HowlRenderSurfaceText;
pub const PreparedSurfaceHandle = ?*HowlRenderPreparedSurfaceObject;

const PreparedSurfaceOwner = prepared_surface.Owner(@This());

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

fn surfaceTextOwnerFromHandle(handle: SurfaceTextHandle) ?*surface.SurfaceTextOwner {
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
    const owner = surface.SurfaceTextOwner.create(.{
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
    if (prepared_handle_out) |out| {
        const prepared_owner = prepared_surface.create(@This(), owner, prepared) catch return .failed;
        out.* = @ptrCast(prepared_owner);
    }
    return .ready;
}

pub fn preparedSurfaceRelease(prepared_surface_handle: PreparedSurfaceHandle) callconv(.c) void {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return;
    owner.destroy();
}

pub fn preparedSurfaceDescribe(prepared_surface_handle: PreparedSurfaceHandle, info_out: ?*FfiPreparedSurfaceInfo) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = info_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.infoOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDamagePlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceDamagePlan) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.damagePlanOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceUploadPlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceUploadPlan) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.uploadPlanOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDrawPlan(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceDrawPlan) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.drawPlanOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDiagnostics(prepared_surface_handle: PreparedSurfaceHandle, diagnostics_out: ?*FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.diagnosticsOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSubmit(surface_text_handle: SurfaceTextHandle, prepared_surface_handle: PreparedSurfaceHandle, prepared_frame_in: FfiPreparedFrame, execution_in: ?*const FfiSurfaceExecutionInput, feedback_out: ?*FfiSurfaceFeedback) callconv(.c) HowlRenderSubmitStatus {
    const owner = surfaceTextOwnerFromHandle(surface_text_handle) orelse return .failed;
    const prepared_owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return .failed;
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
