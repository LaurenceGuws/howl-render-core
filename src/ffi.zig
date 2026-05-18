
const std = @import("std");
const Render = @import("howl_render.zig");
const SurfaceText = Render.SurfaceText;
const surface = @import("frame/surface.zig");
const prepared_surface = @import("frame/prepared_surface_ffi.zig");
const surface_text_ffi = @import("frame/surface_text_ffi.zig");

pub const HowlRenderSurfaceText = opaque {};
pub const HowlRenderPreparedSurfaceObject = opaque {};

pub const SurfaceTextHandle = ?*HowlRenderSurfaceText;
pub const PreparedSurfaceHandle = ?*HowlRenderPreparedSurfaceObject;

const PreparedSurfaceOwner = prepared_surface.Owner(@This());

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
    reserved1: u16 = 0,
    surface_damage_rects: FfiRectSpan,
    buffer_damage_rects: FfiRectSpan,
};

pub const FfiPreparedSurfaceBuffer = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    rgba_pixels: FfiByteSpan,
    uploads_committed: u64,
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
    content_valid: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const FfiSurfaceSource = extern struct {
    cells: FfiCellSpan,
    cols: u16,
    rows: u16,
    scroll_row: u64,
    is_alternate_screen: u8,
    full_damage: u8,
    reserved1: u16 = 0,
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

fn underlineStyleIn(value: u8) Render.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
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
    return surface_text_ffi.deriveFrameLayout(@This(), handle, render_px, grid_px);
}

pub fn surfaceTextInit(config: FfiSurfaceTextConfig) callconv(.c) SurfaceTextHandle {
    return surface_text_ffi.init(@This(), config);
}

pub fn surfaceTextDeinit(handle: SurfaceTextHandle) callconv(.c) void {
    surface_text_ffi.deinit(@This(), handle);
}

pub fn surfaceTextSetFontSizePx(handle: SurfaceTextHandle, font_size_px: u16) callconv(.c) c_int {
    return surface_text_ffi.setFontSize(@This(), handle, font_size_px);
}

pub fn surfaceTextSetFontPath(handle: SurfaceTextHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    return surface_text_ffi.setFontPath(@This(), handle, ptr, len);
}

pub fn surfaceTextSetFallbackFontPaths(handle: SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    return surface_text_ffi.setFallbackFontPaths(@This(), handle, ptrs, count);
}

pub fn surfaceTextPrepareHandle(surface_text_handle: SurfaceTextHandle, surface_source_in: ?*const FfiSurfaceSource, prepare_request: FfiPrepareRequest, query: FfiSurfaceQuery, prepared_handle_out: ?*PreparedSurfaceHandle) callconv(.c) HowlRenderPrepareStatus {
    return surface_text_ffi.prepareHandle(@This(), surface_text_handle, surface_source_in, prepare_request, query, prepared_handle_out);
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

pub fn preparedSurfaceBuffer(prepared_surface_handle: PreparedSurfaceHandle, plan_out: ?*FfiPreparedSurfaceBuffer) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = plan_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.bufferOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn preparedSurfaceDiagnostics(prepared_surface_handle: PreparedSurfaceHandle, diagnostics_out: ?*FfiPreparedSurfaceDiagnostics) callconv(.c) c_int {
    const owner = prepared_surface.fromHandle(@This(), prepared_surface_handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    const out = diagnostics_out orelse return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    out.* = prepared_surface.diagnosticsOut(@This(), owner);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn surfaceTextSubmit(surface_text_handle: SurfaceTextHandle, prepared_surface_handle: PreparedSurfaceHandle, prepared_frame_in: FfiPreparedFrame, execution_in: ?*const FfiSurfaceExecutionInput, feedback_out: ?*FfiSurfaceFeedback) callconv(.c) HowlRenderSubmitStatus {
    return surface_text_ffi.submit(@This(), surface_text_handle, prepared_surface_handle, prepared_frame_in, execution_in, feedback_out);
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
