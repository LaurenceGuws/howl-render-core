//! Responsibility: implement the howl-render-core native ABI surface.
//! Ownership: render-core geometry, snapshot storage, runtime scheduling, and renderer owner handles.
//! Reason: keep C consumers on the same owner-true render contract as Zig consumers.

const std = @import("std");
const Core = @import("render_core.zig").RenderCore;
const renderer_mod = @import("renderer.zig").Renderer;

pub const SnapshotHandle = usize;
pub const RuntimeHandle = usize;
pub const RendererHandle = usize;

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

pub const FfiGridSize = extern struct {
    cols: u16,
    rows: u16,
};

pub const FfiFrameGridResult = extern struct {
    status: c_int,
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

pub const FfiGeometryReceipt = extern struct {
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

pub const FfiSourceView = extern struct {
    snapshot_handle: SnapshotHandle,
    cols: u16,
    rows: u16,
    scrollback_count: u64,
    scrollback_offset: u64,
    selection_anchor_valid: u8,
    selection_current_valid: u8,
    focused: u8,
    hover_underline_style: u8,
    selection_anchor_depth: u64,
    selection_anchor_col: u16,
    reserved0: u16 = 0,
    selection_current_depth: u64,
    selection_current_col: u16,
    reserved1: u16 = 0,
    hover_link_id: u32,
    snapshot_seq: u64,
    vt_epoch: u64,
    last_alt_screen: u8,
    reserved2: u8 = 0,
    reserved3: u8 = 0,
    reserved4: u8 = 0,
};

pub const FfiSourceReceipt = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    published: u8,
    queued: u8,
    damage_kind: u8,
    reserved0: u8 = 0,
    source_seq: u64,
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

pub const FfiRuntimeMetrics = extern struct {
    status: i32 = @intFromEnum(HowlRenderCallStatus.failed),
    snapshot_publishes: u64,
    snapshot_hidden_drops: u64,
    snapshot_clean_drops: u64,
    prepare_requests: u64,
    prepare_coalesces: u64,
    prepare_forced_full: u64,
    prepare_takes: u64,
    prepared_publishes: u64,
    prepared_coalesces: u64,
    submit_takes: u64,
    submit_valid: u64,
    submit_rejected: u64,
    full_prepare_requests: u64,
    submitted_accepts: u64,
    presents: u64,
    target_invalidations: u64,
};

pub const FfiBackendMetrics = extern struct {
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

pub const FfiBackendConfig = extern struct {
    surface_px: FfiPixelSize,
    cell_px: FfiCellSize,
    font_size_px: u16,
    reserved0: u16 = 0,
    target_texture: u32,
};

const RendererOwner = struct {
    renderer: renderer_mod,
    prepared: ?renderer_mod.FrameRecord = null,
    font_path: ?[:0]u8 = null,

    fn deinit(self: *RendererOwner) void {
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
        if (self.font_path) |path| std.heap.c_allocator.free(path);
        self.font_path = null;
        self.renderer.deinit();
    }
};

comptime {
    std.debug.assert(@sizeOf(FfiPixelSize) == 4);
    std.debug.assert(@sizeOf(FfiCellSize) == 4);
    std.debug.assert(@sizeOf(FfiGridSize) == 4);
    std.debug.assert(@sizeOf(FfiColor) == 8);
    std.debug.assert(@sizeOf(FfiCursor) == 6);
}

fn pixelIn(value: FfiPixelSize) Core.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn cellIn(value: FfiCellSize) Core.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn gridOut(value: Core.GridSize) FfiGridSize {
    return .{ .cols = value.cols, .rows = value.rows };
}

fn boolByte(value: bool) u8 {
    return if (value) 1 else 0;
}

fn colorIn(value: FfiColor) Core.SurfaceColor {
    return .{
        .kind = switch (value.kind) {
            0 => .default,
            1 => .indexed,
            else => .rgb,
        },
        .value = @truncate(value.value),
    };
}

fn cellValueIn(value: FfiCell) Core.SurfaceCell {
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

fn cursorIn(value: FfiCursor) Core.SurfaceCursorInfo {
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

fn geometryIn(value: FfiGeometry) Core.Geometry {
    return .{
        .render_px = pixelIn(value.render_px),
        .grid_px = pixelIn(value.grid_px),
        .cell_px = cellInSize(value.cell_px),
    };
}

fn cellInSize(value: FfiCellSize) Core.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn geometryOut(value: Core.GeometryReceipt) FfiGeometryReceipt {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .changed = boolByte(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}

fn sourceViewIn(value: FfiSourceView) ?Core.SourceView {
    const snapshot = snapshotFromHandle(value.snapshot_handle) orelse return null;
    return .{
        .snapshot = snapshot,
        .cols = value.cols,
        .rows = value.rows,
        .scrollback_count = value.scrollback_count,
        .scrollback_offset = value.scrollback_offset,
        .selection_anchor_depth = if (value.selection_anchor_valid != 0) value.selection_anchor_depth else null,
        .selection_anchor_col = if (value.selection_anchor_valid != 0) value.selection_anchor_col else null,
        .selection_current_depth = if (value.selection_current_valid != 0) value.selection_current_depth else null,
        .selection_current_col = if (value.selection_current_valid != 0) value.selection_current_col else null,
        .focused = value.focused != 0,
        .hover_link_id = value.hover_link_id,
        .hover_underline_style = underlineStyleIn(value.hover_underline_style),
        .snapshot_seq = value.snapshot_seq,
        .vt_epoch = value.vt_epoch,
        .last_alt_screen = value.last_alt_screen != 0,
    };
}

fn sourceReceiptOut(value: Core.SourceReceipt) FfiSourceReceipt {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .published = boolByte(value.published),
        .queued = boolByte(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .source_seq = value.source_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

fn surfaceQueryOut(value: Core.SurfaceQuery) FfiSurfaceQuery {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn metricsOut(value: Core.Metrics) FfiRuntimeMetrics {
    return .{
        .status = @intFromEnum(HowlRenderCallStatus.ok),
        .snapshot_publishes = value.snapshot_publishes,
        .snapshot_hidden_drops = value.snapshot_hidden_drops,
        .snapshot_clean_drops = value.snapshot_clean_drops,
        .prepare_requests = value.prepare_requests,
        .prepare_coalesces = value.prepare_coalesces,
        .prepare_forced_full = value.prepare_forced_full,
        .prepare_takes = value.prepare_takes,
        .prepared_publishes = value.prepared_publishes,
        .prepared_coalesces = value.prepared_coalesces,
        .submit_takes = value.submit_takes,
        .submit_valid = value.submit_valid,
        .submit_rejected = value.submit_rejected,
        .full_prepare_requests = value.full_prepare_requests,
        .submitted_accepts = value.submitted_accepts,
        .presents = value.presents,
        .target_invalidations = value.target_invalidations,
    };
}

fn backendMetricsOut(value: Core.RenderMetrics) FfiBackendMetrics {
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

fn surfaceOut(value: Core.SurfaceHandle) FfiSurfaceHandle {
    return .{ .texture_id = value.texture_id, .width = value.width, .height = value.height, .epoch = value.epoch };
}

fn underlineStyleIn(value: u8) Core.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn snapshotFromHandle(handle: SnapshotHandle) ?*Core.FrameSnapshot {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

fn runtimeFromHandle(handle: RuntimeHandle) ?*Core.RenderRuntime {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

fn rendererFromHandle(handle: RendererHandle) ?*RendererOwner {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

pub fn deriveGridSize(grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiGridSize {
    return gridOut(Core.deriveGridSize(pixelIn(grid_px), cellIn(cell_px)));
}

pub fn deriveFrameGridSize(render_px: FfiPixelSize, grid_px: FfiPixelSize, cell_px: FfiCellSize) callconv(.c) FfiFrameGridResult {
    const grid = Core.deriveGridForFrame(pixelIn(render_px), pixelIn(grid_px), cellIn(cell_px)) catch |err| {
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

pub fn snapshotInit(rows: u16, cols: u16) callconv(.c) SnapshotHandle {
    if (rows == 0 or cols == 0) return 0;
    const snapshot = std.heap.c_allocator.create(Core.FrameSnapshot) catch return 0;
    snapshot.* = Core.FrameSnapshot.init(std.heap.c_allocator, rows, cols) catch {
        std.heap.c_allocator.destroy(snapshot);
        return 0;
    };
    return @intFromPtr(snapshot);
}

pub fn snapshotDeinit(handle: SnapshotHandle) callconv(.c) void {
    const snapshot = snapshotFromHandle(handle) orelse return;
    snapshot.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(snapshot);
}

pub fn snapshotResize(handle: SnapshotHandle, rows: u16, cols: u16) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (rows == 0 or cols == 0) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    snapshot.resize(std.heap.c_allocator, rows, cols) catch return @intFromEnum(HowlRenderCallStatus.failed);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn snapshotMarkFullDirty(handle: SnapshotHandle) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    snapshot.markFullDirty();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn snapshotClearDirty(handle: SnapshotHandle) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    snapshot.clearDirty();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn snapshotSetViewport(handle: SnapshotHandle, scroll_row: u64, is_alternate_screen: c_int) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    snapshot.scroll_row = @intCast(scroll_row);
    snapshot.is_alternate_screen = is_alternate_screen != 0;
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn snapshotSetCursor(handle: SnapshotHandle, cursor: FfiCursor) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    snapshot.cursor = cursorIn(cursor);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn snapshotWriteCell(handle: SnapshotHandle, row: u16, col: u16, cell: FfiCell) callconv(.c) c_int {
    const snapshot = snapshotFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (row >= snapshot.rows or col >= snapshot.cols) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    const idx = @as(usize, row) * @as(usize, snapshot.cols) + @as(usize, col);
    snapshot.cells.items[idx] = cellValueIn(cell);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn runtimeInit() callconv(.c) RuntimeHandle {
    const runtime = std.heap.c_allocator.create(Core.RenderRuntime) catch return 0;
    runtime.* = Core.RenderRuntime.init(std.heap.c_allocator);
    return @intFromPtr(runtime);
}

pub fn runtimeDeinit(handle: RuntimeHandle) callconv(.c) void {
    const runtime = runtimeFromHandle(handle) orelse return;
    runtime.deinit();
    std.heap.c_allocator.destroy(runtime);
}

pub fn runtimeSetFontSizePx(handle: RuntimeHandle, font_size_px: u16) callconv(.c) c_int {
    const runtime = runtimeFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    runtime.setFontSizePx(font_size_px);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn runtimeSyncGeometry(handle: RuntimeHandle, geometry: FfiGeometry) callconv(.c) FfiGeometryReceipt {
    const runtime = runtimeFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlRenderCallStatus.missing_handle), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    if (geometry.render_px.width == 0 or geometry.render_px.height == 0) return .{ .status = @intFromEnum(HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    if (geometry.grid_px.width == 0 or geometry.grid_px.height == 0) return .{ .status = @intFromEnum(HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    if (geometry.cell_px.width == 0 or geometry.cell_px.height == 0) return .{ .status = @intFromEnum(HowlRenderCallStatus.invalid_argument), .changed = 0, .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .geometry_epoch = 0 };
    return geometryOut(runtime.syncGeometry(geometryIn(geometry)));
}

pub fn runtimePublishSnapshot(handle: RuntimeHandle, source: FfiSourceView) callconv(.c) FfiSourceReceipt {
    const runtime = runtimeFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlRenderCallStatus.missing_handle), .published = 0, .queued = 0, .damage_kind = 0, .source_seq = 0, .geometry_epoch = 0 };
    const typed = sourceViewIn(source) orelse return .{ .status = @intFromEnum(HowlRenderCallStatus.invalid_argument), .published = 0, .queued = 0, .damage_kind = 0, .source_seq = 0, .geometry_epoch = 0 };
    return sourceReceiptOut(runtime.acceptSource(typed));
}

pub fn runtimeAction(handle: RuntimeHandle) callconv(.c) u8 {
    const runtime = runtimeFromHandle(handle) orelse return @intFromEnum(Core.FrameQueue.TerminalSurface.Action.idle);
    return @intFromEnum(runtime.surface_owner.nextAction());
}

pub fn runtimeMarkPresented(handle: RuntimeHandle) callconv(.c) void {
    const runtime = runtimeFromHandle(handle) orelse return;
    runtime.markPresented();
}

pub fn runtimeSurfaceQuery(handle: RuntimeHandle) callconv(.c) FfiSurfaceQuery {
    const runtime = runtimeFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlRenderCallStatus.missing_handle), .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cell_px = .{ .width = 0, .height = 0 }, .font_size_px = 0, .epoch = 0 };
    return surfaceQueryOut(runtime.surfaceQuery());
}

pub fn runtimeTakeMetrics(handle: RuntimeHandle) callconv(.c) FfiRuntimeMetrics {
    const runtime = runtimeFromHandle(handle) orelse return .{
        .status = @intFromEnum(HowlRenderCallStatus.missing_handle),
        .snapshot_publishes = 0,
        .snapshot_hidden_drops = 0,
        .snapshot_clean_drops = 0,
        .prepare_requests = 0,
        .prepare_coalesces = 0,
        .prepare_forced_full = 0,
        .prepare_takes = 0,
        .prepared_publishes = 0,
        .prepared_coalesces = 0,
        .submit_takes = 0,
        .submit_valid = 0,
        .submit_rejected = 0,
        .full_prepare_requests = 0,
        .submitted_accepts = 0,
        .presents = 0,
        .target_invalidations = 0,
    };
    return metricsOut(runtime.takeMetrics());
}

pub fn runtimeResetMetrics(handle: RuntimeHandle) callconv(.c) c_int {
    const runtime = runtimeFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    runtime.resetMetrics();
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn rendererInit(config: FfiBackendConfig) callconv(.c) RendererHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return 0;
    if (config.cell_px.width == 0 or config.cell_px.height == 0) return 0;
    const owner = std.heap.c_allocator.create(RendererOwner) catch return 0;
    owner.* = .{
        .renderer = renderer_mod.init(.{
            .surface_px = pixelIn(config.surface_px),
            .cell_px = cellInSize(config.cell_px),
            .font_size_px = if (config.font_size_px == 0) config.cell_px.height else config.font_size_px,
            .target_texture = config.target_texture,
        }),
    };
    return @intFromPtr(owner);
}

pub fn rendererDeinit(handle: RendererHandle) callconv(.c) void {
    const owner = rendererFromHandle(handle) orelse return;
    owner.deinit();
    std.heap.c_allocator.destroy(owner);
}

pub fn rendererSetFontSizePx(handle: RendererHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = rendererFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    owner.renderer.setFontSizePx(font_size_px);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn rendererSetFontPath(handle: RendererHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = rendererFromHandle(handle) orelse return @intFromEnum(HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(HowlRenderCallStatus.invalid_argument);
    if (owner.font_path) |path| {
        std.heap.c_allocator.free(path);
        owner.font_path = null;
    }
    if (len == 0 or ptr == null) {
        owner.renderer.setFontPath(null);
        return @intFromEnum(HowlRenderCallStatus.ok);
    }
    const owned = std.heap.c_allocator.dupeZ(u8, ptr.?[0..len]) catch return @intFromEnum(HowlRenderCallStatus.failed);
    owner.font_path = owned;
    owner.renderer.setFontPath(owned);
    return @intFromEnum(HowlRenderCallStatus.ok);
}

pub fn rendererPrepare(renderer_handle: RendererHandle, runtime_handle: RuntimeHandle, snapshot_handle: SnapshotHandle) callconv(.c) c_int {
    const owner = rendererFromHandle(renderer_handle) orelse return @intFromEnum(HowlRenderPrepareStatus.failed);
    const runtime = runtimeFromHandle(runtime_handle) orelse return @intFromEnum(HowlRenderPrepareStatus.failed);
    const snapshot = snapshotFromHandle(snapshot_handle) orelse return @intFromEnum(HowlRenderPrepareStatus.failed);
    const request = runtime.prepare() orelse return @intFromEnum(HowlRenderPrepareStatus.idle);
    if (owner.prepared) |*prepared| prepared.deinit();
    const query = runtime.surfaceQuery();
    const prepared = owner.renderer.prepareFrame(std.heap.c_allocator, snapshot.frameData(), query.render_px, query.cell_px) catch {
        owner.prepared = null;
        return @intFromEnum(HowlRenderPrepareStatus.failed);
    };
    owner.prepared = .{
        .render_seq = request.token.snapshot_seq,
        .render_dirty_epoch = request.token.dirty_epoch,
        .geometry_epoch = request.token.geometry_epoch,
        .sync_us = 0,
        .copy_us = 0,
        .prepare_metrics = .{},
        .resolve_before = prepared.resolve_before,
        .prepared = prepared.frame,
    };
    _ = runtime.publishPrepared(owner.prepared.?.pipelineFrame(request));
    return @intFromEnum(HowlRenderPrepareStatus.ready);
}

pub fn rendererSubmit(renderer_handle: RendererHandle, runtime_handle: RuntimeHandle, surface_out: ?*FfiSurfaceHandle, metrics_out: ?*FfiBackendMetrics) callconv(.c) HowlRenderSubmitStatus {
    const owner = rendererFromHandle(renderer_handle) orelse return .failed;
    const runtime = runtimeFromHandle(runtime_handle) orelse return .failed;
    switch (runtime.submit()) {
        .idle => return .idle,
        .stale => return .stale,
        .needs_full_prepare => return .needs_prepare,
        .submit => {
            const prepared = &(owner.prepared orelse return .failed);
            const submitted = owner.renderer.submitFrame(&prepared.prepared) catch return .failed;
            const metrics = prepared.renderMetrics(submitted, 0);
            runtime.acceptSubmitted(prepared.submittedFrame(submitted));
            if (surface_out) |out| out.* = surfaceOut(submitted.surface);
            if (metrics_out) |out| out.* = backendMetricsOut(metrics);
            prepared.deinit();
            owner.prepared = null;
            return .rendered;
        },
    }
}

test "ffi snapshot owner rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), snapshotResize(0, 2, 2));
}

test "ffi snapshot owner writes cells" {
    const handle = snapshotInit(2, 2);
    defer snapshotDeinit(handle);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.ok), snapshotWriteCell(handle, 1, 1, .{
        .codepoint = 'Z',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 2, .value = 0x010203 },
        .bg_color = .{ .kind = 2, .value = 0x040506 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 1, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0 },
        .link_id = 3,
    }));
    const snapshot = snapshotFromHandle(handle).?;
    const idx = @as(usize, 1) * 2 + 1;
    try std.testing.expectEqual(@as(u21, 'Z'), snapshot.cells.items[idx].codepoint);
}

test "ffi runtime owner handles geometry and publication" {
    const snapshot_handle = snapshotInit(2, 2);
    defer snapshotDeinit(snapshot_handle);
    const runtime_handle = runtimeInit();
    defer runtimeDeinit(runtime_handle);
    try std.testing.expect(runtime_handle != 0);
    _ = snapshotMarkFullDirty(snapshot_handle);
    const geometry = runtimeSyncGeometry(runtime_handle, .{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 8 },
    });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.ok), geometry.status);
    try std.testing.expectEqual(@as(u8, 1), geometry.changed);
    const receipt = runtimePublishSnapshot(runtime_handle, .{
        .snapshot_handle = snapshot_handle,
        .cols = 2,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .selection_anchor_valid = 0,
        .selection_current_valid = 0,
        .focused = 1,
        .hover_underline_style = 0,
        .selection_anchor_depth = 0,
        .selection_anchor_col = 0,
        .selection_current_depth = 0,
        .selection_current_col = 0,
        .hover_link_id = 0,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .last_alt_screen = 0,
    });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.ok), receipt.status);
    try std.testing.expectEqual(@as(u8, 1), receipt.published);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Core.FrameQueue.TerminalSurface.Action.prepare)), runtimeAction(runtime_handle));
}

test "ffi runtime owner reports missing handle and invalid geometry" {
    const missing_geometry = runtimeSyncGeometry(0, .{ .render_px = .{ .width = 1, .height = 1 }, .grid_px = .{ .width = 1, .height = 1 }, .cell_px = .{ .width = 1, .height = 1 } });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), missing_geometry.status);

    const runtime_handle = runtimeInit();
    defer runtimeDeinit(runtime_handle);
    const invalid_geometry = runtimeSyncGeometry(runtime_handle, .{ .render_px = .{ .width = 0, .height = 1 }, .grid_px = .{ .width = 1, .height = 1 }, .cell_px = .{ .width = 1, .height = 1 } });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.invalid_argument), invalid_geometry.status);

    const missing_source = runtimePublishSnapshot(runtime_handle, .{ .snapshot_handle = 0, .cols = 1, .rows = 1, .scrollback_count = 0, .scrollback_offset = 0, .selection_anchor_valid = 0, .selection_current_valid = 0, .focused = 1, .hover_underline_style = 0, .selection_anchor_depth = 0, .selection_anchor_col = 0, .selection_current_depth = 0, .selection_current_col = 0, .hover_link_id = 0, .snapshot_seq = 1, .vt_epoch = 1, .last_alt_screen = 0 });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.invalid_argument), missing_source.status);
}

test "ffi renderer owner rejects missing handle" {
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.missing_handle), rendererSetFontSizePx(0, 12));
}

