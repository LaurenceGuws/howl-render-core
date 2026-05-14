//! Responsibility: cover OpenGL backend behavior.
//! Ownership: render OpenGL tests own backend-specific regression checks.
//! Reason: keeps GL coverage close to the backend it validates.

const std = @import("std");
const backend_mod = @import("backend.zig");
const render = @import("../../render.zig").Render;

const Backend = backend_mod.Backend;
const primary_face_id: u32 = 1;

const TestSpine = struct {
    backend: *Backend,
    engine: render.Text.Engine.Engine,
    target_valid: bool = false,

    fn init(backend: *Backend) !TestSpine {
        var ft_hb = backend.textProvider();
        return .{
            .backend = backend,
            .engine = try render.Text.Engine.Engine.initWithProvider(
                std.testing.allocator,
                backend.capabilities().max_atlas_slots,
                ft_hb.textProvider(),
            ),
        };
    }

    fn deinit(self: *TestSpine) void {
        self.engine.deinit();
        self.* = undefined;
    }

    fn analyzeCells(
        self: *TestSpine,
        _: std.mem.Allocator,
        cells: []const render.CellInput,
        grid: render.GridMetrics,
        options: render.Text.Engine.AnalysisOptions,
    ) !render.Text.Engine.OwnedTextAnalysis {
        var faces: [32]render.Text.FontSession.FontFaceRecord = undefined;
        return self.engine.analyzeCellsWithSessionOptions(cells, grid, self.backend.fontSession(&faces, null), options);
    }

    fn prepareState(
        self: *TestSpine,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: render.PixelSize,
        cell_px: render.CellSize,
    ) !render.Text.Engine.OwnedTextAnalysis {
        const rc = render.init(self.backend.config, self.backend.capabilities());
        try self.backend.applyFrameGeometry(surface_px, cell_px);
        var input = try rc.vtStateToTextSceneInput(allocator, state);
        defer input.deinit();
        if (!self.target_valid) {
            self.engine.clearAtlas();
            input.options.scene.damage.full = true;
            input.options.scene.damage.scroll_up_rows = 0;
        }
        var faces: [32]render.Text.FontSession.FontFaceRecord = undefined;
        return self.engine.analyzeCellsWithSessionOptions(input.cells, input.grid, self.backend.fontSession(&faces, null), input.options);
    }

    fn submitPrepared(self: *TestSpine, prepared: *render.Text.Engine.OwnedTextAnalysis) !backend_mod.TextSceneRenderReport {
        const committed = try self.uploadPrepared(prepared);
        var report = try self.backend.drawPreparedScene(prepared.scene.scene);
        report.raster_uploads_committed = committed;
        self.target_valid = report.texture_id != 0;
        return report;
    }

    fn uploadPrepared(self: *TestSpine, prepared: *const render.Text.Engine.OwnedTextAnalysis) !u32 {
        const committed = try self.backend.uploadTextSceneRaster(prepared.scene.scene, prepared.raster_plan.outputs);
        markRenderedOutputs(&self.engine.atlas, prepared.raster_plan.outputs);
        return @intCast(committed);
    }

    fn markRenderedOutputs(atlas: *render.Text.AtlasCache.OwnedAtlasCache, outputs: []const render.Text.Rasterizer.RasterSpriteOutput) void {
        for (outputs) |output| _ = atlas.markRendered(output.key);
    }
};

test "backend rejects operations after deinit" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    backend.deinit();

    try std.testing.expectError(error.BackendClosed, backend.applyFrameGeometry(.{ .width = 800, .height = 600 }, .{ .width = 10, .height = 20 }));
}

test "backend exposes text provider and font session" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var faces: [4]render.Text.FontSession.FontFaceRecord = undefined;
    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    const session = backend.fontSession(&faces, null);
    try std.testing.expect(provider.face_provider != null);
    try std.testing.expectEqual(@as(u32, primary_face_id), session.primary_face.value);
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
    var faces: [4]render.Text.FontSession.FontFaceRecord = undefined;
    const session = backend.fontSession(&faces, null);
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
    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    const clusters = [_]render.CellCluster{.{
        .text_id = .{ .value = 0 },
        .first_cell = 0,
        .cell_span = 1,
        .first_cp = 'A',
        .style = .regular,
        .presentation = .any,
    }};
    const run = render.ResolvedRun{ .run = .{
        .cluster_start = 0,
        .cluster_count = 1,
        .font = .{ .face_id = .{ .value = primary_face_id }, .style = .regular, .presentation = .any },
    } };
    const text_cache = render.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'A', .codepoints = &.{'A'} }} };
    var shaped = try provider.shaper.shapeRun(std.testing.allocator, run, text_cache, &clusters, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
    try std.testing.expectEqual(@as(u32, primary_face_id), shaped.glyphs[0].face_id.value);
}

