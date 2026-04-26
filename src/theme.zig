//! Responsibility: define shared render themes.
//! Ownership: render-core planning policy.
//! Reason: keep color defaults explicit and reusable across frame conversion.

const types = @import("types.zig");

pub const linux_mvp_theme = types.FrameTheme{
    .default_fg = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .default_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .cursor_color = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
    .ansi16 = .{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 170, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 170, .b = 0, .a = 255 },
        .{ .r = 170, .g = 85, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 170, .a = 255 },
        .{ .r = 170, .g = 0, .b = 170, .a = 255 },
        .{ .r = 0, .g = 170, .b = 170, .a = 255 },
        .{ .r = 170, .g = 170, .b = 170, .a = 255 },
        .{ .r = 85, .g = 85, .b = 85, .a = 255 },
        .{ .r = 255, .g = 85, .b = 85, .a = 255 },
        .{ .r = 85, .g = 255, .b = 85, .a = 255 },
        .{ .r = 255, .g = 255, .b = 85, .a = 255 },
        .{ .r = 85, .g = 85, .b = 255, .a = 255 },
        .{ .r = 255, .g = 85, .b = 255, .a = 255 },
        .{ .r = 85, .g = 255, .b = 255, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    },
};
