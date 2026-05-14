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

    var ft_hb = backend.textProvider();
    const provider = ft_hb.textProvider();
    try std.testing.expect(provider.face_provider != null);
    try std.testing.expect(provider.glyph_lookup.lookupGlyph(.{ .value = 1 }, 'A', .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 }).glyph_id != 0);
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

test "gles backend draw leaf reports prepared scene counters" {
    var backend = Backend.init(.{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    defer backend.deinit();

    const cursor = render.TextCursorDraw{ .x_px = 8, .y_px = 16, .width_px = 2, .height_px = 16, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    const sprite = render.TextSpriteDraw{
        .sprite = .{ .slot = 0, .key = .{ .value = 1 } },
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
        .background_draws = &.{},
        .sprite_draws = &.{sprite},
        .decoration_draws = &.{},
        .cursor_draws = &.{cursor},
        .raster_requests = &.{},
        .missing = &.{},
    };

    const report = try backend.drawPreparedScene(scene);
    try std.testing.expectEqual(@as(u64, 1), report.pass_index);
    try std.testing.expectEqual(@as(usize, 1), report.sprite_draws);
    try std.testing.expectEqual(@as(usize, 1), report.cursor_draws);
    try std.testing.expectEqual(@as(u16, 0), report.scroll_up_px);
    try std.testing.expectEqual(@as(usize, 0), report.raster_uploads_committed);
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
