const std = @import("std");
const Render = @import("../howl_render.zig");
const prepared_surface = @import("prepared_surface_ffi.zig");
const surface = @import("surface.zig");
const surface_text = @import("surface_text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");

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

pub fn ownerFromHandle(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) ?*surface_text.SurfaceTextOwner {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn deriveFrameLayout(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, render_px: Ffi.FfiPixelSize, grid_px: Ffi.FfiPixelSize) Ffi.FfiFrameLayoutResult {
    const owner = ownerFromHandle(Ffi, handle) orelse return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    const layout = owner.session.deriveFrameLayout(owner.config, pixelIn(render_px), pixelIn(grid_px)) catch {
        return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument), .cell_px = .{ .width = 0, .height = 0 }, .grid = .{ .cols = 0, .rows = 0 } };
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn init(comptime Ffi: type, config: Ffi.FfiSurfaceTextConfig) Ffi.SurfaceTextHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    const owner = surface_text.SurfaceTextOwner.create(.{ .surface_px = pixelIn(config.surface_px), .font_size_px = @max(config.font_size_px, 1) }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(comptime Ffi: type, handle: Ffi.SurfaceTextHandle) void {
    const owner = ownerFromHandle(Ffi, handle) orelse return;
    owner.destroy();
}

pub fn setFontSize(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, font_size_px: u16) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    if (font_size_px == 0) return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    owner.config.font_size_px = @max(font_size_px, 1);
    owner.invalidateTextState();
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn setFontPath(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, ptr: ?[*]const u8, len: usize) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    if (len > 0 and ptr == null) return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    if (owner.font_path) |path| {
        std.heap.c_allocator.free(path);
        owner.font_path = null;
    }
    if (len == 0 or ptr == null) {
        owner.config.font_path = null;
        owner.invalidateTextState();
        return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
    }
    const owned = std.heap.c_allocator.dupeZ(u8, ptr.?[0..len]) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
    owner.font_path = owned;
    owner.config.font_path = owned;
    owner.invalidateTextState();
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn setFallbackFontPaths(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, ptrs: ?[*]const ?[*]const u8, count: usize) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    for (owner.fallback_font_paths.items) |path| std.heap.c_allocator.free(path);
    owner.fallback_font_paths.clearRetainingCapacity();
    if (count == 0) {
        owner.session.text_state.fallback_font_paths_len = 0;
        for (0..text_support.max_fallback_fonts) |i| owner.session.text_state.fallback_font_paths[i] = null;
        owner.invalidateTextState();
        return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
    }
    const raw_paths = ptrs orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const raw = raw_paths[i] orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
        const owned = std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
        owner.fallback_font_paths.append(std.heap.c_allocator, owned) catch return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
    }
    const n: u8 = @intCast(@min(owner.fallback_font_paths.items.len, text_support.max_fallback_fonts));
    owner.session.text_state.fallback_font_paths_len = n;
    for (0..n) |slot| owner.session.text_state.fallback_font_paths[slot] = owner.fallback_font_paths.items[slot];
    for (@as(usize, n)..text_support.max_fallback_fonts) |slot| owner.session.text_state.fallback_font_paths[slot] = null;
    owner.invalidateTextState();
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

pub fn prepareHandle(comptime Ffi: type, surface_text_handle: Ffi.SurfaceTextHandle, surface_source_in: ?*const Ffi.FfiSurfaceSource, prepare_request: Ffi.FfiPrepareRequest, query: Ffi.FfiSurfaceQuery, prepared_handle_out: ?*Ffi.PreparedSurfaceHandle) Ffi.HowlRenderPrepareStatus {
    const owner = ownerFromHandle(Ffi, surface_text_handle) orelse return .failed;
    const surface_source_value = surface_source_in orelse return .failed;
    var prepare = prepareRequestIn(Ffi, prepare_request);
    prepare.config = owner.config;
    prepare.query = surfaceQueryIn(query);
    var surface_source = surfaceSourceIn(Ffi, std.heap.c_allocator, surface_source_value.*) catch return .failed;
    defer surface_source.deinit();
    prepare.state = surface_source.frame;
    const prepared = owner.session.prepareSurface(std.heap.c_allocator, prepare) catch return .failed;
    if (prepared_handle_out) |out| {
        const prepared_owner = prepared_surface.create(Ffi, owner, prepared) catch return .failed;
        out.* = @ptrCast(prepared_owner);
    }
    return .ready;
}

pub fn submit(comptime Ffi: type, surface_text_handle: Ffi.SurfaceTextHandle, prepared_surface_handle: Ffi.PreparedSurfaceHandle, prepared_frame_in: Ffi.FfiPreparedFrame, execution_in: ?*const Ffi.FfiSurfaceExecutionInput, feedback_out: ?*Ffi.FfiSurfaceFeedback) Ffi.HowlRenderSubmitStatus {
    const owner = ownerFromHandle(Ffi, surface_text_handle) orelse return .failed;
    const prepared_owner = prepared_surface.fromHandle(Ffi, prepared_surface_handle) orelse return .failed;
    if (prepared_owner.session_owner != owner) return .failed;
    const execution = execution_in orelse return .failed;
    const prepared_frame = preparedFrameIn(prepared_frame_in);
    if (!samePreparedFrame(prepared_owner.prepared.pipelineFrame(), prepared_frame)) return .needs_prepare;
    const submitted = owner.session.submitSurface(&prepared_owner.prepared, executionInputIn(execution.*)) catch return .failed;
    if (feedback_out) |out| out.* = surfaceFeedbackOut(Ffi, submitted);
    prepared_owner.destroy();
    return .rendered;
}

pub fn cachedSprite(comptime Ffi: type, handle: Ffi.SurfaceTextHandle, sprite_key: u64, out: ?*Ffi.FfiCachedSprite) c_int {
    const owner = ownerFromHandle(Ffi, handle) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.missing_handle);
    const cached = owner.session.atlasRaster(Render.SpriteKey{ .value = sprite_key }) orelse return @intFromEnum(Ffi.HowlRenderCallStatus.failed);
    const sprite_out = out orelse return @intFromEnum(Ffi.HowlRenderCallStatus.invalid_argument);
    sprite_out.* = .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .width_px = cached.width_px,
        .height_px = cached.height_px,
        .color_mode = @intFromEnum(cached.color_mode),
        .visual_bounds = .{ .x_px = cached.visual_bounds.x_px, .y_px = cached.visual_bounds.y_px, .width_px = cached.visual_bounds.width_px, .height_px = cached.visual_bounds.height_px },
        .pixels = .{ .ptr = if (cached.pixels.len == 0) null else cached.pixels.ptr, .len = cached.pixels.len },
    };
    return @intFromEnum(Ffi.HowlRenderCallStatus.ok);
}

