const std = @import("std");
const backend_mod = @import("backend.zig");
const render_core = @import("../../render_core.zig").RenderCore;

const Backend = backend_mod.Backend;

test "backend rejects operations after deinit" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    backend.deinit();

    try std.testing.expectError(error.BackendClosed, backend.resize(.{ .width = 800, .height = 600 }, .{ .width = 10, .height = 20 }));
}

test "backend exposes text provider and font session scaffold" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const session = backend.fontSession(&faces);
    try std.testing.expect(provider.face_provider != null);
    try std.testing.expectEqual(@as(u32, backend_mod.test_primary_face_id), session.primary_face.value);
    try std.testing.expectEqual(@as(usize, 1), session.faces.len);
    try std.testing.expectEqual(@as(u16, 8), session.metrics.cell_w_px);
    try std.testing.expectEqual(@as(u16, 16), session.metrics.cell_h_px);
}

test "backend text session metrics respect configured cell size" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 9, .height = 17 },
    });
    defer backend.deinit();
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    const session = backend.fontSession(&faces);
    try std.testing.expectEqual(@as(u16, 9), session.metrics.cell_w_px);
    try std.testing.expectEqual(@as(u16, 17), session.metrics.cell_h_px);
    try std.testing.expect(session.metrics.baseline_px > 0);
    try std.testing.expect(session.metrics.baseline_px <= 17);
}

test "backend text provider shaper returns glyph instances" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const clusters = [_]render_core.CellCluster{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = 'A',
        .style = .regular,
        .presentation = .any,
    }};
    const run = render_core.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = backend_mod.test_primary_face_id }, .style = .regular, .presentation = .any },
    } };
    const text_cache = render_core.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} }} };
    var shaped = try provider.shaper.shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
    try std.testing.expectEqual(@as(u32, backend_mod.test_primary_face_id), shaped.glyphs[0].face_id.value);
}

test "backend text provider rasterizer returns sprite output" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const glyph = render_core.GlyphInstance{
        .face_id = .{ .value = backend_mod.test_primary_face_id },
        .glyph_id = backend_mod.testProviderGlyphId(&backend, .{ .value = backend_mod.test_primary_face_id }, 'A'),
        .cluster_index = 0,
    };
    const group = render_core.GlyphGroup{
        .first_cell = 0,
        .cell_span = 1,
        .glyphs = &.{glyph},
        .sprite_key = .{ .value = 123 },
        .kind = .normal,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render_core.Text.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    try std.testing.expectEqual(@as(u16, 8), out.width_px);
    try std.testing.expectEqual(@as(u16, 16), out.height_px);
    try std.testing.expectEqual(@as(usize, 8 * 16), out.pixels.len);
}

test "backend text provider rasterizer draws box fallback alpha" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var adapter = backend.textProvider();
    const provider = adapter.textProvider();
    const group = render_core.GlyphGroup{
        .first_cell = 0,
        .first_cp = 0x2500,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 2500 },
        .kind = .box_fallback,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render_core.Text.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    var lit: usize = 0;
    for (out.pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit >= 8);
    try std.testing.expect(lit < out.pixels.len);
}

test "backend analyzes text cells through provider-backed engine" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
    };
    var faces: [8]render_core.Text.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, &faces);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 2), analysis.groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
}

test "backend analyzes text cells with scene cursor options" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCellsOptions(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces, .{
        .scene = .{ .cursor = .{ .cell_col = 0, .cell_row = 0, .shape = .beam, .color = white } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.cursor_draws.len);
}

test "backend uploads text analysis raster outputs into atlas memory" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer analysis.deinit();
    const committed = try backend.uploadTextAnalysisRaster(analysis);
    try std.testing.expectEqual(@as(usize, 1), committed);
    const committed_scene = try backend.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    try std.testing.expectEqual(@as(usize, 0), committed_scene);
    try std.testing.expect(backend.atlas_pixels.len > 0);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expect(slot_idx < backend.atlas_slot_has_alpha.len);
    try std.testing.expect(backend.atlas_slot_width[slot_idx] == 8);
}

test "backend text analysis reuses retained scene atlas for unchanged glyphs" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;

    var first = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.raster_plan.outputs.len);

    var second = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.raster_plan.outputs.len);
    try std.testing.expectEqual(first.scene.scene.sprite_draws[0].sprite.slot, second.scene.scene.sprite_draws[0].sprite.slot);
}

test "backend text scene cache treats transparent raster output as cached" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    var outputs = [_]render_core.Text.Rasterizer.RasterSpriteOutput{.{
        .allocator = std.testing.allocator,
        .key = .{ .value = 77 },
        .width_px = 8,
        .height_px = 16,
        .pixels = try std.testing.allocator.alloc(u8, 8 * 16),
    }};
    defer outputs[0].deinit();
    @memset(outputs[0].pixels, 0);

    const draw = render_core.TextSpriteDraw{
        .sprite = .{ .slot = 0, .key = outputs[0].key },
        .x_px = 0,
        .y_px = 0,
        .width_px = 8,
        .height_px = 16,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };
    const scene = render_core.TextScene{
        .cells = &.{},
        .sprite_draws = &.{draw},
        .missing = &.{},
    };

    const first = try backend.uploadTextSceneRaster(scene, &outputs);
    const second = try backend.uploadTextSceneRaster(scene, &outputs);
    try std.testing.expectEqual(@as(usize, 1), first);
    try std.testing.expectEqual(@as(usize, 0), second);
    try std.testing.expect(!backend.atlas_slot_has_alpha[0]);
}

test "backend renders text scene handoff without legacy glyph batch" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black, .underline = true }};
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, &faces);
    defer analysis.deinit();
    const report = try backend.renderTextScene(analysis.scene.scene, analysis.raster_plan.outputs);
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expectEqual(@as(usize, 1), report.raster_uploads_committed);
    try std.testing.expectEqual(analysis.scene.scene.background_draws.len, report.background_draws);
    try std.testing.expectEqual(analysis.scene.scene.sprite_draws.len, report.sprite_draws);
    try std.testing.expectEqual(analysis.scene.scene.decoration_draws.len, report.decoration_draws);
}

test "backend text scene report includes cursor draws" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cursor = render_core.TextCursorDraw{ .x_px = 8, .y_px = 16, .width_px = 2, .height_px = 16, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    const scene = render_core.TextScene{
        .cells = &.{},
        .background_draws = &.{},
        .sprite_draws = &.{},
        .decoration_draws = &.{},
        .cursor_draws = &.{cursor},
        .raster_requests = &.{},
        .missing = &.{},
    };
    const report = try backend.renderTextScene(scene, &.{});
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend renders frame state through opt-in text scene path" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render_core.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    const report = try backend.renderFrameStateTextScene(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, &faces);
    try std.testing.expectEqual(@as(usize, 1), report.sprite_draws);
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend renderFrameState uses text scene renderer" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render_core.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    const report = try backend.renderFrameState(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expectEqual(@as(usize, 1), report.stats.glyphs);
    try std.testing.expect(report.stats.has_cursor);
}

test "backend text scene atlas storage fits multicell sprites" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render_core.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_core.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_core.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
    };
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    var analysis = try backend.analyzeTextCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, &faces);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    _ = try backend.uploadTextSceneRaster(analysis.scene.scene, analysis.raster_plan.outputs);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_cell_w);
    try std.testing.expect(slot_idx < backend.atlas_slot_width.len);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_slot_width[slot_idx]);
}
