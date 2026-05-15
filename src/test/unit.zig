
const std = @import("std");
const Render = @import("../render.zig").Render;
const Renderer = @import("../renderer.zig").Renderer;

test "render frame pixel geometry clamps to drawable size" {
    const frame = Render.FramePixels{ .render_width = 0, .render_height = -2, .grid_width = 80, .grid_height = 24 };
    try std.testing.expectEqual(@as(u16, 1), frame.renderWidth());
    try std.testing.expectEqual(@as(u16, 1), frame.renderHeight());
    try std.testing.expectEqual(@as(u16, 80), frame.gridWidth());
    try std.testing.expectEqual(@as(u16, 24), frame.gridHeight());
}

test "renderer root helpers forward deterministically" {
    const grid = Render.deriveGridSize(.{ .width = 80, .height = 48 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);

    const frame_grid = try Render.deriveGridForFrame(
        .{ .width = 800, .height = 600 },
        .{ .width = 640, .height = 320 },
        .{ .width = 8, .height = 16 },
    );
    try std.testing.expectEqual(@as(u16, 80), frame_grid.cols);
    try std.testing.expectEqual(@as(u16, 20), frame_grid.rows);
}

test "renderer serializes font resize against prepare" {
    var renderer = Renderer.init(.{
        .surface_px = .{ .width = 64, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .font_size_px = 16,
    });
    defer renderer.deinit();
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = runtime.syncGeometry(.{
        .render_px = .{ .width = 64, .height = 32 },
        .grid_px = .{ .width = 64, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 4);
    defer snapshot.deinit(std.testing.allocator);
    snapshot.clearDirty();

    var cells = [_]Render.SurfaceCell{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var dirty_rows = [_]bool{ true, true };
    var dirty_cols_start = [_]u16{ 0, 0 };
    var dirty_cols_end = [_]u16{ 3, 3 };
    const frame = Render.SurfaceFrameData{
        .viewport = .{ .cols = 4, .rows = 2 },
        .grid = .{ .cells = cells[0..], .cols = 4, .rows = 2 },
        .cursor = .{},
        .damage = .{
            .full = true,
            .dirty_rows = dirty_rows[0..],
            .dirty_cols_start = dirty_cols_start[0..],
            .dirty_cols_end = dirty_cols_end[0..],
        },
    };
    const source = Render.SourceView{
        .snapshot = &snapshot,
        .cols = 4,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .hover_link_id = 0,
        .hover_underline_style = .straight,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .last_alt_screen = false,
    };

    var failed = std.atomic.Value(bool).init(false);
    const resize_thread = try std.Thread.spawn(.{}, RendererStress.resize, .{ &renderer, &failed });
    const prepare_thread = try std.Thread.spawn(.{}, RendererStress.prepare, .{ &renderer, &runtime, frame, source, &failed });
    resize_thread.join();
    prepare_thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "render runtime owner behavior remains reachable" {
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 3);
    defer snapshot.deinit(std.testing.allocator);
    snapshot.clearDirty();
    for (snapshot.cells.items, 0..) |*cell, idx| cell.codepoint = @intCast('a' + idx);

    const geometry = runtime.syncGeometry(.{
        .render_px = .{ .width = 24, .height = 32 },
        .grid_px = .{ .width = 24, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(geometry.changed);
    try std.testing.expectEqual(@as(u64, 1), geometry.geometry_epoch);

    const source = Render.SourceView{
        .snapshot = &snapshot,
        .cols = 3,
        .rows = 2,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .hover_link_id = 0,
        .hover_underline_style = .straight,
        .snapshot_seq = 1,
        .vt_epoch = 1,
        .last_alt_screen = false,
    };
    const receipt = runtime.acceptSource(source);
    try std.testing.expect(receipt.published);
    try std.testing.expect(receipt.queued);
    const request = runtime.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    _ = runtime.publishPrepared(.{
        .token = request.token,
        .required_base_seq = request.token.damage_base_seq,
        .required_target_epoch = request.known_target_epoch,
    });
    switch (runtime.submit()) {
        .submit => |prepared| runtime.acceptSubmitted(.{
            .token = prepared.token,
            .target_epoch = prepared.required_target_epoch,
            .content_valid = true,
        }),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(runtime.prepare() == null);

    const metrics = runtime.takeMetrics();
    try std.testing.expect(metrics.snapshot_publishes > 0);
    try std.testing.expect(metrics.prepare_requests > 0);
    try std.testing.expect(metrics.prepare_takes > 0);
    try std.testing.expect(metrics.submit_valid > 0);
}

test "render runtime stale retained-base validation stays explicit" {
    const submitted = Render.FramePipeline.SubmittedFrame{
        .token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 7,
        .content_valid = true,
    };
    const stale_base = Render.FramePipeline.PreparedFrame{
        .token = .{ .snapshot_seq = 12, .dirty_epoch = 12, .geometry_epoch = 3, .damage_base_seq = 11, .damage_kind = .partial },
        .required_base_seq = 11,
        .required_target_epoch = 7,
    };
    const stale_target = Render.FramePipeline.PreparedFrame{
        .token = .{ .snapshot_seq = 11, .dirty_epoch = 11, .geometry_epoch = 3, .damage_base_seq = 10, .damage_kind = .partial },
        .required_base_seq = 10,
        .required_target_epoch = 8,
    };

    try std.testing.expectEqual(Render.FramePipeline.SubmitValidation.stale_retained_base, Render.FramePipeline.validatePreparedFrame(stale_base, submitted));
    try std.testing.expectEqual(Render.FramePipeline.SubmitValidation.stale_target, Render.FramePipeline.validatePreparedFrame(stale_target, submitted));
}

test "renderer reuses retained atlas across matching frames" {
    var renderer = Renderer.init(.{ .surface_px = .{ .width = 8, .height = 16 }, .cell_px = .{ .width = 8, .height = 16 }, .font_size_px = 16 });
    defer renderer.deinit();
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = runtime.syncGeometry(.{ .render_px = .{ .width = 8, .height = 16 }, .grid_px = .{ .width = 8, .height = 16 }, .cell_px = .{ .width = 8, .height = 16 } });
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 1, 1);
    defer snapshot.deinit(std.testing.allocator);
    const cells = [_]Render.SurfaceCell{.{ .codepoint = 'A' }};
    const frame = frameData(&cells, 1, 1, true, 0, &[_]bool{}, &[_]u16{}, &[_]u16{});

    const first = try runRendererFrame(&renderer, &runtime, &snapshot, frame, 1, 1, 1);
    try std.testing.expect(first.report.raster_uploads_committed == 1);
    const second = try runRendererFrame(&renderer, &runtime, &snapshot, frame, 1, 1, 2);
    try std.testing.expect(second.report.raster_uploads_committed == 0);
}

test "renderer forces full redraw while target contents are invalid" {
    var renderer = Renderer.init(.{ .surface_px = .{ .width = 16, .height = 32 }, .cell_px = .{ .width = 8, .height = 16 }, .font_size_px = 16 });
    defer renderer.deinit();
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = runtime.syncGeometry(.{ .render_px = .{ .width = 16, .height = 32 }, .grid_px = .{ .width = 16, .height = 32 }, .cell_px = .{ .width = 8, .height = 16 } });
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 1);
    defer snapshot.deinit(std.testing.allocator);
    const cells = [_]Render.SurfaceCell{ .{ .codepoint = 'A' }, .{ .codepoint = 'B' } };
    const dirty_rows = [_]bool{ false, true };
    const dirty_start = [_]u16{ 0, 0 };
    const dirty_end = [_]u16{ 0, 0 };
    const frame = frameData(&cells, 1, 2, false, 1, &dirty_rows, &dirty_start, &dirty_end);

    const submitted = try runRendererFrame(&renderer, &runtime, &snapshot, frame, 1, 2, 1);
    try std.testing.expect(submitted.report.full_redraw);
    try std.testing.expectEqual(@as(u16, 0), submitted.report.scroll_up_px);
}

test "renderer preserves partial scroll damage once retained target is valid" {
    var renderer = Renderer.init(.{ .surface_px = .{ .width = 16, .height = 32 }, .cell_px = .{ .width = 8, .height = 16 }, .font_size_px = 16 });
    defer renderer.deinit();
    try renderer.backend.bindTargetTexture(1);
    var runtime = Render.RenderRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    _ = runtime.syncGeometry(.{ .render_px = .{ .width = 16, .height = 32 }, .grid_px = .{ .width = 16, .height = 32 }, .cell_px = .{ .width = 8, .height = 16 } });
    var snapshot = try Render.FrameSnapshot.init(std.testing.allocator, 2, 1);
    defer snapshot.deinit(std.testing.allocator);
    const cells = [_]Render.SurfaceCell{ .{ .codepoint = 'A' }, .{ .codepoint = 'B' } };
    const full_frame = frameData(&cells, 1, 2, true, 0, &[_]bool{}, &[_]u16{}, &[_]u16{});
    _ = try runRendererFrame(&renderer, &runtime, &snapshot, full_frame, 1, 2, 1);

    const dirty_rows = [_]bool{ false, true };
    const dirty_start = [_]u16{ 0, 0 };
    const dirty_end = [_]u16{ 0, 0 };
    const scroll_frame = frameData(&cells, 1, 2, false, 1, &dirty_rows, &dirty_start, &dirty_end);
    const submitted = try runRendererFrame(&renderer, &runtime, &snapshot, scroll_frame, 1, 2, 2);
    try std.testing.expect(!submitted.report.full_redraw);
    try std.testing.expectEqual(@as(u16, 16), submitted.report.scroll_up_px);
}

const RendererStress = struct {
    fn resize(renderer: *Renderer, failed: *std.atomic.Value(bool)) void {
        _ = failed;
        var size: u16 = 8;
        while (size < 64) : (size += 1) renderer.setFontSizePx(size);
    }

    fn prepare(renderer: *Renderer, runtime: *Render.RenderRuntime, frame: Render.SurfaceFrameData, source_template: Render.SourceView, failed: *std.atomic.Value(bool)) void {
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            var source = source_template;
            source.snapshot_seq = @intCast(idx + 1);
            source.vt_epoch = @intCast(idx + 1);
            _ = runtime.acceptSource(source);
            const prepared = renderer.prepareFrame(std.heap.c_allocator, runtime, frame) catch {
                failed.store(true, .release);
                return;
            };
            if (prepared != .prepared) {
                failed.store(true, .release);
                return;
            }
            _ = renderer.submitFrame(runtime) catch {
                failed.store(true, .release);
                return;
            };
        }
    }
};

fn runRendererFrame(
    renderer: *Renderer,
    runtime: *Render.RenderRuntime,
    snapshot: *Render.FrameSnapshot,
    frame: Render.SurfaceFrameData,
    cols: u16,
    rows: u16,
    seq: u64,
) !Renderer.Submitted {
    const source = Render.SourceView{
        .snapshot = snapshot,
        .cols = cols,
        .rows = rows,
        .scrollback_count = 0,
        .scrollback_offset = 0,
        .focused = true,
        .hover_link_id = 0,
        .hover_underline_style = .straight,
        .snapshot_seq = seq,
        .vt_epoch = seq,
        .last_alt_screen = false,
    };
    _ = runtime.acceptSource(source);
    if (try renderer.prepareFrame(std.testing.allocator, runtime, frame) != .prepared) return error.TestUnexpectedResult;
    return switch (try renderer.submitFrame(runtime)) {
        .rendered => |submitted| submitted,
        else => error.TestUnexpectedResult,
    };
}

fn frameData(
    cells: []const Render.SurfaceCell,
    cols: u16,
    rows: u16,
    full: bool,
    scroll_up_rows: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
) Render.SurfaceFrameData {
    return .{
        .viewport = .{ .cols = cols, .rows = rows },
        .grid = .{ .cells = cells, .cols = cols, .rows = rows },
        .cursor = .{},
        .damage = .{
            .full = full,
            .scroll_up_rows = scroll_up_rows,
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
        },
    };
}