fn surfaceFeedbackOut(comptime Ffi: type, value: Render.SurfaceFeedback) Ffi.FfiSurfaceFeedback {
    return .{
        .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok),
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .texture_id = value.surface.texture_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch },
        .metrics = surfaceMetricsOut(Ffi, value.metrics),
    };
}

fn surfaceMetricsOut(comptime Ffi: type, value: Render.RenderMetrics) Ffi.FfiSurfaceMetrics {
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

fn executionInputIn(value: anytype) Render.SurfaceText.SurfaceExecutionInput {
    return .{ .surface = .{ .texture_id = value.surface.texture_id, .width = value.surface.width, .height = value.surface.height, .epoch = value.surface.epoch }, .uploads_committed = value.uploads_committed, .render_us = value.render_us, .content_valid = value.content_valid != 0 };
}

fn prepareRequestIn(comptime Ffi: type, value: Ffi.FfiPrepareRequest) Render.SurfaceText.PrepareInput {
    return .{
        .config = undefined,
        .request = .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = @enumFromInt(value.damage_kind) }, .known_target_epoch = value.known_target_epoch, .allow_retained_reuse = true, .priority = .opportunistic },
        .query = undefined,
        .state = undefined,
        .target_valid = value.target_valid != 0,
    };
}

fn preparedFrameIn(value: anytype) Render.FramePipeline.PreparedFrame {
    return .{ .token = .{ .snapshot_seq = value.snapshot_seq, .dirty_epoch = value.dirty_epoch, .geometry_epoch = value.geometry_epoch, .damage_base_seq = value.damage_base_seq, .damage_kind = @enumFromInt(value.damage_kind) }, .required_base_seq = value.required_base_seq, .required_target_epoch = value.required_target_epoch };
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

fn surfaceQueryIn(value: anytype) Render.SurfaceQuery {
    return .{ .render_px = .{ .width = value.render_px.width, .height = value.render_px.height }, .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height }, .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height }, .font_size_px = value.font_size_px, .epoch = value.epoch };
}

