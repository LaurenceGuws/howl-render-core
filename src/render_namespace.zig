//! Render namespace wrapper for the howl-render-core module.

const std = @import("std");
const options = @import("render_options");

pub const c_api = if (options.c_abi) @import("ffi.zig") else void;

const core_mod = @import("render_core.zig");
const core = core_mod.RenderCore;
const renderer = @import("renderer.zig");

pub const Core = core;
pub const Renderer = renderer.Renderer;

pub const geometry = core_mod.geometry;

test {
    std.testing.refAllDecls(@This());
}
