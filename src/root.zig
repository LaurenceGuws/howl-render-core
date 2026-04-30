//! Responsibility: expose the render-core package public surface.
//! Ownership: root API export boundary.
//! Reason: keep one primary host-facing object.

pub const RenderCore = @import("render_core.zig").RenderCore;
pub const ascii8x8 = @import("ascii8x8.zig").ascii8x8;
pub const text_stack_atlas = @import("text_stack/atlas.zig");
pub const text_stack_shaping = @import("text_stack/shaping.zig");
pub const text_stack_fallback = @import("text_stack/fallback.zig");
pub const text_stack_system_fallback = @import("text_stack/system_fallback.zig");
pub const text_stack_special_glyphs = @import("text_stack/special_glyphs.zig");
