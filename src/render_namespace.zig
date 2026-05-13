//! Render namespace wrapper for the howl-render module.

const std = @import("std");
const options = @import("render_options");

pub const c_api = if (options.c_abi) @import("ffi.zig") else void;

const render_mod = @import("render.zig");
const render = render_mod.Render;
const renderer = @import("renderer.zig");

pub const Render = render;
pub const Renderer = renderer.Renderer;

pub const geometry = render_mod.geometry;

test {
    std.testing.refAllDecls(@This());
}