fn surfaceSourceIn(comptime Ffi: type, allocator: std.mem.Allocator, value: Ffi.FfiSurfaceSource) !OwnedSurfaceSource {
    const cell_count = @as(usize, value.cols) * @as(usize, value.rows);
    if (value.cells.len < cell_count) return error.InvalidSurfaceSource;
    const cells = try allocator.alloc(Render.SurfaceCell, cell_count);
    errdefer allocator.free(cells);
    for (cells, 0..) |*dst, idx| dst.* = cellValueIn(Ffi, value.cells.ptr[idx]);
    const dirty_rows = try dirtyRowsIn(allocator, value.rows, value.dirty_rows);
    errdefer if (dirty_rows.len > 0) allocator.free(dirty_rows);
    const dirty_cols_start = try dirtyColsIn(allocator, value.rows, value.dirty_cols_start);
    errdefer if (dirty_cols_start.len > 0) allocator.free(dirty_cols_start);
    const dirty_cols_end = try dirtyColsIn(allocator, value.rows, value.dirty_cols_end);
    errdefer if (dirty_cols_end.len > 0) allocator.free(dirty_cols_end);
    return .{ .allocator = allocator, .cells = cells, .dirty_rows = dirty_rows, .dirty_cols_start = dirty_cols_start, .dirty_cols_end = dirty_cols_end, .frame = .{ .viewport = .{ .cols = value.cols, .rows = value.rows, .scroll_row = @intCast(value.scroll_row), .is_alternate_screen = value.is_alternate_screen != 0 }, .grid = .{ .cells = cells, .cols = value.cols, .rows = value.rows }, .cursor = cursorIn(value.cursor), .damage = .{ .full = value.full_damage != 0, .scroll_up_rows = value.scroll_up_rows, .dirty_rows = dirty_rows, .dirty_cols_start = dirty_cols_start, .dirty_cols_end = dirty_cols_end } } };
}

fn dirtyRowsIn(allocator: std.mem.Allocator, rows: u16, span: anytype) ![]bool {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    const out = try allocator.alloc(bool, rows);
    for (out, 0..) |*dst, idx| dst.* = span.ptr[idx] != 0;
    return out;
}

fn dirtyColsIn(allocator: std.mem.Allocator, rows: u16, span: anytype) ![]u16 {
    if (span.len == 0) return &.{};
    if (span.ptr == null or span.len != rows) return error.InvalidSurfaceSource;
    return try allocator.dupe(u16, span.ptr[0..rows]);
}

fn cellValueIn(comptime Ffi: type, value: Ffi.FfiCell) Render.SurfaceCell {
    return .{ .codepoint = @intCast(value.codepoint), .flags = .{ .continuation = value.flags.continuation != 0 }, .fg_color = colorIn(value.fg_color), .bg_color = colorIn(value.bg_color), .underline_color = colorIn(value.underline_color), .underline_style = underlineStyleIn(value.underline_style), .attrs = .{ .bold = value.attrs.bold != 0, .dim = value.attrs.dim != 0, .italic = value.attrs.italic != 0, .underline = value.attrs.underline != 0, .underline_color_set = value.attrs.underline_color_set != 0, .blink = value.attrs.blink != 0, .inverse = value.attrs.inverse != 0, .invisible = value.attrs.invisible != 0, .strikethrough = value.attrs.strikethrough != 0 }, .link_id = value.link_id };
}

fn colorIn(value: anytype) Render.SurfaceColor {
    return .{ .kind = switch (value.kind) { 0 => .default, 1 => .indexed, else => .rgb }, .value = @truncate(value.value) };
}

fn cursorIn(value: anytype) Render.SurfaceCursorInfo {
    return .{ .row = value.row, .col = value.col, .visible = value.visible != 0, .shape = switch (value.shape) { 1 => .underline, 2 => .beam, 3 => .hollow_block, else => .block } };
}

fn underlineStyleIn(value: u8) Render.UnderlineStyle {
    return switch (value) { 1 => .double, 2 => .curly, 3 => .dotted, 4 => .dashed, else => .straight };
}

fn pixelIn(value: anytype) surface.PixelSize {
    return .{ .width = value.width, .height = value.height };
}
