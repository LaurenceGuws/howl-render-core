//! Responsibility: classify configured and built-in symbol routes.
//! Ownership: render-core text engine.
//! Reason: nerd-font and icon rendering must be explicit, not fallback luck.

const contract = @import("../text_contract.zig");

pub fn builtinRoute(cp: u32) ?contract.SpecialSpriteRoute {
    if (cp == 0 or cp == '\t') return .blank;
    if (cp >= 0x2500 and cp <= 0x257f) return .box;
    if (cp >= 0x2580 and cp <= 0x259f) return .block;
    if (cp >= 0x2800 and cp <= 0x28ff) return .braille;
    if ((cp >= 0xe0a0 and cp <= 0xe0d7) or (cp >= 0xe0b0 and cp <= 0xe0bf)) return .powerline;
    if (cp >= 0x1fb00 and cp <= 0x1fbae) return .legacy_computing;
    return null;
}

test "builtin route classifies box drawing" {
    try @import("std").testing.expectEqual(contract.SpecialSpriteRoute.box, builtinRoute(0x2500).?);
}