test "backend text provider rasterizer returns sprite output" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    const metrics = render.CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 };
    const glyph = render.GlyphInstance{
        .face_id = .{ .value = primary_face_id },
        .glyph_id = provider.glyph_lookup.lookupGlyph(.{ .value = primary_face_id }, 'A', metrics).glyph_id,
        .cluster_index = 0,
    };
    const group = render.GlyphGroup{
        .first_cell = 0,
        .cell_span = 1,
        .glyphs = &.{glyph},
        .sprite_key = .{ .value = 123 },
        .kind = .normal,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render.Text.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
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
    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    const group = render.GlyphGroup{
        .first_cell = 0,
        .first_cp = 0x2500,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 2500 },
        .kind = .box_fallback,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render.Text.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    var lit: usize = 0;
    for (out.pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit >= 8);
    try std.testing.expect(lit < out.pixels.len);
}

test "backend text provider rasterizer draws generated braille alpha" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    const group = render.GlyphGroup{
        .first_cell = 0,
        .first_cp = 0x2801,
        .cell_span = 1,
        .glyphs = &.{},
        .sprite_key = .{ .value = 2801 },
        .kind = .box_fallback,
    };
    var out = try provider.rasterizer.rasterize(std.testing.allocator, render.Text.Rasterizer.requestForGroup(group, .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }));
    defer out.deinit();
    var lit: usize = 0;
    for (out.pixels) |alpha| {
        if (alpha != 0) lit += 1;
    }
    try std.testing.expect(lit > 0);
    try std.testing.expect(lit < out.pixels.len / 2);
}

test "backend analyzes text cells through provider-backed engine" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var analysis = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 0), analysis.groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
}

test "backend analyzes text cells with scene cursor options" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var analysis = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, .{
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
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var analysis = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, .{});
    defer analysis.deinit();
    const committed = try spine.uploadPrepared(&analysis);
    try std.testing.expectEqual(@as(u32, 1), committed);
    const committed_scene = try spine.uploadPrepared(&analysis);
    try std.testing.expectEqual(@as(u32, 0), committed_scene);
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

    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black }};
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();

    var first = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.raster_plan.outputs.len);
    _ = try spine.uploadPrepared(&first);

    var second = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, .{});
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

    var outputs = [_]render.Text.Rasterizer.RasterSpriteOutput{.{
        .allocator = std.testing.allocator,
        .key = .{ .value = 77 },
        .width_px = 8,
        .height_px = 16,
        .pixels = try std.testing.allocator.alloc(u8, 8 * 16),
    }};
    defer outputs[0].deinit();
    @memset(outputs[0].pixels, 0);

    const draw = render.TextSpriteDraw{
        .sprite = .{ .slot = 0, .key = outputs[0].key },
        .x_px = 0,
        .y_px = 0,
        .width_px = 8,
        .height_px = 16,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 1,
    };
    const scene = render.TextScene{
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

test "backend stores raster visual bounds separately from logical sprite span" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    var outputs = [_]render.Text.Rasterizer.RasterSpriteOutput{.{
        .allocator = std.testing.allocator,
        .key = .{ .value = 88 },
        .width_px = 16,
        .height_px = 16,
        .pixels = try std.testing.allocator.alloc(u8, 16 * 16),
    }};
    defer outputs[0].deinit();
    @memset(outputs[0].pixels, 0);
    outputs[0].pixels[4 * 16 + 3] = 255;
    outputs[0].pixels[5 * 16 + 6] = 255;

    const draw = render.TextSpriteDraw{
        .sprite = .{ .slot = 0, .key = outputs[0].key },
        .x_px = 0,
        .y_px = 0,
        .width_px = 16,
        .height_px = 16,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .first_cell = 0,
        .cell_span = 2,
    };
    const scene = render.TextScene{ .cells = &.{}, .sprite_draws = &.{draw}, .missing = &.{} };

    _ = try backend.uploadTextSceneRaster(scene, &outputs);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_slot_width[0]);
    try std.testing.expectEqual(@as(u16, 3), backend.atlas_slot_draw_x[0]);
    try std.testing.expectEqual(@as(u16, 4), backend.atlas_slot_draw_y[0]);
    try std.testing.expectEqual(@as(u16, 4), backend.atlas_slot_draw_w[0]);
    try std.testing.expectEqual(@as(u16, 2), backend.atlas_slot_draw_h[0]);
}

