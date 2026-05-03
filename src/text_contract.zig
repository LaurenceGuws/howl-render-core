//! Responsibility: deterministic text pipeline contract types.
//! Ownership: render-core text API boundary.
//! Reason: keep shaping/fallback/metrics vocabulary stable across render variants.

const std = @import("std");

pub const BackendCaps = struct {
    has_freetype: bool = false,
    has_harfbuzz: bool = false,
    has_fontconfig: bool = false,
    has_discovery: bool = false,
};

pub const FontStyle = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

pub const TextPresentation = enum(u2) {
    text = 0,
    emoji = 1,
    any = 2,
};

pub const FontMetrics = struct {
    ascent_px: f32,
    descent_px: f32,
    line_gap_px: f32,
    underline_pos_px: f32,
    underline_thickness_px: f32,
};

pub const CellMetrics = struct {
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
};

pub const TextCluster = struct {
    grapheme_utf8: []const u8,
    first_cp: u32,
    presentation: ?TextPresentation = null,
    style: FontStyle = .regular,
    cell_span: u8 = 1,
};

pub const ShapedGlyph = struct {
    glyph_id: u32,
    atlas_key: u64,
    x_offset_px: f32,
    y_offset_px: f32,
    x_advance_px: f32,
    face_id: u32,
};

pub const ShapedRun = struct {
    cluster_start: u32,
    cluster_count: u32,
    glyphs: []const ShapedGlyph,
};

pub const MissingGlyphReason = enum(u3) {
    unresolved_codepoint,
    style_unavailable,
    no_fallback_face,
    shaping_failed,
    raster_failed,
};

pub const MissingGlyph = struct {
    codepoint: u32,
    style: FontStyle,
    presentation: TextPresentation,
    reason: MissingGlyphReason,
};

test "text contract defaults are deterministic" {
    const caps = BackendCaps{};
    try std.testing.expect(!caps.has_freetype);
    try std.testing.expect(!caps.has_harfbuzz);
    const cluster = TextCluster{ .grapheme_utf8 = "a", .first_cp = 97 };
    try std.testing.expectEqual(@as(u8, 1), cluster.cell_span);
}
