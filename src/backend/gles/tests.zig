const std = @import("std");
const backend_mod = @import("backend.zig");
const render_core = @import("../../render_core.zig").RenderCore;

const Backend = backend_mod.Backend;

test "gles backend analyzes text cells through provider-backed engine" {
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

test "gles backend uploads text analysis raster outputs into atlas memory" {
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
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expect(backend.atlas_pixels.len > 0);
    try std.testing.expect(slot_idx < backend.atlas_slot_width.len);
    try std.testing.expectEqual(@as(u16, 8), backend.atlas_slot_width[slot_idx]);
}

test "gles backend text analysis reuses retained scene atlas for unchanged glyphs" {
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

test "gles backend renderFrameState uses text scene renderer" {
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

test "backend resize updates config dimensions" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 320, .height = 240 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    try backend.resize(.{ .width = 1920, .height = 1080 }, .{ .width = 12, .height = 24 });
    try std.testing.expectEqual(@as(u16, 1920), backend.config.surface_px.width);
    try std.testing.expectEqual(@as(u16, 24), backend.config.cell_px.height);
}

test "gles backend reanalyzes after atlas storage grows" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const first_cells = [_]render_core.SurfaceCell{.{ .codepoint = 'A' }};
    const first_state = .{
        .grid = .{ .cells = &first_cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var faces: [4]render_core.Text.FontSession.FontFaceRecord = undefined;
    const first = try backend.renderFrameStateTextScene(std.testing.allocator, first_state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 }, &faces);
    try std.testing.expectEqual(@as(usize, 1), first.raster_uploads_committed);

    const second_cells = [_]render_core.SurfaceCell{
        .{ .codepoint = 'A' },
        .{ .codepoint = 0x4f60 },
        .{ .codepoint = 0, .flags = .{ .continuation = true } },
    };
    const second_state = .{
        .grid = .{ .cells = &second_cells, .cols = 3, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render_core.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    const second = try backend.renderFrameStateTextScene(std.testing.allocator, second_state, .{ .width = 24, .height = 16 }, .{ .width = 24, .height = 16 }, &faces);
    try std.testing.expect(backend.atlas_cell_w > 8);
    try std.testing.expectEqual(@as(usize, 2), second.raster_uploads_committed);
}
