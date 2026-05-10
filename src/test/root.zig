//! Responsibility: cover the render-core package surface.
//! Ownership: render-core test target owns public surface compile checks.
//! Reason: keeps package export regressions visible in one test root.

const std = @import("std");
const root = @import("howl_render");

test "renderer package surface remains available" {
    _ = root.Core;
    _ = root.Core.Text;
    _ = root.Core.BackendConfig;
    _ = root.Core.SurfaceFrameData;
    _ = root.Core.ResolveResult;
    _ = root.Renderer;
}

test "renderer root helpers forward deterministically" {
    const grid = root.deriveGridSize(.{ .width = 80, .height = 48 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);

    const frame_grid = try root.deriveGridForFrame(
        .{ .width = 800, .height = 600 },
        .{ .width = 640, .height = 320 },
        .{ .width = 8, .height = 16 },
    );
    try std.testing.expectEqual(@as(u16, 80), frame_grid.cols);
    try std.testing.expectEqual(@as(u16, 20), frame_grid.rows);
}

test "renderer serializes font resize against prepare" {
    var renderer = root.Renderer.init(.{
        .surface_px = .{ .width = 64, .height = 32 },
        .cell_px = .{ .width = 8, .height = 16 },
        .font_size_px = 16,
    });
    defer renderer.deinit();

    var cells = [_]root.Core.SurfaceCell{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var dirty_rows = [_]bool{ true, true };
    var dirty_cols_start = [_]u16{ 0, 0 };
    var dirty_cols_end = [_]u16{ 3, 3 };
    const frame = root.Core.SurfaceFrameData{
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

const RendererStress = struct {
    fn resize(renderer: *root.Renderer, failed: *std.atomic.Value(bool)) void {
        _ = failed;
        var size: u16 = 8;
        while (size < 64) : (size += 1) renderer.setFontSizePx(size);
    }

    fn prepare(renderer: *root.Renderer, frame: root.Core.SurfaceFrameData, failed: *std.atomic.Value(bool)) void {
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
