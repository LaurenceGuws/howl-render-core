const builtin = @import("builtin");
const std = @import("std");
const render = @import("../../../render.zig").Render;
const clip_rect = @import("../../shared/clip_rect.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

pub const TexturedGlyph = struct {
    clipped: clip_rect.ClipRect,
    color: render.Rgba8,
    tex_u0: f32,
    tex_v0: f32,
    tex_u1: f32,
    tex_v1: f32,
};

pub const TexturedVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

pub const QuadVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const DrawPass = struct {
    atlas_texture: u32 = 0,
    atlas_tex_width: u16 = 0,
    atlas_tex_height: u16 = 0,
    scroll_scratch_texture: u32 = 0,
    scroll_scratch_width: u16 = 0,
    scroll_scratch_height: u16 = 0,
    fill_vertices: []QuadVertex = &.{},
    glyph_vertices: []QuadVertex = &.{},
    text_vertices: []TexturedVertex = &.{},
    text_shader_program: u32 = 0,
    text_shader_pos_loc: c_int = -1,
    text_shader_uv_loc: c_int = -1,
    text_shader_color_loc: c_int = -1,
    text_shader_sampler_loc: c_int = -1,
    fallback_fill_vertices: []QuadVertex = &.{},
};

pub fn prepareSceneTarget(self: anytype) !void {
    if (self.target_texture == null and self.config.target_texture != 0) {
        self.target_texture = self.config.target_texture;
        self.surface_epoch +%= 1;
        self.target_content_valid = false;
    }
    try ensureOwnedTargetTexture(self);
    if (self.target_texture == null) return error.TargetTextureUnset;
}

pub fn beginTargetPass(self: anytype) !void {
    if (self.target_texture == null) return error.TargetTextureUnset;
    if (self.target_fbo == 0) {
        c.glGenFramebuffersEXT(1, @ptrCast(&self.target_fbo));
    }
    c.glBindFramebufferEXT(c.GL_FRAMEBUFFER_EXT, self.target_fbo);
    c.glFramebufferTexture2DEXT(
        c.GL_FRAMEBUFFER_EXT,
        c.GL_COLOR_ATTACHMENT0_EXT,
        c.GL_TEXTURE_2D,
        @intCast(self.target_texture.?),
        0,
    );
    if (c.glCheckFramebufferStatusEXT(c.GL_FRAMEBUFFER_EXT) != c.GL_FRAMEBUFFER_COMPLETE_EXT) {
        return error.FramebufferIncomplete;
    }
}

pub fn endTargetPass(_: anytype) void {
    c.glBindFramebufferEXT(c.GL_FRAMEBUFFER_EXT, 0);
}

pub fn resizeOwnedTargetTexture(self: anytype) void {
    const texture = self.target_texture orelse return;
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        @as(c_int, @intCast(@max(self.config.surface_px.width, 1))),
        @as(c_int, @intCast(@max(self.config.surface_px.height, 1))),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    self.target_content_valid = false;
}

pub fn applyScrollReusePx(self: anytype, surface_px: render.PixelSize, scroll_px_u16: u16) void {
    const scroll_px = @as(u32, scroll_px_u16);
    const width = @as(u32, surface_px.width);
    const height = @as(u32, surface_px.height);
    if (scroll_px == 0 or scroll_px >= height) return;
    ensureScrollScratchTexture(self, surface_px) catch return;
    if (self.draw_pass.scroll_scratch_texture == 0) return;

    c.glBindTexture(c.GL_TEXTURE_2D, self.draw_pass.scroll_scratch_texture);
    c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, 0, @as(c_int, @intCast(width)), @as(c_int, @intCast(height)));

    c.glDisable(c.GL_BLEND);
    c.glEnable(c.GL_TEXTURE_2D);
    c.glBindTexture(c.GL_TEXTURE_2D, self.draw_pass.scroll_scratch_texture);
    c.glTexEnvi(c.GL_TEXTURE_ENV, c.GL_TEXTURE_ENV_MODE, c.GL_REPLACE);
    c.glColor4ub(255, 255, 255, 255);
    c.glBegin(c.GL_QUADS);
    const top_v: f32 = 1.0 - @as(f32, @floatFromInt(scroll_px)) / @as(f32, @floatFromInt(height));
    c.glTexCoord2f(0.0, top_v);
    c.glVertex2f(0.0, 0.0);
    c.glTexCoord2f(1.0, top_v);
    c.glVertex2f(@floatFromInt(width), 0.0);
    c.glTexCoord2f(1.0, 0.0);
    c.glVertex2f(@floatFromInt(width), @floatFromInt(height - scroll_px));
    c.glTexCoord2f(0.0, 0.0);
    c.glVertex2f(0.0, @floatFromInt(height - scroll_px));
    c.glEnd();
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glDisable(c.GL_TEXTURE_2D);
}

