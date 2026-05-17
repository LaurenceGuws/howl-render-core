const std = @import("std");
const Render = @import("howl_render.zig");
const surface = @import("frame/surface.zig");

pub fn Owner(comptime Ffi: type) type {
    return struct {
        session_owner: *surface.SurfaceTextOwner,
        prepared: Render.PreparedSurface,
        snapshot_seq: u64,
        dirty_epoch: u64,
        geometry_epoch: u64,
        required_base_seq: u64,
        required_surface_epoch: u64,
        render_px: Ffi.FfiPixelSize,
        cell_px: Ffi.FfiCellSize,
        grid: Ffi.FfiGridSize,
        prepare_metrics: Ffi.FfiSurfaceMetrics,
        damage_kind: u8,
        full_redraw: u8,
        scroll_up_px: u16,
        clear_draws: []Ffi.FfiColorDraw = &.{},
        background_draws: []Ffi.FfiColorDraw = &.{},
        sprite_batches: []Ffi.FfiSpriteBatch = &.{},
        sprite_instances: []Ffi.FfiSpriteInstance = &.{},
        decoration_draws: []Ffi.FfiDecorationDraw = &.{},
        cursor_draws: []Ffi.FfiColorDraw = &.{},
        surface_damage_rects: []Ffi.FfiRect = &.{},
        buffer_damage_rects: []Ffi.FfiRect = &.{},
        uploads: []Ffi.FfiUploadOp = &.{},
        pixel_blob: []u8 = &.{},
        missing_glyphs: u64,
        resolve_metrics: Ffi.FfiSurfaceMetrics,

        pub fn destroy(self: *@This()) void {
            self.prepared.deinit();
            freeOwnedSlice(Ffi.FfiColorDraw, &self.clear_draws);
            freeOwnedSlice(Ffi.FfiColorDraw, &self.background_draws);
            freeOwnedSlice(Ffi.FfiSpriteBatch, &self.sprite_batches);
            freeOwnedSlice(Ffi.FfiSpriteInstance, &self.sprite_instances);
            freeOwnedSlice(Ffi.FfiDecorationDraw, &self.decoration_draws);
            freeOwnedSlice(Ffi.FfiColorDraw, &self.cursor_draws);
            freeOwnedSlice(Ffi.FfiRect, &self.surface_damage_rects);
            freeOwnedSlice(Ffi.FfiRect, &self.buffer_damage_rects);
            freeOwnedSlice(Ffi.FfiUploadOp, &self.uploads);
            freeOwnedSlice(u8, &self.pixel_blob);
            std.heap.c_allocator.destroy(self);
        }
    };
}

pub fn create(comptime Ffi: type, session_owner: *surface.SurfaceTextOwner, value: Render.PreparedSurface) !*Owner(Ffi) {
    var owner = try std.heap.c_allocator.create(Owner(Ffi));
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

    owner.clear_draws = try std.heap.c_allocator.alloc(Ffi.FfiColorDraw, value.text_frame.scene.scene.clear_draws.len);
    for (value.text_frame.scene.scene.clear_draws, 0..) |draw, idx| owner.clear_draws[idx] = .{ .x_px = draw.x_px, .y_px = draw.y_px, .width_px = draw.width_px, .height_px = draw.height_px, .color = rgba8Out(Ffi, draw.color) };
    owner.background_draws = try std.heap.c_allocator.alloc(Ffi.FfiColorDraw, value.text_frame.scene.scene.background_draws.len);
    for (value.text_frame.scene.scene.background_draws, 0..) |draw, idx| owner.background_draws[idx] = .{ .x_px = draw.x_px, .y_px = draw.y_px, .width_px = draw.width_px, .height_px = draw.height_px, .color = rgba8Out(Ffi, draw.color) };
    owner.decoration_draws = try std.heap.c_allocator.alloc(Ffi.FfiDecorationDraw, value.text_frame.scene.scene.decoration_draws.len);
    for (value.text_frame.scene.scene.decoration_draws, 0..) |draw, idx| owner.decoration_draws[idx] = .{ .kind = @intFromEnum(draw.kind), .x_px = draw.x_px, .y_px = draw.y_px, .width_px = draw.width_px, .height_px = draw.height_px, .color = rgba8Out(Ffi, draw.color) };
    owner.cursor_draws = try std.heap.c_allocator.alloc(Ffi.FfiColorDraw, value.text_frame.scene.scene.cursor_draws.len);
    for (value.text_frame.scene.scene.cursor_draws, 0..) |draw, idx| owner.cursor_draws[idx] = .{ .x_px = draw.x_px, .y_px = draw.y_px, .width_px = draw.width_px, .height_px = draw.height_px, .color = rgba8Out(Ffi, draw.color) };

    owner.surface_damage_rects = try std.heap.c_allocator.alloc(Ffi.FfiRect, value.surface_damage_rects.len);
    for (value.surface_damage_rects, 0..) |rect, idx| owner.surface_damage_rects[idx] = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    owner.buffer_damage_rects = try std.heap.c_allocator.alloc(Ffi.FfiRect, value.buffer_damage_rects.len);
    for (value.buffer_damage_rects, 0..) |rect, idx| owner.buffer_damage_rects[idx] = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };

    owner.uploads = try std.heap.c_allocator.alloc(Ffi.FfiUploadOp, value.text_frame.raster_plan.outputs.len);
    var blob_len: usize = 0;
    for (value.text_frame.raster_plan.outputs) |output| blob_len += output.pixels.len;
    owner.pixel_blob = try std.heap.c_allocator.alloc(u8, blob_len);
    var blob_offset: usize = 0;
    for (value.text_frame.raster_plan.outputs, 0..) |output, idx| {
        const slot = findSceneSpriteSlot(value.text_frame.scene.scene, output.key) orelse continue;
        const bounds = output.visualBounds();
        const pixels = output.pixels;
        if (pixels.len > 0) std.mem.copyForwards(u8, owner.pixel_blob[blob_offset .. blob_offset + pixels.len], pixels);
        owner.uploads[idx] = .{
            .sprite_key = output.key.value,
            .slot = slot,
            .atlas_page = atlasPageForPrepared(slot, value.atlas_page_slots),
            .pixel_format = pixelFormatForOutput(output),
            .color_mode = @intFromEnum(output.color_mode),
            .width_px = output.width_px,
            .height_px = output.height_px,
            .stride = packedStrideForOutput(output),
            .blob_offset = blob_offset,
            .blob_len = pixels.len,
            .visual_bounds = .{ .x_px = bounds.x_px, .y_px = bounds.y_px, .width_px = bounds.width_px, .height_px = bounds.height_px },
        };
        blob_offset += pixels.len;
    }

    owner.sprite_instances = try std.heap.c_allocator.alloc(Ffi.FfiSpriteInstance, value.text_frame.scene.scene.sprite_draws.len);
    for (value.text_frame.scene.scene.sprite_draws, 0..) |draw, idx| {
        const upload = findUploadOp(Ffi, owner.uploads, draw.sprite.key.value, draw.sprite.slot);
        const src_width_px = if (upload) |op| op.visual_bounds.width_px else draw.width_px;
        const src_height_px = if (upload) |op| op.visual_bounds.height_px else draw.height_px;
        owner.sprite_instances[idx] = .{
            .slot = draw.sprite.slot,
            .sprite_key = draw.sprite.key.value,
            .dst_x_px = draw.x_px,
            .dst_y_px = draw.y_px,
            .dst_width_px = draw.width_px,
            .dst_height_px = draw.height_px,
            .src_x_px = if (upload) |op| op.visual_bounds.x_px else 0,
            .src_y_px = if (upload) |op| op.visual_bounds.y_px else 0,
            .src_width_px = src_width_px,
            .src_height_px = src_height_px,
            .color = rgba8Out(Ffi, draw.color),
        };
    }
    owner.sprite_batches = try std.heap.c_allocator.alloc(Ffi.FfiSpriteBatch, value.sprite_batches.len);
    for (value.sprite_batches, 0..) |batch, idx| owner.sprite_batches[idx] = .{ .atlas_page = batch.atlas_page, .pass_kind = @intFromEnum(batch.pass_kind), .first_instance = batch.first_instance, .instance_count = batch.instance_count };
    return owner;
}

