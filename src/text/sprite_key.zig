//! Responsibility: define rendered sprite cache identity helpers.
//! Ownership: render-core text engine.
//! Reason: cache rendered glyph groups by output identity instead of source codepoint.

const std = @import("std");
const contract = @import("../text_contract.zig");

pub fn hashGlyphSequence(face: contract.FontFaceId, glyphs: []const contract.GlyphInstance, cell_span: u8) contract.SpriteKey {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&face.value));
    h.update(std.mem.asBytes(&cell_span));
    for (glyphs) |glyph| {
        h.update(std.mem.asBytes(&glyph.face_id.value));
        h.update(std.mem.asBytes(&glyph.glyph_id));
    }
    return .{ .value = h.final() };
}

/// Returns a cache key for a generated undercurl sprite with fixed metrics.
pub fn hashUndercurl(width_px: u16, height_px: u16, stroke_px: u16, amplitude_px: u16, period_px: u16, y_px: u16) contract.SpriteKey {
    var h = std.hash.Wyhash.init(0x756e646572637572);
    h.update(std.mem.asBytes(&width_px));
    h.update(std.mem.asBytes(&height_px));
    h.update(std.mem.asBytes(&stroke_px));
    h.update(std.mem.asBytes(&amplitude_px));
    h.update(std.mem.asBytes(&period_px));
    h.update(std.mem.asBytes(&y_px));
    return .{ .value = h.final() };
}

test "sprite key changes by face" {
    const a = hashGlyphSequence(.{ .value = 1 }, &.{}, 1);
    const b = hashGlyphSequence(.{ .value = 2 }, &.{}, 1);
    try std.testing.expect(a.value != b.value);
}

test "undercurl sprite key changes by metrics" {
    const a = hashUndercurl(16, 20, 2, 3, 12, 14);
    const b = hashUndercurl(16, 24, 2, 3, 12, 14);
    try std.testing.expect(a.value != b.value);
}
