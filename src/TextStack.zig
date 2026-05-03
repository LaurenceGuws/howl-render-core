//! Responsibility: own the public text-stack support surface.
//! Ownership: render-core text shaping/raster support boundary.
//! Reason: keep root exports boring while leaf modules stay grouped.

pub const TextStack = struct {
    pub const Atlas = @import("text_stack/atlas.zig");
    pub const Shaping = @import("text_stack/shaping.zig");
    pub const Fallback = @import("text_stack/fallback.zig");
    pub const SpecialGlyphs = @import("text_stack/special_glyphs.zig");
};