pub fn fromHandle(comptime Ffi: type, handle: Ffi.PreparedSurfaceHandle) ?*Owner(Ffi) {
    const owned = handle orelse return null;
    return @ptrCast(@alignCast(owned));
}

pub fn infoOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceInfo {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .snapshot_seq = owner.snapshot_seq, .dirty_epoch = owner.dirty_epoch, .geometry_epoch = owner.geometry_epoch, .required_base_seq = owner.required_base_seq, .required_surface_epoch = owner.required_surface_epoch, .render_px = owner.render_px, .cell_px = owner.cell_px, .grid = owner.grid, .prepare_metrics = owner.prepare_metrics, .damage_kind = owner.damage_kind };
}

pub fn damagePlanOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceDamagePlan {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .full_redraw = owner.full_redraw, .scroll_up_px = owner.scroll_up_px, .surface_damage_rects = span(Ffi.FfiRectSpan, owner.surface_damage_rects), .buffer_damage_rects = span(Ffi.FfiRectSpan, owner.buffer_damage_rects) };
}

pub fn uploadPlanOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceUploadPlan {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .uploads = span(Ffi.FfiUploadOpSpan, owner.uploads), .pixel_blob = span(Ffi.FfiByteSpan, owner.pixel_blob) };
}

pub fn drawPlanOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceDrawPlan {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .clear_draws = span(Ffi.FfiColorDrawSpan, owner.clear_draws), .background_draws = span(Ffi.FfiColorDrawSpan, owner.background_draws), .sprite_batches = span(Ffi.FfiSpriteBatchSpan, owner.sprite_batches), .sprite_instances = span(Ffi.FfiSpriteInstanceSpan, owner.sprite_instances), .decoration_draws = span(Ffi.FfiDecorationDrawSpan, owner.decoration_draws), .cursor_draws = span(Ffi.FfiColorDrawSpan, owner.cursor_draws) };
}

pub fn diagnosticsOut(comptime Ffi: type, owner: *Owner(Ffi)) Ffi.FfiPreparedSurfaceDiagnostics {
    return .{ .status = @intFromEnum(Ffi.HowlRenderCallStatus.ok), .missing_glyphs = owner.missing_glyphs, .resolve_metrics = owner.resolve_metrics };
}

fn rgba8Out(comptime Ffi: type, value: Render.Rgba8) Ffi.FfiRgba8 {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
}

fn boolByte(value: bool) u8 {
    return if (value) 1 else 0;
}

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
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

fn findUploadOp(comptime Ffi: type, uploads: []const Ffi.FfiUploadOp, sprite_key: u64, slot: u32) ?Ffi.FfiUploadOp {
    for (uploads) |upload| {
        if (upload.sprite_key == sprite_key and upload.slot == slot) return upload;
    }
    return null;
}

fn findSceneSpriteSlot(scene: Render.TextScene, key: Render.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn atlasPageForPrepared(slot: u32, atlas_page_slots: u32) u16 {
    if (atlas_page_slots == 0) return 0;
    return @intCast(slot / atlas_page_slots);
}

fn span(comptime Span: type, items: anytype) Span {
    return .{ .ptr = if (items.len == 0) null else items.ptr, .len = items.len };
}