test "ffi renderer owner initializes" {
    const handle = rendererInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 8 },
        .font_size_px = 8,
        .target_texture = 0,
    });
    defer rendererDeinit(handle);
    try std.testing.expect(handle != 0);
}

test "ffi renderer owner detects stale runtime submit transition" {
    const snapshot_handle = snapshotInit(2, 2);
    defer snapshotDeinit(snapshot_handle);
    const runtime_handle = runtimeInit();
    defer runtimeDeinit(runtime_handle);
    const renderer_handle = rendererInit(.{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 8 },
        .font_size_px = 8,
        .target_texture = 0,
    });
    defer rendererDeinit(renderer_handle);

    _ = snapshotMarkFullDirty(snapshot_handle);
    _ = runtimeSyncGeometry(runtime_handle, .{ .render_px = .{ .width = 16, .height = 16 }, .grid_px = .{ .width = 16, .height = 16 }, .cell_px = .{ .width = 8, .height = 8 } });
    const receipt = runtimePublishSnapshot(runtime_handle, .{ .snapshot_handle = snapshot_handle, .cols = 2, .rows = 2, .scrollback_count = 0, .scrollback_offset = 0, .selection_anchor_valid = 0, .selection_current_valid = 0, .focused = 1, .hover_underline_style = 0, .selection_anchor_depth = 0, .selection_anchor_col = 0, .selection_current_depth = 0, .selection_current_col = 0, .hover_link_id = 0, .snapshot_seq = 1, .vt_epoch = 1, .last_alt_screen = 0 });
    try std.testing.expectEqual(@intFromEnum(HowlRenderCallStatus.ok), receipt.status);
    try std.testing.expectEqual(@intFromEnum(HowlRenderPrepareStatus.ready), rendererPrepare(renderer_handle, runtime_handle, snapshot_handle));

    _ = runtimeSyncGeometry(runtime_handle, .{ .render_px = .{ .width = 24, .height = 16 }, .grid_px = .{ .width = 24, .height = 16 }, .cell_px = .{ .width = 8, .height = 8 } });
    try std.testing.expectEqual(HowlRenderSubmitStatus.needs_prepare, rendererSubmit(renderer_handle, runtime_handle, null, null));
}
