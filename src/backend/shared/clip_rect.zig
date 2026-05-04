const std = @import("std");
const render_core = @import("../../core_api.zig");

pub const ClipRect = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn clipRect(surface: render_core.PixelSize, x: i32, y: i32, width: u16, height: u16) ?ClipRect {
    if (width == 0 or height == 0) return null;
    const sw: i32 = @intCast(surface.width);
    const sh: i32 = @intCast(surface.height);
    const x0 = std.math.clamp(x, 0, sw);
    const y0 = std.math.clamp(y, 0, sh);
    const x1 = std.math.clamp(x + @as(i32, @intCast(width)), 0, sw);
    const y1 = std.math.clamp(y + @as(i32, @intCast(height)), 0, sh);
    if (x1 <= x0 or y1 <= y0) return null;

    const bottom_y = sh - y1;
    return .{
        .x = @intCast(x0),
        .y = @intCast(bottom_y),
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
    };
}
