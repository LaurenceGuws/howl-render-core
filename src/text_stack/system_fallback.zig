//! Responsibility: system fallback policy stubs for text stack.
//! Ownership: render-core text stack.
//! Reason: reserve clear integration point for host/platform font fallback.

pub const FallbackClass = enum {
    primary,
    symbol,
    emoji,
    system,
};

pub fn classifyCodepoint(codepoint: u21) FallbackClass {
    if ((codepoint >= 0x1F000 and codepoint <= 0x1FAFF) or
        (codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF))
    {
        return .emoji;
    }
    if ((codepoint >= 0x2500 and codepoint <= 0x259F) or
        (codepoint >= 0x2800 and codepoint <= 0x28FF))
    {
        return .symbol;
    }
    return .primary;
}
