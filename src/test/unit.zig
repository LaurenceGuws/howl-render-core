
const std = @import("std");
const Render = @import("../howl_render.zig");
const surface = @import("../frame/surface.zig");

test "render frame pixel geometry clamps to drawable size" {
    const frame = surface.FramePixels{ .render_width = 0, .render_height = -2, .grid_width = 80, .grid_height = 24 };
    try std.testing.expectEqual(@as(u16, 1), frame.renderWidth());
    try std.testing.expectEqual(@as(u16, 1), frame.renderHeight());
    try std.testing.expectEqual(@as(u16, 80), frame.gridWidth());
    try std.testing.expectEqual(@as(u16, 24), frame.gridHeight());
}

test "surface session root helpers forward deterministically" {
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
