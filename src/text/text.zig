
pub const TextFramePreparer = @import("frame_preparer.zig").TextFramePreparer;
pub const PrepareOptions = @import("frame_preparer.zig").PrepareOptions;
pub const PrepareTimings = @import("frame_preparer.zig").PrepareTimings;
pub const OwnedPreparedTextFrame = @import("frame_preparer.zig").OwnedPreparedTextFrame;
/// Font session/group vocabulary.
pub const FontSession = @import("font/session.zig");
pub const FontResolver = @import("font/resolver.zig");
/// Cell text and grapheme cluster extraction.
pub const Cluster = @import("shape/cluster.zig");
/// HarfBuzz run-shaping boundary and shaper contract surface.
pub const ShapeRun = @import("shape/run.zig");
/// Shape-output to terminal-cell grouping policy.
pub const Grouping = @import("shape/grouping.zig");
/// Rendered sprite cache identity.
pub const SpriteKey = @import("raster/key.zig");
/// Glyph-group rasterization contracts.
pub const Rasterizer = @import("raster/rasterizer.zig");
/// Renderer-neutral text scene vocabulary and scene-build entrypoints.
pub const Scene = @import("scene.zig");
pub const AtlasCache = @import("raster/cache.zig");
/// Explicit symbol/icon route classification.
pub const SymbolMap = @import("classify/symbol_map.zig");
/// Locked normal-vs-complex lane classifier.
pub const Lane = @import("classify/lane.zig");
/// Unified provider boundary for FT/HB integrations.
pub const Provider = @import("font/provider.zig");
/// FreeType/HarfBuzz callback source for surface-session text providers.
pub const FtHbProvider = @import("font/ft_hb/provider.zig");
/// Shared atlas placement math.
pub const Atlas = @import("raster/atlas.zig");
/// Shared shaping policy.
pub const Shaping = @import("classify/symbol.zig");
/// Shared fallback raster policy.
pub const Fallback = @import("raster/fallback.zig");
/// Shared special-glyph classification.
pub const SpecialGlyphs = @import("classify/special_glyphs.zig");

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
    _ = Lane;
    _ = Provider;
    _ = FtHbProvider;
    _ = Atlas;
    _ = Shaping;
    _ = Fallback;
    _ = SpecialGlyphs;
}