test "backend renders prepared text scene" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{.{ .codepoint = 'A', .fg = white, .bg = black, .underline = true }};
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var analysis = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 1, .rows = 1 }, .{});
    defer analysis.deinit();
    const report = try spine.submitPrepared(&analysis);
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
    const cursor = render.TextCursorDraw{ .x_px = 8, .y_px = 16, .width_px = 2, .height_px = 16, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    const scene = render.TextScene{
        .cells = &.{},
        .background_draws = &.{},
        .sprite_draws = &.{},
        .decoration_draws = &.{},
        .cursor_draws = &.{cursor},
        .raster_requests = &.{},
        .missing = &.{},
    };
    const report = try backend.drawPreparedScene(scene);
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend leaf path renders frame state" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var prepared = try spine.prepareState(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer prepared.deinit();
    const report = try spine.submitPrepared(&prepared);
    try std.testing.expectEqual(@as(usize, 1), report.sprite_draws);
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
}

test "backend leaf path prepares and submits text scene separately" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const cells = [_]render.SurfaceCell{.{ .codepoint = 'A' }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var prepared = try spine.prepareState(std.testing.allocator, state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), prepared.scene.scene.sprite_draws.len);
    const report = try spine.submitPrepared(&prepared);
    try std.testing.expectEqual(@as(usize, 1), report.sprite_draws);
}

test "backend forces full redraw while target contents are invalid" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const cells = [_]render.SurfaceCell{ .{ .codepoint = 'A' }, .{ .codepoint = 'B' } };
    const dirty_rows = [_]bool{ false, true };
    const dirty_start = [_]u16{ 0, 0 };
    const dirty_end = [_]u16{ 0, 0 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = false, .scroll_up_rows = 1, .dirty_rows = &dirty_rows, .dirty_cols_start = &dirty_start, .dirty_cols_end = &dirty_end },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var prepared = try spine.prepareState(std.testing.allocator, state, .{ .width = 16, .height = 32 }, .{ .width = 8, .height = 16 });
    defer prepared.deinit();
    const report = try spine.submitPrepared(&prepared);
    try std.testing.expect(report.full_redraw);
    try std.testing.expectEqual(@as(u16, 0), report.scroll_up_px);
}

test "backend preserves partial scroll damage when target contents are valid" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 16, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    spine.target_valid = true;

    const cells = [_]render.SurfaceCell{ .{ .codepoint = 'A' }, .{ .codepoint = 'B' } };
    const dirty_rows = [_]bool{ false, true };
    const dirty_start = [_]u16{ 0, 0 };
    const dirty_end = [_]u16{ 0, 0 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = false, .scroll_up_rows = 1, .dirty_rows = &dirty_rows, .dirty_cols_start = &dirty_start, .dirty_cols_end = &dirty_end },
    };
    var prepared = try spine.prepareState(std.testing.allocator, state, .{ .width = 16, .height = 32 }, .{ .width = 8, .height = 16 });
    defer prepared.deinit();
    const report = try spine.submitPrepared(&prepared);
    try std.testing.expect(!report.full_redraw);
    try std.testing.expectEqual(@as(u16, 16), report.scroll_up_px);
}

test "backend text scene atlas storage fits multicell sprites" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();
    const white = render.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var analysis = try spine.analyzeCells(std.testing.allocator, &cells, .{ .cols = 2, .rows = 1 }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    _ = try spine.uploadPrepared(&analysis);
    const slot = analysis.scene.scene.sprite_draws[0].sprite.slot;
    const slot_idx = @as(usize, slot);
    try std.testing.expect(backend.atlas_cell_w > 8);
    try std.testing.expect(slot_idx < backend.atlas_slot_width.len);
    try std.testing.expectEqual(@as(u16, 16), backend.atlas_slot_width[slot_idx]);
}

test "backend reanalyzes after atlas storage grows" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const first_cells = [_]render.SurfaceCell{.{ .codepoint = 'A' }};
    const first_state = .{
        .grid = .{ .cells = &first_cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var spine = try TestSpine.init(&backend);
    defer spine.deinit();
    var first_prepared = try spine.prepareState(std.testing.allocator, first_state, .{ .width = 8, .height = 16 }, .{ .width = 8, .height = 16 });
    defer first_prepared.deinit();
    const first = try spine.submitPrepared(&first_prepared);
    try std.testing.expectEqual(@as(usize, 1), first.raster_uploads_committed);

    const second_cells = [_]render.SurfaceCell{
        .{ .codepoint = 'A' },
        .{ .codepoint = 0x4f60 },
        .{ .codepoint = 0, .flags = .{ .continuation = true } },
    };
    const second_state = .{
        .grid = .{ .cells = &second_cells, .cols = 3, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = render.SurfaceCursorShape.block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var second_prepared = try spine.prepareState(std.testing.allocator, second_state, .{ .width = 24, .height = 16 }, .{ .width = 24, .height = 16 });
    defer second_prepared.deinit();
    const second = try spine.submitPrepared(&second_prepared);
    try std.testing.expect(backend.atlas_cell_w > 8);
    try std.testing.expectEqual(@as(usize, 2), second.raster_uploads_committed);
}
