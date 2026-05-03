//! Responsibility: own shared text shaping policy for backend owners.
//! Ownership: render-core text stack.
//! Reason: centralize classification logic used during glyph selection/rasterization.

/// Report whether a codepoint should be treated as a symbol glyph.
pub fn isSymbolGlyph(codepoint: u21) bool {
    return (codepoint >= 0xE000 and codepoint <= 0xF8FF) or
        (codepoint >= 0xF0000 and codepoint <= 0xFFFFD) or
        (codepoint >= 0x100000 and codepoint <= 0x10FFFD) or
        (codepoint >= 0x2700 and codepoint <= 0x27BF) or
        (codepoint >= 0x2600 and codepoint <= 0x26FF);
}
