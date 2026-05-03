//! Responsibility: own the public text-stack support surface.
//! Ownership: render-core text shaping/raster support boundary.
//! Reason: keep root exports boring while text-stack units stay grouped.

/// Canonical public text-stack support surface.
pub const TextStack = struct {
    /// Shared atlas math helpers.
    pub const Atlas = @import("text_stack/atlas.zig");
    /// Shared shaping helpers.
    pub const Shaping = @import("text_stack/shaping.zig");
    /// Shared fallback raster helpers.
    pub const Fallback = @import("text_stack/fallback.zig");
    /// Shared special-glyph classification helpers.
    pub const SpecialGlyphs = @import("text_stack/special_glyphs.zig");
};
