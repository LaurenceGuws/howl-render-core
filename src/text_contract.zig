//! Responsibility: deterministic text pipeline contract types.
//! Ownership: render-core text API boundary.
//! Reason: keep shaping/fallback/metrics vocabulary stable across render variants.

const std = @import("std");
pub const Rgba8 = @import("rgba.zig").Rgba8;

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

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
    strikethrough_pos_px: f32,
    strikethrough_thickness_px: f32,
};

pub const CellMetrics = struct {
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
    box_thickness_px: u16 = 0,
};

pub const GridMetrics = struct {
    cols: u16,
    rows: u16 = 1,
};

pub const FontFaceId = extern struct {
    value: u32,
};

pub const CellTextId = extern struct {
    value: u32,
};

pub const SpriteKey = extern struct {
    value: u64,
};

pub const CellText = struct {
    id: CellTextId,
    first_cp: u32,
    codepoints: []const u32,
};

pub const LineTextCache = struct {
    texts: []const CellText = &.{},
};

pub const RenderableCell = struct {
    text_id: CellTextId,
    first_cell: u32,
    cell_span: u8,
    style: FontStyle,
    presentation: TextPresentation,
    fg: Rgba8,
    bg: Rgba8,
    underline_color: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    underline_style: UnderlineStyle = .straight,
    underline: bool = false,
    strikethrough: bool = false,
    continuation: bool = false,
};

pub const CellCluster = struct {
    text_id: CellTextId,
    first_cell: u32,
    cell_span: u8,
    first_cp: u32,
    style: FontStyle,
    presentation: TextPresentation,
};

pub const RunFont = struct {
    face_id: FontFaceId,
    style: FontStyle,
    presentation: TextPresentation,
    scale: u8 = 1,
    subscale_n: u8 = 0,
    subscale_d: u8 = 0,
    multicell_y: u8 = 0,
    alignment: u8 = 0,
};

pub const TextRun = struct {
    cluster_start: u32,
    cluster_count: u32,
    font: RunFont,
};

pub const ResolvedRun = struct {
    run: TextRun,
    features_id: u32 = 0,
};

pub const GlyphInstance = struct {
    face_id: FontFaceId,
    glyph_id: u32,
    cluster_index: u32,
    x_offset_px: f32 = 0,
    y_offset_px: f32 = 0,
    x_advance_px: f32 = 0,
};

pub const GlyphPlacement = struct {
    x_offset_px: f32 = 0,
    y_offset_px: f32 = 0,
    advance_px: f32 = 0,
};

pub const GlyphGroupKind = enum(u3) {
    normal,
    ligature,
    icon,
    emoji,
    box_fallback,
    missing,
};

pub const GlyphGroup = struct {
    first_cell: u32,
    first_cp: u32 = 0,
    cell_span: u8,
    glyphs: []const GlyphInstance,
    placement: GlyphPlacement = .{},
    sprite_key: SpriteKey,
    kind: GlyphGroupKind,
};

pub const SpriteColorMode = enum(u2) {
    alpha,
    color,
};

pub const SpritePosition = struct {
    slot: u32,
    key: SpriteKey,
    rendered: bool = false,
    colored: bool = false,
};

pub const TextSpriteDraw = struct {
    sprite: SpritePosition,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    placement: GlyphPlacement = .{},
    color: Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextBackgroundDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextClearDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextCursorDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: Rgba8,
};

pub const DecorationKind = enum(u3) {
    underline,
    underline_dotted,
    underline_dashed,
    undercurl,
    strikethrough,
};

pub const TextDecorationDraw = struct {
    kind: DecorationKind,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: Rgba8,
    first_cell: u32,
    cell_span: u8,
};

/// Identifies which shared raster path should produce a sprite mask.
pub const SpriteRasterKind = enum(u2) {
    glyph,
    undercurl,
};

/// Metrics for a generated decoration sprite rasterized as an alpha mask.
pub const DecorationSpriteRaster = struct {
    stroke_px: u16 = 1,
    amplitude_px: u16 = 2,
    period_px: u16 = 8,
    y_px: u16 = 0,
};

/// Stroke metrics for generated box drawing and related terminal sprites.
pub const BoxDrawingRasterMetrics = struct {
    light_stroke_px: u16 = 1,
    heavy_stroke_px: u16 = 2,
};

/// Request to rasterize either shaped glyphs or a generated text sprite.
pub const SpriteRasterRequest = struct {
    kind: SpriteRasterKind = .glyph,
    key: SpriteKey,
    group: GlyphGroup,
    decoration: DecorationSpriteRaster = .{},
    box_drawing: BoxDrawingRasterMetrics = .{},
    placement: GlyphPlacement = .{},
    width_px: u16,
    height_px: u16,
    baseline_px: i16 = 0,
    color_mode: SpriteColorMode = .alpha,
};

pub const TextScene = struct {
    cells: []const RenderableCell,
    full_redraw: bool = true,
    scroll_up_px: u16 = 0,
    clear_draws: []const TextClearDraw = &.{},
    background_draws: []const TextBackgroundDraw = &.{},
    sprite_draws: []const TextSpriteDraw,
    decoration_draws: []const TextDecorationDraw = &.{},
    cursor_draws: []const TextCursorDraw = &.{},
    raster_requests: []const SpriteRasterRequest = &.{},
    missing: []const MissingGlyph,
};

pub const SpecialSpriteRoute = enum(u3) {
    blank,
    box,
    block,
    braille,
    powerline,
    legacy_computing,
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
    const text = CellText{ .id = .{ .value = 1 }, .first_cp = 'A', .codepoints = &.{'A'} };
    try std.testing.expectEqual(@as(u32, 'A'), text.codepoints[0]);
}
