//! Responsibility: define render RGBA color payloads.
//! Ownership: render owns shared color vocabulary.
//! Reason: keeps color representation deterministic across surfaces and backends.

pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};
