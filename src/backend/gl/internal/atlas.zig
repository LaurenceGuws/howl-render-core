
const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../../render.zig").Render;
const c_api = @import("c_api.zig");
const c = c_api.c;

pub fn uploadTextSceneRaster(
    self: anytype,
    scene: render.TextScene,
    outputs: []const render.Text.Rasterizer.RasterSpriteOutput,
) !usize {
    try ensureAtlasStorageForRasterOutputs(self, outputs);
    if (hasCurrentContext()) try ensureAtlasTexture(self);
    if (hasCurrentContext()) uploadSceneResidentSlots(self, scene);
    var committed: usize = 0;
    for (outputs) |output| {
        const slot = findSceneSpriteSlot(scene, output.key) orelse continue;
        if (textSceneSlotCached(self, slot, output)) {
            continue;
        }
        copyRasterOutputToAtlas(self, slot, output);
        if (hasCurrentContext()) _ = uploadAtlasSlot(self, slot);
        committed += 1;
    }
    return committed;
}

pub fn clearAtlasCache(self: anytype) void {
    if (self.atlas_pixels.len > 0) @memset(self.atlas_pixels, 0);
    if (self.atlas_slot_codepoint.len > 0) @memset(self.atlas_slot_codepoint, 0);
    if (self.atlas_slot_face_id.len > 0) @memset(self.atlas_slot_face_id, 0);
    if (self.atlas_slot_glyph_id.len > 0) @memset(self.atlas_slot_glyph_id, 0);
    if (self.atlas_slot_sprite_key.len > 0) @memset(self.atlas_slot_sprite_key, 0);
    if (self.atlas_slot_width.len > 0) @memset(self.atlas_slot_width, 0);
    if (self.atlas_slot_height.len > 0) @memset(self.atlas_slot_height, 0);
    if (self.atlas_slot_draw_x.len > 0) @memset(self.atlas_slot_draw_x, 0);
    if (self.atlas_slot_draw_y.len > 0) @memset(self.atlas_slot_draw_y, 0);
    if (self.atlas_slot_draw_w.len > 0) @memset(self.atlas_slot_draw_w, 0);
    if (self.atlas_slot_draw_h.len > 0) @memset(self.atlas_slot_draw_h, 0);
    if (self.atlas_slot_has_alpha.len > 0) @memset(self.atlas_slot_has_alpha, false);
    if (self.atlas_slot_gpu_uploaded.len > 0) @memset(self.atlas_slot_gpu_uploaded, false);
    self.atlas_next_slot = 0;
}

pub fn ensureAtlasStorageForRasterOutputs(
    self: anytype,
    outputs: []const render.Text.Rasterizer.RasterSpriteOutput,
) !void {
    var need_w = @max(self.config.cell_px.width, 1);
    var need_h = @max(self.config.cell_px.height, 1);
    for (outputs) |output| {
        need_w = @max(need_w, @max(output.width_px, 1));
        need_h = @max(need_h, @max(output.height_px, 1));
    }
    return ensureAtlasStorageSized(self, need_w, need_h);
}

