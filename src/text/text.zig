
pub const TextFramePreparer = @import("frame_preparer.zig").TextFramePreparer;
pub const PrepareOptions = @import("frame_preparer.zig").PrepareOptions;
pub const PrepareTimings = @import("frame_preparer.zig").PrepareTimings;
pub const OwnedPreparedTextFrame = @import("frame_preparer.zig").OwnedPreparedTextFrame;
/// Font session/group vocabulary.
pub const FontSession = @import("font_session.zig");
/// Backend-independent font resolver vocabulary.
pub const FontResolver = @import("font_resolver.zig");
/// Cell text and grapheme cluster extraction.
pub const Cluster = @import("cluster.zig");
/// HarfBuzz run-shaping boundary and shaper contract surface.
pub const ShapeRun = @import("shape_run.zig");
/// Shape-output to terminal-cell grouping policy.
pub const Grouping = @import("grouping.zig");
/// Rendered sprite cache identity.
pub const SpriteKey = @import("sprite_key.zig");
/// Glyph-group rasterization contracts.
pub const Rasterizer = @import("rasterizer.zig");
/// Renderer-neutral text scene vocabulary and scene-build entrypoints.
pub const Scene = @import("scene.zig");
/// Backend-neutral atlas residency vocabulary.
pub const AtlasCache = @import("atlas_cache.zig");
/// Explicit symbol/icon route classification.
pub const SymbolMap = @import("symbol_map.zig");
/// Shared font/cell metrics policy.
pub const Metrics = @import("metrics.zig");
/// Locked normal-vs-complex lane classifier.
pub const Lane = @import("lane.zig");
/// Unified provider boundary for FT/HB integrations.
pub const Provider = @import("provider.zig");
/// FreeType/HarfBuzz callback source for backend-owned providers.
pub const FtHbProvider = @import("ft_hb_provider.zig");
/// Shared atlas placement math.
pub const Atlas = @import("atlas.zig");
/// Shared shaping policy.
pub const Shaping = @import("shaping.zig");
/// Shared fallback raster policy.
pub const Fallback = @import("fallback.zig");
/// Shared special-glyph classification.
pub const SpecialGlyphs = @import("special_glyphs.zig");

test "text module surface imports" {
    _ = TextFramePreparer;
    _ = PrepareOptions;
    _ = PrepareTimings;
    _ = OwnedPreparedTextFrame;
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
    _ = Lane;
    _ = Provider;
    _ = FtHbProvider;
    _ = Atlas;
    _ = Shaping;
    _ = Fallback;
    _ = SpecialGlyphs;
}
