//! Responsibility: own the public text-stack support surface.
//! Ownership: render-core text shaping/raster support boundary.
//! Reason: keep root exports boring while text-stack units stay grouped.

/// Canonical public text-stack support surface.
pub const TextStack = struct {
    /// Mature text-engine orchestration boundary.
    pub const Engine = @import("text_stack/engine.zig");
    /// Font session/group vocabulary.
    pub const FontSession = @import("text_stack/font_session.zig");
    /// Backend-independent font resolver vocabulary.
    pub const FontResolver = @import("text_stack/font_resolver.zig");
    /// Cell text and grapheme cluster helpers.
    pub const Cluster = @import("text_stack/cluster.zig");
    /// HarfBuzz run-shaping boundary.
    pub const ShapeRun = @import("text_stack/shape_run.zig");
    /// Shape-output to terminal-cell grouping policy.
    pub const Grouping = @import("text_stack/grouping.zig");
    /// Rendered sprite identity helpers.
    pub const SpriteKey = @import("text_stack/sprite_key.zig");
    /// Glyph-group rasterization contracts.
    pub const Rasterizer = @import("text_stack/rasterizer.zig");
    /// Renderer-neutral text scene vocabulary.
    pub const Scene = @import("text_stack/scene.zig");
    /// Backend-neutral atlas residency vocabulary.
    pub const AtlasCache = @import("text_stack/atlas_cache.zig");
    /// Explicit symbol/icon route classification.
    pub const SymbolMap = @import("text_stack/symbol_map.zig");
    /// Shared font/cell metrics policy.
    pub const Metrics = @import("text_stack/metrics.zig");
    /// Unified provider boundary for FT/HB integrations.
    pub const Provider = @import("text_stack/provider.zig");
    /// Backend adapter scaffold for FreeType/HarfBuzz providers.
    pub const FtHbProvider = @import("text_stack/ft_hb_provider.zig");
    /// Shared atlas math helpers.
    pub const Atlas = @import("text_stack/atlas.zig");
    /// Shared shaping helpers.
    pub const Shaping = @import("text_stack/shaping.zig");
    /// Shared fallback raster helpers.
    pub const Fallback = @import("text_stack/fallback.zig");
    /// Shared special-glyph classification helpers.
    pub const SpecialGlyphs = @import("text_stack/special_glyphs.zig");
};

test "text stack module surface imports" {
    _ = TextStack.Engine;
    _ = TextStack.FontSession;
    _ = TextStack.FontResolver;
    _ = TextStack.Cluster;
    _ = TextStack.ShapeRun;
    _ = TextStack.Grouping;
    _ = TextStack.SpriteKey;
    _ = TextStack.Rasterizer;
    _ = TextStack.Scene;
    _ = TextStack.AtlasCache;
    _ = TextStack.SymbolMap;
    _ = TextStack.Metrics;
    _ = TextStack.Provider;
    _ = TextStack.FtHbProvider;
    _ = TextStack.Atlas;
    _ = TextStack.Shaping;
    _ = TextStack.Fallback;
    _ = TextStack.SpecialGlyphs;
}
