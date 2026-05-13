//! Responsibility: aggregate the runtime proof artifact.
//! Ownership: render runtime proof root.
//! Reason: keep runtime proof explicit and separate from package-surface compile checks.

test {
    _ = @import("runtime_proof.zig");
}