pub fn deinitTargetObjects(self: anytype) void {
    if (self.draw_pass.atlas_texture != 0 and hasCurrentContext()) {
        c.glDeleteTextures(1, @ptrCast(&self.draw_pass.atlas_texture));
        self.draw_pass.atlas_texture = 0;
    }
    if (self.draw_pass.scroll_scratch_texture != 0 and hasCurrentContext()) {
        c.glDeleteTextures(1, @ptrCast(&self.draw_pass.scroll_scratch_texture));
        self.draw_pass.scroll_scratch_texture = 0;
    }
    if (self.target_fbo != 0 and hasCurrentContext()) {
        c.glDeleteFramebuffersEXT(1, @ptrCast(&self.target_fbo));
        self.target_fbo = 0;
    }
    if (self.owns_target_texture and self.target_texture != null and hasCurrentContext()) {
        var texture = self.target_texture.?;
        c.glDeleteTextures(1, @ptrCast(&texture));
    }
}

pub fn deinitDrawResources(self: anytype) void {
    freeOwnedSlice(QuadVertex, &self.draw_pass.fill_vertices);
    freeOwnedSlice(QuadVertex, &self.draw_pass.glyph_vertices);
    freeOwnedSlice(TexturedVertex, &self.draw_pass.text_vertices);
    freeOwnedSlice(QuadVertex, &self.draw_pass.fallback_fill_vertices);
    if (self.draw_pass.text_shader_program != 0 and hasCurrentContext()) {
        c.glDeleteProgram(self.draw_pass.text_shader_program);
        self.draw_pass.text_shader_program = 0;
    }
}

pub fn drawTextScene(self: anytype, surface: render.PixelSize, scene: render.TextScene) void {
    c.glViewport(0, 0, @as(c_int, @intCast(surface.width)), @as(c_int, @intCast(surface.height)));
    c.glDisable(c.GL_DEPTH_TEST);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glPushMatrix();
    c.glLoadIdentity();
    c.glOrtho(0.0, @as(f64, @floatFromInt(surface.width)), @as(f64, @floatFromInt(surface.height)), 0.0, -1.0, 1.0);
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glPushMatrix();
    c.glLoadIdentity();
    c.glDisable(c.GL_TEXTURE_2D);
    defer {
        c.glDisable(c.GL_TEXTURE_2D);
        c.glPopMatrix();
        c.glMatrixMode(c.GL_PROJECTION);
        c.glPopMatrix();
        c.glMatrixMode(c.GL_MODELVIEW);
    }

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    defer c.glDisable(c.GL_BLEND);

    if (scene.full_redraw) {
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0.0, 0.0, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    } else if (scene.scroll_up_px > 0) {
        applyScrollReusePx(self, surface, scene.scroll_up_px);
    }

    drawSceneRectBatch(render.TextClearDraw, self, surface, scene.clear_draws);
    drawSceneRectBatch(render.TextBackgroundDraw, self, surface, scene.background_draws);
    drawSceneRectBatch(render.TextDecorationDraw, self, surface, scene.decoration_draws);
    if (self.draw_pass.atlas_texture != 0) {
        c.glEnable(c.GL_TEXTURE_2D);
        c.glBindTexture(c.GL_TEXTURE_2D, self.draw_pass.atlas_texture);
        c.glTexEnvi(c.GL_TEXTURE_ENV, c.GL_TEXTURE_ENV_MODE, c.GL_MODULATE);
    }
    drawSceneSprites(self, surface, scene.sprite_draws);
    if (self.draw_pass.atlas_texture != 0) {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glDisable(c.GL_TEXTURE_2D);
    }
    drawSceneRectBatch(render.TextCursorDraw, self, surface, scene.cursor_draws);
}