pub fn ensureAtlasStorageSized(self: anytype, need_w: u16, need_h: u16) !void {
    const need_stride: usize = @as(usize, need_w) * @as(usize, need_h);
    if (self.atlas_pixels.len != 0 and self.atlas_cell_w == need_w and self.atlas_cell_h == need_h) return;
    const old = captureAtlasStorage(self);
    const max_slots = self.capabilities().max_atlas_slots;
    self.atlas_pixels = try std.heap.c_allocator.alloc(u8, need_stride * @as(usize, max_slots));
    @memset(self.atlas_pixels, 0);
    self.atlas_slot_codepoint = try std.heap.c_allocator.alloc(u21, max_slots);
    @memset(self.atlas_slot_codepoint, 0);
    self.atlas_slot_face_id = try std.heap.c_allocator.alloc(u32, max_slots);
    @memset(self.atlas_slot_face_id, 0);
    self.atlas_slot_glyph_id = try std.heap.c_allocator.alloc(u32, max_slots);
    @memset(self.atlas_slot_glyph_id, 0);
    self.atlas_slot_sprite_key = try std.heap.c_allocator.alloc(u64, max_slots);
    @memset(self.atlas_slot_sprite_key, 0);
    self.atlas_slot_width = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_width, 0);
    self.atlas_slot_height = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_height, 0);
    self.atlas_slot_draw_x = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_draw_x, 0);
    self.atlas_slot_draw_y = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_draw_y, 0);
    self.atlas_slot_draw_w = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_draw_w, 0);
    self.atlas_slot_draw_h = try std.heap.c_allocator.alloc(u16, max_slots);
    @memset(self.atlas_slot_draw_h, 0);
    self.atlas_slot_has_alpha = try std.heap.c_allocator.alloc(bool, max_slots);
    @memset(self.atlas_slot_has_alpha, false);
    self.atlas_slot_gpu_uploaded = try std.heap.c_allocator.alloc(bool, max_slots);
    @memset(self.atlas_slot_gpu_uploaded, false);
    self.atlas_cell_w = need_w;
    self.atlas_cell_h = need_h;
    self.atlas_slot_stride = need_stride;
    self.atlas_next_slot = old.next_slot;

    preserveAtlasCache(self, old);
    freeOldAtlasStorage(old);
    if (self.atlas_texture != 0 and hasCurrentContext()) {
        c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
        self.atlas_texture = 0;
    }
    self.atlas_tex_width = 0;
    self.atlas_tex_height = 0;
}

const AtlasStorageSnapshot = struct {
    pixels: []u8,
    slot_codepoint: []u21,
    slot_face_id: []u32,
    slot_glyph_id: []u32,
    slot_sprite_key: []u64,
    slot_width: []u16,
    slot_height: []u16,
    slot_draw_x: []u16,
    slot_draw_y: []u16,
    slot_draw_w: []u16,
    slot_draw_h: []u16,
    slot_has_alpha: []bool,
    slot_gpu_uploaded: []bool,
    cell_w: u16,
    cell_h: u16,
    stride: usize,
    next_slot: u32,
};

fn captureAtlasStorage(self: anytype) AtlasStorageSnapshot {
    return .{
        .pixels = self.atlas_pixels,
        .slot_codepoint = self.atlas_slot_codepoint,
        .slot_face_id = self.atlas_slot_face_id,
        .slot_glyph_id = self.atlas_slot_glyph_id,
        .slot_sprite_key = self.atlas_slot_sprite_key,
        .slot_width = self.atlas_slot_width,
        .slot_height = self.atlas_slot_height,
        .slot_draw_x = self.atlas_slot_draw_x,
        .slot_draw_y = self.atlas_slot_draw_y,
        .slot_draw_w = self.atlas_slot_draw_w,
        .slot_draw_h = self.atlas_slot_draw_h,
        .slot_has_alpha = self.atlas_slot_has_alpha,
        .slot_gpu_uploaded = self.atlas_slot_gpu_uploaded,
        .cell_w = self.atlas_cell_w,
        .cell_h = self.atlas_cell_h,
        .stride = self.atlas_slot_stride,
        .next_slot = self.atlas_next_slot,
    };
}

