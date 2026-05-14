//! Responsibility: prove the render runtime owner chain.
//! Ownership: retained publication, queue, geometry, and metrics behavior.
//! Reason: keep runtime proof focused on owner behavior only.

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

    var failed = std.atomic.Value(bool).init(false);
    const resize_thread = try std.Thread.spawn(.{}, RendererStress.resize, .{ &renderer, &failed });
    const prepare_thread = try std.Thread.spawn(.{}, RendererStress.prepare, .{ &renderer, frame, &failed });
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

const RendererStress = struct {
    fn resize(renderer: *Renderer, failed: *std.atomic.Value(bool)) void {
        _ = failed;
        var size: u16 = 8;
        while (size < 64) : (size += 1) renderer.setFontSizePx(size);
    }

    fn prepare(renderer: *Renderer, frame: Render.SurfaceFrameData, failed: *std.atomic.Value(bool)) void {
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            var prepared = renderer.prepareFrame(
                std.heap.c_allocator,
                frame,
                .{ .width = 64, .height = 32 },
                .{ .width = 8, .height = 16 },
            ) catch {
                failed.store(true, .release);
                return;
            };
            prepared.frame.deinit();
        }
    }
};
