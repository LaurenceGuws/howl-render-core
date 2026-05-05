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

test "sprite key changes by face" {
    const a = hashGlyphSequence(.{ .value = 1 }, &.{}, 1);
    const b = hashGlyphSequence(.{ .value = 2 }, &.{}, 1);
    try std.testing.expect(a.value != b.value);
}