fn preserveAtlasCache(
    self: anytype,
    old: AtlasStorageSnapshot,
) void {
    if (old.pixels.len == 0) return;
    const slot_count = @min(self.atlas_slot_sprite_key.len, old.slot_sprite_key.len);
    if (slot_count == 0) return;
    std.mem.copyForwards(u21, self.atlas_slot_codepoint[0..@min(self.atlas_slot_codepoint.len, old.slot_codepoint.len)], old.slot_codepoint[0..@min(self.atlas_slot_codepoint.len, old.slot_codepoint.len)]);
    std.mem.copyForwards(u32, self.atlas_slot_face_id[0..@min(self.atlas_slot_face_id.len, old.slot_face_id.len)], old.slot_face_id[0..@min(self.atlas_slot_face_id.len, old.slot_face_id.len)]);
    std.mem.copyForwards(u32, self.atlas_slot_glyph_id[0..@min(self.atlas_slot_glyph_id.len, old.slot_glyph_id.len)], old.slot_glyph_id[0..@min(self.atlas_slot_glyph_id.len, old.slot_glyph_id.len)]);
    std.mem.copyForwards(u64, self.atlas_slot_sprite_key[0..slot_count], old.slot_sprite_key[0..slot_count]);
    std.mem.copyForwards(u16, self.atlas_slot_width[0..@min(self.atlas_slot_width.len, old.slot_width.len)], old.slot_width[0..@min(self.atlas_slot_width.len, old.slot_width.len)]);
    std.mem.copyForwards(u16, self.atlas_slot_height[0..@min(self.atlas_slot_height.len, old.slot_height.len)], old.slot_height[0..@min(self.atlas_slot_height.len, old.slot_height.len)]);
    std.mem.copyForwards(u16, self.atlas_slot_draw_x[0..@min(self.atlas_slot_draw_x.len, old.slot_draw_x.len)], old.slot_draw_x[0..@min(self.atlas_slot_draw_x.len, old.slot_draw_x.len)]);
    std.mem.copyForwards(u16, self.atlas_slot_draw_y[0..@min(self.atlas_slot_draw_y.len, old.slot_draw_y.len)], old.slot_draw_y[0..@min(self.atlas_slot_draw_y.len, old.slot_draw_y.len)]);
    std.mem.copyForwards(u16, self.atlas_slot_draw_w[0..@min(self.atlas_slot_draw_w.len, old.slot_draw_w.len)], old.slot_draw_w[0..@min(self.atlas_slot_draw_w.len, old.slot_draw_w.len)]);
    std.mem.copyForwards(u16, self.atlas_slot_draw_h[0..@min(self.atlas_slot_draw_h.len, old.slot_draw_h.len)], old.slot_draw_h[0..@min(self.atlas_slot_draw_h.len, old.slot_draw_h.len)]);
    std.mem.copyForwards(bool, self.atlas_slot_has_alpha[0..@min(self.atlas_slot_has_alpha.len, old.slot_has_alpha.len)], old.slot_has_alpha[0..@min(self.atlas_slot_has_alpha.len, old.slot_has_alpha.len)]);

    const copy_w = @min(old.cell_w, self.atlas_cell_w);
    const copy_h = @min(old.cell_h, self.atlas_cell_h);
    if (copy_w == 0 or copy_h == 0) return;
    for (0..slot_count) |slot_idx| {
        const old_off = slot_idx * old.stride;
        const new_off = slot_idx * self.atlas_slot_stride;
        if (old_off + old.stride > old.pixels.len or new_off + self.atlas_slot_stride > self.atlas_pixels.len) break;
        const src = old.pixels[old_off .. old_off + old.stride];
        const dst = self.atlas_pixels[new_off .. new_off + self.atlas_slot_stride];
        for (0..copy_h) |yy| {
            const src_off = yy * @as(usize, old.cell_w);
            const dst_off = yy * @as(usize, self.atlas_cell_w);
            @memcpy(dst[dst_off .. dst_off + copy_w], src[src_off .. src_off + copy_w]);
        }
    }
}

fn freeOldAtlasStorage(old: AtlasStorageSnapshot) void {
    if (old.pixels.len > 0) std.heap.c_allocator.free(old.pixels);
    if (old.slot_codepoint.len > 0) std.heap.c_allocator.free(old.slot_codepoint);
    if (old.slot_face_id.len > 0) std.heap.c_allocator.free(old.slot_face_id);
    if (old.slot_glyph_id.len > 0) std.heap.c_allocator.free(old.slot_glyph_id);
    if (old.slot_sprite_key.len > 0) std.heap.c_allocator.free(old.slot_sprite_key);
    if (old.slot_width.len > 0) std.heap.c_allocator.free(old.slot_width);
    if (old.slot_height.len > 0) std.heap.c_allocator.free(old.slot_height);
    if (old.slot_draw_x.len > 0) std.heap.c_allocator.free(old.slot_draw_x);
    if (old.slot_draw_y.len > 0) std.heap.c_allocator.free(old.slot_draw_y);
    if (old.slot_draw_w.len > 0) std.heap.c_allocator.free(old.slot_draw_w);
    if (old.slot_draw_h.len > 0) std.heap.c_allocator.free(old.slot_draw_h);
    if (old.slot_has_alpha.len > 0) std.heap.c_allocator.free(old.slot_has_alpha);
    if (old.slot_gpu_uploaded.len > 0) std.heap.c_allocator.free(old.slot_gpu_uploaded);
}

