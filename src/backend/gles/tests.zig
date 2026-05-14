//! Responsibility: cover OpenGL ES backend behavior.
//! Ownership: render GLES tests own backend-specific regression checks.
//! Reason: keeps GLES coverage close to the backend it validates.

const std = @import("std");
const backend_mod = @import("backend.zig");
const render = @import("../../render.zig").Render;

const Backend = backend_mod.Backend;

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

test "gles backend analyzes text cells through provider-backed engine" {
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

test "gles backend uploads text analysis raster outputs into atlas memory" {
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

test "gles backend stores raster visual bounds separately from logical sprite span" {
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

test "gles backend leaf path renders frame state" {
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
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expect(report.sprite_draws == 1);
    try std.testing.expect(report.cursor_draws == 1);
}

test "backend apply frame geometry updates config dimensions" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 320, .height = 240 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    try backend.applyFrameGeometry(.{ .width = 1920, .height = 1080 }, .{ .width = 12, .height = 24 });
    try std.testing.expectEqual(@as(u16, 1920), backend.config.surface_px.width);
    try std.testing.expectEqual(@as(u16, 24), backend.config.cell_px.height);
}

test "gles backend leaf path prepares and submits text scene separately" {
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

test "gles backend forces full redraw while target contents are invalid" {
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

test "gles backend preserves partial scroll damage when target contents are valid" {
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

test "gles backend reanalyzes after atlas storage grows" {
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
