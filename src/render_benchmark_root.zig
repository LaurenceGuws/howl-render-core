//! Responsibility: root the repo-local render benchmark under src/.
//! Ownership: repo-local benchmark wiring only.
//! Reason: let benchmark code import true owners directly without proving the package root shape.

pub const main = @import("test/render_benchmark.zig").main;