fn uploadSceneResidentSlots(self: anytype, scene: render.TextScene) void {
    for (scene.sprite_draws) |draw| {
        const slot = draw.sprite.slot;
        if (slotGpuUploaded(self, slot)) continue;
        if (!slotMatchesSprite(self, slot, draw.sprite.key)) continue;
        _ = uploadAtlasSlot(self, slot);
    }
}

fn slotMatchesSprite(self: anytype, slot: u32, key: render.SpriteKey) bool {
    const slot_idx = @as(usize, slot);
    return slot_idx < self.atlas_slot_sprite_key.len and self.atlas_slot_sprite_key[slot_idx] == key.value;
}

pub fn ensureAtlasTexture(self: anytype) !void {
    if (!hasCurrentContext()) return;
    const max_slots = self.capabilities().max_atlas_slots;
    const Backend = @TypeOf(self.*);
    const cols: usize = @min(max_slots, Backend.AtlasTexCols);
    const rows: usize = std.math.divCeil(usize, max_slots, cols) catch unreachable;
    const need_w: u16 = @intCast(@as(usize, self.atlas_cell_w) * cols);
    const need_h: u16 = @intCast(@as(usize, self.atlas_cell_h) * rows);
    if (self.atlas_texture != 0 and self.atlas_tex_width == need_w and self.atlas_tex_height == need_h) return;

    if (self.atlas_texture != 0) {
        c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
        self.atlas_texture = 0;
    }

    c.glGenTextures(1, @ptrCast(&self.atlas_texture));
    c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
    resetAtlasUnpackState();
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        @as(c_int, @intCast(need_w)),
        @as(c_int, @intCast(need_h)),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    self.atlas_tex_width = need_w;
    self.atlas_tex_height = need_h;
}

pub fn textSceneSlotCached(
    self: anytype,
    slot: u32,
    output: render.Text.Rasterizer.RasterSpriteOutput,
) bool {
    const idx = @as(usize, slot);
    if (idx >= self.atlas_slot_sprite_key.len) return false;
    if (idx >= self.atlas_slot_width.len or idx >= self.atlas_slot_height.len) return false;
    return self.atlas_slot_sprite_key[idx] == output.key.value and
        self.atlas_slot_width[idx] == output.width_px and
        self.atlas_slot_height[idx] == output.height_px;
}

pub fn copyRasterOutputToAtlas(
    self: anytype,
    slot: u32,
    output: render.Text.Rasterizer.RasterSpriteOutput,
) void {
    if (self.atlas_pixels.len == 0) return;
    const slot_idx = @as(usize, slot);
    const slot_off = slot_idx * self.atlas_slot_stride;
    if (slot_off + self.atlas_slot_stride > self.atlas_pixels.len) return;
    const dst = self.atlas_pixels[slot_off .. slot_off + self.atlas_slot_stride];
    @memset(dst, 0);
    const copy_w = @min(output.width_px, self.atlas_cell_w);
    const copy_h = @min(output.height_px, self.atlas_cell_h);
    for (0..copy_h) |yy| {
        const src_off = yy * @as(usize, output.width_px);
        const dst_off = yy * @as(usize, self.atlas_cell_w);
        @memcpy(dst[dst_off .. dst_off + copy_w], output.pixels[src_off .. src_off + copy_w]);
    }
    if (slot_idx < self.atlas_slot_codepoint.len) self.atlas_slot_codepoint[slot_idx] = 0;
    if (slot_idx < self.atlas_slot_face_id.len) self.atlas_slot_face_id[slot_idx] = 0;
    if (slot_idx < self.atlas_slot_glyph_id.len) self.atlas_slot_glyph_id[slot_idx] = @intCast(output.key.value & 0xffff_ffff);
    if (slot_idx < self.atlas_slot_sprite_key.len) self.atlas_slot_sprite_key[slot_idx] = output.key.value;
    if (slot_idx < self.atlas_slot_width.len) self.atlas_slot_width[slot_idx] = output.width_px;
    if (slot_idx < self.atlas_slot_height.len) self.atlas_slot_height[slot_idx] = output.height_px;
    const bounds = clippedBounds(output.visualBounds(), self.atlas_cell_w, self.atlas_cell_h);
    if (slot_idx < self.atlas_slot_draw_x.len) self.atlas_slot_draw_x[slot_idx] = bounds.x_px;
    if (slot_idx < self.atlas_slot_draw_y.len) self.atlas_slot_draw_y[slot_idx] = bounds.y_px;
    if (slot_idx < self.atlas_slot_draw_w.len) self.atlas_slot_draw_w[slot_idx] = bounds.width_px;
    if (slot_idx < self.atlas_slot_draw_h.len) self.atlas_slot_draw_h[slot_idx] = bounds.height_px;
    markSlotAlpha(self, slot, dst, copy_w, copy_h);
}

