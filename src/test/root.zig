//! Responsibility: cover the render-core package surface.
//! Ownership: render-core test target owns public surface compile checks.
//! Reason: keeps package export regressions visible in one test root.

const std = @import("std");
const root = @import("howl_render");

test "renderer package surface remains available" {
    _ = root.Core;
    _ = root.Backend;
    _ = root.RenderReport;
    _ = root.Core.Text;
    _ = root.Core.BackendConfig;
    _ = root.Core.SurfaceFrameData;
    _ = root.Core.ResolveResult;
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
