//! Responsibility: text shaping policy helpers shared by backends.
//! Ownership: render-core text stack.
//! Reason: centralize classification logic used during glyph selection/rasterization.

pub fn isSymbolGlyph(codepoint: u21) bool {
    return (codepoint >= 0xE000 and codepoint <= 0xF8FF) or
        (codepoint >= 0xF0000 and codepoint <= 0xFFFFD) or
        (codepoint >= 0x100000 and codepoint <= 0x10FFFD) or
        (codepoint >= 0x2700 and codepoint <= 0x27BF) or
        (codepoint >= 0x2600 and codepoint <= 0x26FF);
}
