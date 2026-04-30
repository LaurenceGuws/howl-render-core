//! Responsibility: special-glyph classification shared across backends.
//! Ownership: render-core text stack.
//! Reason: avoid per-backend drift for symbol/powerline decisions.

pub fn isPowerlineCodepoint(codepoint: u21) bool {
    return (codepoint >= 0xE0B0 and codepoint <= 0xE0D7) or
        (codepoint >= 0xE0A0 and codepoint <= 0xE0A2);
}

pub fn isBoxDrawingCodepoint(codepoint: u21) bool {
    return codepoint >= 0x2500 and codepoint <= 0x259F;
}