pub fn textSceneRenderReport(comptime Report: type, self: anytype, scene: render.TextScene) Report {
    return .{
        .pass_index = self.pass_count,
        .texture_id = self.target_texture orelse 0,
        .raster_uploads_committed = 0,
        .full_redraw = scene.full_redraw,
        .scroll_up_px = scene.scroll_up_px,
        .clear_draws = scene.clear_draws.len,
        .background_draws = scene.background_draws.len,
        .sprite_draws = scene.sprite_draws.len,
        .decoration_draws = scene.decoration_draws.len,
        .cursor_draws = scene.cursor_draws.len,
    };
}

pub fn hasCurrentContext() bool {
    return if (builtin.is_test) c.glGetString(c.GL_VERSION) != null else c.glGetString(c.GL_VERSION) != null;
}

fn drawSceneRectBatch(comptime Draw: type, self: anytype, surface: render.PixelSize, draws: []const Draw) void {
    if (draws.len == 0) return;
    var vertices = ensureVertexCapacity(&self.draw_pass.fill_vertices, @intCast(draws.len * 4)) orelse {
        for (draws) |draw| drawRect(surface, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
        return;
    };
    var count: u32 = 0;
    for (draws) |draw| {
        _ = appendRectVertices(surface, vertices, &count, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
    drawSolidVertices(vertices[0..count]);
}

fn drawSceneSprites(self: anytype, surface: render.PixelSize, draws: []const render.TextSpriteDraw) void {
    if (draws.len == 0) return;
    if (ensureTextShader(self)) {
        drawSceneSpritesShader(self, surface, draws);
        return;
    }
    var sprite_vertices = ensureVertexCapacity(&self.draw_pass.glyph_vertices, @intCast(draws.len * 4)) orelse {
        for (draws) |draw| drawSceneSprite(self, surface, draw);
        return;
    };
    var sprite_count: u32 = 0;
    for (draws) |draw| {
        const textured = prepareTexturedSceneSprite(self, surface, draw) orelse continue;
        appendTexturedGlyphVertices(sprite_vertices, &sprite_count, textured);
    }
    drawTexturedVertices(sprite_vertices[0..sprite_count]);
}

fn drawSceneSpritesShader(self: anytype, surface: render.PixelSize, draws: []const render.TextSpriteDraw) void {
    if (self.draw_pass.text_shader_program == 0 or self.draw_pass.atlas_texture == 0) return;
    c.glUseProgram(self.draw_pass.text_shader_program);
    defer c.glUseProgram(0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, self.draw_pass.atlas_texture);
    if (self.draw_pass.text_shader_sampler_loc >= 0) c.glUniform1i(self.draw_pass.text_shader_sampler_loc, 0);

    for (draws) |draw| {
        const textured = prepareTexturedSceneSprite(self, surface, draw) orelse continue;
        if (self.draw_pass.text_shader_color_loc >= 0) {
            c.glUniform4f(
                self.draw_pass.text_shader_color_loc,
                @as(f32, @floatFromInt(textured.color.r)) / 255.0,
                @as(f32, @floatFromInt(textured.color.g)) / 255.0,
                @as(f32, @floatFromInt(textured.color.b)) / 255.0,
                @as(f32, @floatFromInt(textured.color.a)) / 255.0,
            );
        }
        drawTexturedGlyphShader(self, textured);
    }
}

fn drawSceneSprite(self: anytype, surface: render.PixelSize, draw: render.TextSpriteDraw) void {
    const textured = prepareTexturedSceneSprite(self, surface, draw) orelse return;
    c.glEnable(c.GL_TEXTURE_2D);
    c.glColor4ub(textured.color.r, textured.color.g, textured.color.b, textured.color.a);
    c.glBegin(c.GL_QUADS);
    emitTexturedGlyph(textured);
    c.glEnd();
}

fn ensureVertexCapacity(buffer: *[]QuadVertex, needed: u32) ?[]QuadVertex {
    if (needed == 0) return buffer.*;
    const needed_len = @intCast(needed);
    if (buffer.len >= needed_len) return buffer.*;
    const new_buffer = std.heap.c_allocator.realloc(buffer.*, needed_len) catch return null;
    buffer.* = new_buffer;
    return new_buffer;
}

fn appendRectVertices(surface: render.PixelSize, vertices: []QuadVertex, count: *u32, x: i32, y: i32, width: u16, height: u16, color: render.Rgba8) bool {
    const clipped = clip_rect.clipRectTopOrigin(surface, x, y, width, height) orelse return false;
    if (@intCast(count.* + 4) > vertices.len) return false;
    appendQuad(vertices, count, clipped, color, 0, 0, 0, 0);
    return true;
}

fn appendTexturedGlyphVertices(vertices: []QuadVertex, count: *u32, glyph: TexturedGlyph) void {
    if (@intCast(count.* + 4) > vertices.len) return;
    appendQuad(vertices, count, glyph.clipped, glyph.color, glyph.tex_u0, glyph.tex_v0, glyph.tex_u1, glyph.tex_v1);
}

fn appendQuad(vertices: []QuadVertex, count: *u32, clipped: clip_rect.ClipRect, color: render.Rgba8, tex_u0: f32, tex_v0: f32, tex_u1: f32, tex_v1: f32) void {
    const base = @intCast(count.*);
    const x0: f32 = @floatFromInt(clipped.x);
    const y0: f32 = @floatFromInt(clipped.y);
    const x1: f32 = @floatFromInt(clipped.x + clipped.w);
    const y1: f32 = @floatFromInt(clipped.y + clipped.h);
    vertices[base + 0] = .{ .x = x0, .y = y0, .u = tex_u0, .v = tex_v0, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[base + 1] = .{ .x = x1, .y = y0, .u = tex_u1, .v = tex_v0, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[base + 2] = .{ .x = x1, .y = y1, .u = tex_u1, .v = tex_v1, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    vertices[base + 3] = .{ .x = x0, .y = y1, .u = tex_u0, .v = tex_v1, .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    count.* += 4;
}

fn drawSolidVertices(vertices: []const QuadVertex) void {
    if (vertices.len == 0) return;
    c.glDisable(c.GL_TEXTURE_2D);
    drawVertexArray(vertices, false);
}

fn drawTexturedVertices(vertices: []const QuadVertex) void {
    if (vertices.len == 0) return;
    c.glEnable(c.GL_TEXTURE_2D);
    drawVertexArray(vertices, true);
}

fn drawTexturedGlyphShader(self: anytype, glyph: TexturedGlyph) void {
    if (self.draw_pass.text_shader_pos_loc < 0 or self.draw_pass.text_shader_uv_loc < 0) return;
    const x0: f32 = @floatFromInt(glyph.clipped.x);
    const y0: f32 = @floatFromInt(glyph.clipped.y);
    const x1: f32 = @floatFromInt(glyph.clipped.x + glyph.clipped.w);
    const y1: f32 = @floatFromInt(glyph.clipped.y + glyph.clipped.h);
    const vertices = [_]TexturedVertex{
        .{ .x = x0, .y = y0, .u = glyph.tex_u0, .v = glyph.tex_v0 },
        .{ .x = x1, .y = y0, .u = glyph.tex_u1, .v = glyph.tex_v0 },
        .{ .x = x1, .y = y1, .u = glyph.tex_u1, .v = glyph.tex_v1 },
        .{ .x = x0, .y = y1, .u = glyph.tex_u0, .v = glyph.tex_v1 },
    };
    const stride: c.GLsizei = @intCast(@sizeOf(TexturedVertex));
    c.glEnableVertexAttribArray(@intCast(self.draw_pass.text_shader_pos_loc));
    c.glEnableVertexAttribArray(@intCast(self.draw_pass.text_shader_uv_loc));
    defer {
        c.glDisableVertexAttribArray(@intCast(self.draw_pass.text_shader_uv_loc));
        c.glDisableVertexAttribArray(@intCast(self.draw_pass.text_shader_pos_loc));
    }
    c.glVertexAttribPointer(@intCast(self.draw_pass.text_shader_pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, stride, &vertices[0].x);
    c.glVertexAttribPointer(@intCast(self.draw_pass.text_shader_uv_loc), 2, c.GL_FLOAT, c.GL_FALSE, stride, &vertices[0].u);
    c.glDrawArrays(c.GL_QUADS, 0, 4);
}

fn drawVertexArray(vertices: []const QuadVertex, textured: bool) void {
    if (vertices.len == 0) return;
    c.glEnableClientState(c.GL_VERTEX_ARRAY);
    c.glEnableClientState(c.GL_COLOR_ARRAY);
    if (textured) c.glEnableClientState(c.GL_TEXTURE_COORD_ARRAY);
    defer {
        if (textured) c.glDisableClientState(c.GL_TEXTURE_COORD_ARRAY);
        c.glDisableClientState(c.GL_COLOR_ARRAY);
        c.glDisableClientState(c.GL_VERTEX_ARRAY);
    }
    const stride: c.GLsizei = @intCast(@sizeOf(QuadVertex));
    c.glVertexPointer(2, c.GL_FLOAT, stride, &vertices[0].x);
    c.glColorPointer(4, c.GL_UNSIGNED_BYTE, stride, &vertices[0].r);
    if (textured) c.glTexCoordPointer(2, c.GL_FLOAT, stride, &vertices[0].u);
    c.glDrawArrays(c.GL_QUADS, 0, @intCast(vertices.len));
}

fn drawRect(surface: render.PixelSize, x: i32, y: i32, width: u16, height: u16, color: render.Rgba8) void {
    const clipped = clip_rect.clipRectTopOrigin(surface, x, y, width, height) orelse return;
    c.glDisable(c.GL_TEXTURE_2D);
    c.glColor4ub(color.r, color.g, color.b, color.a);
    c.glBegin(c.GL_QUADS);
    c.glVertex2f(@floatFromInt(clipped.x), @floatFromInt(clipped.y));
    c.glVertex2f(@floatFromInt(clipped.x + clipped.w), @floatFromInt(clipped.y));
    c.glVertex2f(@floatFromInt(clipped.x + clipped.w), @floatFromInt(clipped.y + clipped.h));
    c.glVertex2f(@floatFromInt(clipped.x), @floatFromInt(clipped.y + clipped.h));
    c.glEnd();
}

fn prepareTexturedSceneSprite(self: anytype, surface: render.PixelSize, draw: render.TextSpriteDraw) ?TexturedGlyph {
    if (self.draw_pass.atlas_texture == 0 or self.atlas_pixels.len == 0) return null;
    const slot = draw.sprite.slot;
    const slot_idx = @intCast(slot);
    if (slot_idx >= self.atlas_slot_has_alpha.len or !self.atlas_slot_has_alpha[slot_idx]) return null;
    const slot_index = slot_idx * self.atlas_slot_stride;
    if (slot_index + self.atlas_slot_stride > self.atlas_pixels.len) return null;
    if (slot_idx >= self.atlas_slot_draw_x.len or slot_idx >= self.atlas_slot_draw_y.len or slot_idx >= self.atlas_slot_draw_w.len or slot_idx >= self.atlas_slot_draw_h.len) return null;
    const draw_x = self.atlas_slot_draw_x[slot_idx];
    const draw_y = self.atlas_slot_draw_y[slot_idx];
    const gw = @min(@min(self.atlas_slot_draw_w[slot_idx], self.atlas_cell_w -| draw_x), if (slot_idx < self.atlas_slot_width.len) self.atlas_slot_width[slot_idx] -| draw_x else self.atlas_cell_w -| draw_x);
    const gh = @min(@min(self.atlas_slot_draw_h[slot_idx], self.atlas_cell_h -| draw_y), if (slot_idx < self.atlas_slot_height.len) self.atlas_slot_height[slot_idx] -| draw_y else self.atlas_cell_h -| draw_y);
    if (gw == 0 or gh == 0) return null;
    const dest_x = draw.x_px + @as(i32, @intCast(draw_x));
    const dest_y = draw.y_px + @as(i32, @intCast(draw_y));
    const clipped = clip_rect.clipRectTopOrigin(surface, dest_x, dest_y, gw, gh) orelse return null;
    const cols: u32 = @intCast(@min(self.capabilities().max_atlas_slots, @TypeOf(self.*).AtlasTexCols));
    const slot_x = (slot % cols) * @as(u32, self.atlas_cell_w);
    const slot_y = (slot / cols) * @as(u32, self.atlas_cell_h);
    const clip_dx: u32 = @intCast(@max(clipped.x - dest_x, 0));
    const clip_dy: u32 = @intCast(@max(clipped.y - dest_y, 0));
    return .{
        .clipped = clipped,
        .color = draw.color,
        .tex_u0 = @as(f32, @floatFromInt(slot_x + draw_x + clip_dx)) / @as(f32, @floatFromInt(self.draw_pass.atlas_tex_width)),
        .tex_v0 = @as(f32, @floatFromInt(slot_y + draw_y + clip_dy)) / @as(f32, @floatFromInt(self.draw_pass.atlas_tex_height)),
        .tex_u1 = @as(f32, @floatFromInt(slot_x + draw_x + clip_dx + @as(u32, @intCast(clipped.w)))) / @as(f32, @floatFromInt(self.draw_pass.atlas_tex_width)),
        .tex_v1 = @as(f32, @floatFromInt(slot_y + draw_y + clip_dy + @as(u32, @intCast(clipped.h)))) / @as(f32, @floatFromInt(self.draw_pass.atlas_tex_height)),
    };
}

fn ensureTextShader(self: anytype) bool {
    if (self.draw_pass.text_shader_program != 0) return true;
    if (!hasCurrentContext()) return false;
    const vertex_src =
        \\#version 120
        \\attribute vec2 a_pos;
        \\attribute vec2 a_uv;
        \\varying vec2 v_uv;
        \\void main() {
        \\    v_uv = a_uv;
        \\    gl_Position = gl_ModelViewProjectionMatrix * vec4(a_pos, 0.0, 1.0);
        \\}
    ;
    const fragment_src =
        \\#version 120
        \\uniform sampler2D u_atlas;
        \\uniform vec4 u_color;
        \\varying vec2 v_uv;
        \\void main() {
        \\    float alpha = texture2D(u_atlas, v_uv).a;
        \\    gl_FragColor = vec4(u_color.rgb, u_color.a * alpha);
        \\}
    ;
    const vert = compileShader(c.GL_VERTEX_SHADER, vertex_src) orelse return false;
    defer c.glDeleteShader(vert);
    const frag = compileShader(c.GL_FRAGMENT_SHADER, fragment_src) orelse return false;
    defer c.glDeleteShader(frag);
    const program = c.glCreateProgram();
    if (program == 0) return false;
    c.glAttachShader(program, vert);
    c.glAttachShader(program, frag);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        c.glDeleteProgram(program);
        return false;
    }
    self.draw_pass.text_shader_program = program;
    self.draw_pass.text_shader_pos_loc = c.glGetAttribLocation(program, "a_pos");
    self.draw_pass.text_shader_uv_loc = c.glGetAttribLocation(program, "a_uv");
    self.draw_pass.text_shader_color_loc = c.glGetUniformLocation(program, "u_color");
    self.draw_pass.text_shader_sampler_loc = c.glGetUniformLocation(program, "u_atlas");
    return self.draw_pass.text_shader_pos_loc >= 0 and self.draw_pass.text_shader_uv_loc >= 0;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) ?u32 {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return null;
    var ptr: [*c]const u8 = source.ptr;
    c.glShaderSource(shader, 1, &ptr, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        c.glDeleteShader(shader);
        return null;
    }
    return shader;
}

fn emitTexturedGlyph(glyph: TexturedGlyph) void {
    c.glTexCoord2f(glyph.tex_u0, glyph.tex_v0);
    c.glVertex2f(@floatFromInt(glyph.clipped.x), @floatFromInt(glyph.clipped.y));
    c.glTexCoord2f(glyph.tex_u1, glyph.tex_v0);
    c.glVertex2f(@floatFromInt(glyph.clipped.x + glyph.clipped.w), @floatFromInt(glyph.clipped.y));
    c.glTexCoord2f(glyph.tex_u1, glyph.tex_v1);
    c.glVertex2f(@floatFromInt(glyph.clipped.x + glyph.clipped.w), @floatFromInt(glyph.clipped.y + glyph.clipped.h));
    c.glTexCoord2f(glyph.tex_u0, glyph.tex_v1);
    c.glVertex2f(@floatFromInt(glyph.clipped.x), @floatFromInt(glyph.clipped.y + glyph.clipped.h));
}

fn ensureOwnedTargetTexture(self: anytype) !void {
    if (self.target_texture != null) return;
    if (!hasCurrentContext() and !builtin.is_test) return error.NoContext;
    var texture: u32 = 0;
    c.glGenTextures(1, @ptrCast(&texture));
    if (texture == 0) return error.TargetTextureUnset;
    self.target_texture = texture;
    self.owns_target_texture = true;
    self.target_content_valid = false;
    self.surface_epoch +%= 1;
    resizeOwnedTargetTexture(self);
}

fn ensureScrollScratchTexture(self: anytype, surface_px: render.PixelSize) !void {
    if (self.draw_pass.scroll_scratch_texture == 0) {
        c.glGenTextures(1, @ptrCast(&self.draw_pass.scroll_scratch_texture));
        if (self.draw_pass.scroll_scratch_texture == 0) return error.TargetTextureUnset;
    }
    if (self.draw_pass.scroll_scratch_width == surface_px.width and self.draw_pass.scroll_scratch_height == surface_px.height) return;
    self.draw_pass.scroll_scratch_width = surface_px.width;
    self.draw_pass.scroll_scratch_height = surface_px.height;
    c.glBindTexture(c.GL_TEXTURE_2D, self.draw_pass.scroll_scratch_texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        @as(c_int, @intCast(@max(surface_px.width, 1))),
        @as(c_int, @intCast(@max(surface_px.height, 1))),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}

fn freeOwnedSlice(comptime T: type, buffer: *[]T) void {
    if (buffer.*.len == 0) return;
    std.heap.c_allocator.free(buffer.*);
    buffer.* = &.{};
}
