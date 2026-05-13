//! Render namespace wrapper for the howl-render module.

const std = @import("std");
const options = @import("render_options");

pub const Ffi = if (options.c_abi) @import("ffi.zig") else void;

const render = @import("render.zig").Render;
const renderer = @import("renderer.zig");

pub const Render = render;
pub const Renderer = renderer.Renderer;

test {
    std.testing.refAllDecls(@This());
}
