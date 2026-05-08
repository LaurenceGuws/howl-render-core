const builtin = @import("builtin");
const std = @import("std");
const render_core = @import("../../../render_core.zig").RenderCore;
const c_api = @import("c_api.zig");
const c = c_api.c;

pub fn uploadTextSceneRaster(
    self: anytype,
    scene: render_core.TextScene,
    outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput,
) !usize {
    try ensureAtlasStorageForRasterOutputs(self, outputs);
    if (hasCurrentContext()) try ensureAtlasTexture(self);
    var committed: usize = 0;
    for (outputs) |output| {
        const slot = findSceneSpriteSlot(scene, output.key) orelse continue;
        if (textSceneSlotCached(self, slot, output)) continue;
        copyRasterOutputToAtlas(self, slot, output);
        if (hasCurrentContext()) uploadAtlasSlot(self, slot);
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
    if (self.atlas_slot_has_alpha.len > 0) @memset(self.atlas_slot_has_alpha, false);
    self.atlas_next_slot = 0;
}

pub fn ensureAtlasStorageForRasterOutputs(
    self: anytype,
    outputs: []const render_core.Text.Rasterizer.RasterSpriteOutput,
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
    if (self.atlas_pixels.len > 0) {
        std.heap.c_allocator.free(self.atlas_pixels);
        self.atlas_pixels = &.{};
    }
    if (self.atlas_slot_codepoint.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_codepoint);
        self.atlas_slot_codepoint = &.{};
    }
    if (self.atlas_slot_face_id.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_face_id);
        self.atlas_slot_face_id = &.{};
    }
    if (self.atlas_slot_glyph_id.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_glyph_id);
        self.atlas_slot_glyph_id = &.{};
    }
    if (self.atlas_slot_sprite_key.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_sprite_key);
        self.atlas_slot_sprite_key = &.{};
    }
    if (self.atlas_slot_width.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_width);
        self.atlas_slot_width = &.{};
    }
    if (self.atlas_slot_height.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_height);
        self.atlas_slot_height = &.{};
    }
    if (self.atlas_slot_has_alpha.len > 0) {
        std.heap.c_allocator.free(self.atlas_slot_has_alpha);
        self.atlas_slot_has_alpha = &.{};
    }
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
    self.atlas_slot_has_alpha = try std.heap.c_allocator.alloc(bool, max_slots);
    @memset(self.atlas_slot_has_alpha, false);
    self.atlas_cell_w = need_w;
    self.atlas_cell_h = need_h;
    self.atlas_slot_stride = need_stride;
    self.atlas_next_slot = 0;
    if (self.atlas_texture != 0 and hasCurrentContext()) {
        c.glDeleteTextures(1, @ptrCast(&self.atlas_texture));
        self.atlas_texture = 0;
    }
    self.atlas_tex_width = 0;
    self.atlas_tex_height = 0;
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
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_ALPHA,
        @as(c_int, @intCast(need_w)),
        @as(c_int, @intCast(need_h)),
        0,
        c.GL_ALPHA,
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
    output: render_core.Text.Rasterizer.RasterSpriteOutput,
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
    output: render_core.Text.Rasterizer.RasterSpriteOutput,
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
    markSlotAlpha(self, slot, dst, copy_w, copy_h);
}

fn uploadAtlasSlot(self: anytype, slot: u32) void {
    if (self.atlas_texture == 0 or self.atlas_pixels.len == 0) return;
    const slot_idx = @as(usize, slot);
    const slot_off = slot_idx * self.atlas_slot_stride;
    if (slot_off + self.atlas_slot_stride > self.atlas_pixels.len) return;
    const Backend = @TypeOf(self.*);
    const cols = @min(self.capabilities().max_atlas_slots, Backend.AtlasTexCols);
    const cell_w = @as(usize, self.atlas_cell_w);
    const cell_h = @as(usize, self.atlas_cell_h);
    const x = (slot_idx % cols) * cell_w;
    const y = (slot_idx / cols) * cell_h;
    c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        @as(c_int, @intCast(x)),
        @as(c_int, @intCast(y)),
        @as(c_int, @intCast(cell_w)),
        @as(c_int, @intCast(cell_h)),
        c.GL_ALPHA,
        c.GL_UNSIGNED_BYTE,
        self.atlas_pixels[slot_off..].ptr,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
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

fn findSceneSpriteSlot(scene: render_core.TextScene, key: render_core.SpriteKey) ?u32 {
    for (scene.sprite_draws) |draw| {
        if (draw.sprite.key.value == key.value) return draw.sprite.slot;
    }
    return null;
}

fn hasCurrentContext() bool {
    return if (builtin.is_test) c.glGetString(c.GL_VERSION) != null else c.glGetString(c.GL_VERSION) != null;
}
