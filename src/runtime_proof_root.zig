//! Responsibility: root the repo-local runtime proof under src/.
//! Ownership: repo-local proof wiring only.
//! Reason: let proof files import true owners directly without proving the package root shape.

test {
    _ = @import("test/runtime_proof.zig");
}
