
const std = @import("std");

test {
    std.testing.refAllDecls(@import("render.zig"));
    std.testing.refAllDecls(@import("renderer.zig"));
}
