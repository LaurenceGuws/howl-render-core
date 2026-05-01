//! Responsibility: export the render-core object surface.
//! Ownership: package API boundary.
//! Reason: keep exports boring, stable, and object-first.

/// Canonical render-core package object.
pub const RenderCoreModule = struct {
    /// Primary render-core facade.
    pub const RenderCore = @import("render_core.zig").RenderCore;

    /// Internal text-stack helpers exposed behind one namespace.
    pub const TextStack = struct {
        pub const atlas = @import("text_stack/atlas.zig");
        pub const shaping = @import("text_stack/shaping.zig");
        pub const fallback = @import("text_stack/fallback.zig");
        pub const system_fallback = @import("text_stack/system_fallback.zig");
        pub const special_glyphs = @import("text_stack/special_glyphs.zig");
    };
};