fn clippedBounds(bounds: render.Text.Rasterizer.SpriteBounds, max_w: u16, max_h: u16) render.Text.Rasterizer.SpriteBounds {
    if (bounds.width_px == 0 or bounds.height_px == 0) return .{};
    if (bounds.x_px >= max_w or bounds.y_px >= max_h) return .{};
    return .{
        .x_px = bounds.x_px,
        .y_px = bounds.y_px,
        .width_px = @min(bounds.width_px, max_w - bounds.x_px),
        .height_px = @min(bounds.height_px, max_h - bounds.y_px),
    };
}

fn uploadAtlasSlot(self: anytype, slot: u32) bool {
    if (self.atlas_texture == 0 or self.atlas_pixels.len == 0) return false;
    const slot_idx = @as(usize, slot);
    const slot_off = slot_idx * self.atlas_slot_stride;
    if (slot_off + self.atlas_slot_stride > self.atlas_pixels.len) return false;
    const Backend = @TypeOf(self.*);
    const cols = @min(self.capabilities().max_atlas_slots, Backend.AtlasTexCols);
    const cell_w = @as(usize, self.atlas_cell_w);
    const cell_h = @as(usize, self.atlas_cell_h);
    const x = (slot_idx % cols) * cell_w;
    const y = (slot_idx / cols) * cell_h;
    const rgba = std.heap.c_allocator.alloc(u8, cell_w * cell_h * 4) catch return false;
    defer std.heap.c_allocator.free(rgba);
    const alpha = self.atlas_pixels[slot_off .. slot_off + self.atlas_slot_stride];
    for (alpha, 0..) |a, i| {
        const dst = i * 4;
        rgba[dst + 0] = 255;
        rgba[dst + 1] = 255;
        rgba[dst + 2] = 255;
        rgba[dst + 3] = a;
    }
    c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
    resetAtlasUnpackState();
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        @as(c_int, @intCast(x)),
        @as(c_int, @intCast(y)),
        @as(c_int, @intCast(cell_w)),
        @as(c_int, @intCast(cell_h)),
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        rgba.ptr,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    if (slot_idx < self.atlas_slot_gpu_uploaded.len) self.atlas_slot_gpu_uploaded[slot_idx] = true;
    return true;
}

fn slotGpuUploaded(self: anytype, slot: u32) bool {
    const slot_idx = @as(usize, slot);
    return slot_idx < self.atlas_slot_gpu_uploaded.len and self.atlas_slot_gpu_uploaded[slot_idx];
}

fn resetAtlasUnpackState() void {
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
    c.glPixelStorei(c.GL_UNPACK_SKIP_PIXELS, 0);
    c.glPixelStorei(c.GL_UNPACK_SKIP_ROWS, 0);
}

fn markSlotAlpha(self: anytype, slot: u32, pixels: []const u8, gw: u16, gh: u16) void {
    const slot_idx = @as(usize, slot);
    if (slot_idx >= self.atlas_slot_has_alpha.len) return;
    for (0..gh) |yy| {
        for (0..gw) |xx| {
            if (pixels[yy * @as(usize, self.atlas_cell_w) + xx] != 0) {
                self.atlas_slot_has_alpha[slot_idx] = true;
                return;
            }
        }
    }
    self.atlas_slot_has_alpha[slot_idx] = false;
}

fn findSceneSpriteSlot(scene: render.TextScene, key: render.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn hasCurrentContext() bool {
    return if (builtin.is_test) c.glGetString(c.GL_VERSION) != null else c.glGetString(c.GL_VERSION) != null;
}
