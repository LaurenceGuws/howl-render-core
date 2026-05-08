//! Responsibility: own the public text support surface.
//! Ownership: render-core text shaping/raster support boundary.
//! Reason: keep root exports boring while text units stay grouped.

/// Canonical public text support surface.
/// Mature text-engine orchestration boundary.
pub const Engine = @import("text/engine.zig");
/// Font session/group vocabulary.
pub const FontSession = @import("text/font_session.zig");
/// Backend-independent font resolver vocabulary.
pub const FontResolver = @import("text/font_resolver.zig");
/// Cell text and grapheme cluster helpers.
pub const Cluster = @import("text/cluster.zig");
/// HarfBuzz run-shaping boundary.
pub const ShapeRun = @import("text/shape_run.zig");
/// Shape-output to terminal-cell grouping policy.
pub const Grouping = @import("text/grouping.zig");
/// Rendered sprite identity helpers.
pub const SpriteKey = @import("text/sprite_key.zig");
/// Glyph-group rasterization contracts.
pub const Rasterizer = @import("text/rasterizer.zig");
/// Renderer-neutral text scene vocabulary.
pub const Scene = @import("text/scene.zig");
/// Backend-neutral atlas residency vocabulary.
pub const AtlasCache = @import("text/atlas_cache.zig");
/// Explicit symbol/icon route classification.
pub const SymbolMap = @import("text/symbol_map.zig");
/// Shared font/cell metrics policy.
pub const Metrics = @import("text/metrics.zig");
/// Unified provider boundary for FT/HB integrations.
pub const Provider = @import("text/provider.zig");
/// Backend adapter scaffold for FreeType/HarfBuzz providers.
pub const FtHbProvider = @import("text/ft_hb_provider.zig");
/// Shared atlas math helpers.
pub const Atlas = @import("text/atlas.zig");
/// Shared shaping helpers.
pub const Shaping = @import("text/shaping.zig");
/// Shared fallback raster helpers.
pub const Fallback = @import("text/fallback.zig");
/// Shared special-glyph classification helpers.
pub const SpecialGlyphs = @import("text/special_glyphs.zig");

test "text module surface imports" {
    _ = Engine;
    _ = FontSession;
    _ = FontResolver;
    _ = Cluster;
    _ = ShapeRun;
    _ = Grouping;
    _ = SpriteKey;
    _ = Rasterizer;
    _ = Scene;
    _ = AtlasCache;
    _ = SymbolMap;
    _ = Metrics;
    _ = Provider;
    _ = FtHbProvider;
    _ = Atlas;
    _ = Shaping;
    _ = Fallback;
    _ = SpecialGlyphs;
}
