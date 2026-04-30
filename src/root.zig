//! Responsibility: expose the render-core package public surface.
//! Ownership: root API export boundary.
//! Reason: keep one primary host-facing object.

pub const RenderCore = @import("render_core.zig").RenderCore;
