//! Responsibility: special-glyph classification shared across backends.
//! Ownership: render text pipeline.
//! Reason: avoid per-backend drift for symbol/powerline decisions.

pub fn isPowerlineCodepoint(codepoint: u21) bool {
    return (codepoint >= 0xE0B0 and codepoint <= 0xE0D7) or
        (codepoint >= 0xE0A0 and codepoint <= 0xE0A2);
}

pub fn isBoxDrawingCodepoint(codepoint: u21) bool {
    return codepoint >= 0x2500 and codepoint <= 0x259F;
}

/// Returns true when the shared generated raster path currently implements the codepoint.
pub fn isGeneratedSpecialSupported(codepoint: u32) bool {
    return switch (codepoint) {
        0x2500...0x257f,
        0x2580...0x259f,
        0x2800...0x28ff,
        0xe0b0...0xe0b7,
        0xe0b8...0xe0bf,
        0x1cd00...0x1cde5,
        0x1fbe6,
        0x1fbe7,
        => true,
        0x1fb00...0x1fb13,
        0x1fb14...0x1fb27,
        0x1fb28...0x1fb3b,
        => true,
        else => false,
    };
}
