//! Responsibility: classify configured and built-in symbol routes.
//! Ownership: render-core text engine.
//! Reason: nerd-font and icon rendering must be explicit, not fallback luck.

const contract = @import("../text_contract.zig");
const special_glyphs = @import("special_glyphs.zig");

pub fn builtinRoute(cp: u32) ?contract.SpecialSpriteRoute {
    if (cp == 0 or cp == '\t') return .blank;
    if (cp >= 0x2500 and cp <= 0x257f) return .box;
    if (cp >= 0x2580 and cp <= 0x259f) return .block;
    if (cp >= 0x2800 and cp <= 0x28ff) return .braille;
    if ((cp >= 0xe0a0 and cp <= 0xe0d7) or (cp >= 0xe0b0 and cp <= 0xe0bf)) return .powerline;
    if (special_glyphs.isGeneratedSpecialSupported(cp) and (cp >= 0x1fb00 or cp >= 0x1cd00)) return .legacy_computing;
    return null;
}

pub fn isIconCodepoint(cp: u32) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x1f100 and cp <= 0x1f1ff) or
        (cp >= 0xf0000 and cp <= 0xffffd) or
        (cp >= 0x100000 and cp <= 0x10fffd);
}

test "builtin route classifies box drawing" {
    try @import("std").testing.expectEqual(contract.SpecialSpriteRoute.box, builtinRoute(0x2500).?);
}

test "builtin route classifies octant symbols" {
    try @import("std").testing.expectEqual(contract.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1cd00).?);
    try @import("std").testing.expectEqual(contract.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1fbe6).?);
}

test "builtin route skips unsupported generated legacy symbols" {
    try @import("std").testing.expectEqual(@as(?contract.SpecialSpriteRoute, null), builtinRoute(0x1fb70));
}

test "icon codepoint classification stays explicit" {
    try @import("std").testing.expect(isIconCodepoint(0xf101));
    try @import("std").testing.expect(!isIconCodepoint('A'));
    try @import("std").testing.expectEqual(@as(?contract.SpecialSpriteRoute, null), builtinRoute(0xf101));
}
