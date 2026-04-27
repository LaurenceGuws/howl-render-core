//! Responsibility: validate backend execution inputs against shared contracts.
//! Ownership: render-core backend execution contract helpers.
//! Reason: keep backend implementations thin and consistent.

const types = @import("types.zig");

/// Errors returned when a backend validates a render plan before execution.
pub const ExecutionValidationError = error{
    SurfaceMismatch,
    CellMismatch,
    FillUnsupported,
    GlyphUnsupported,
    AtlasSlotOutOfRange,
};

/// Validate a render plan against backend config and capability declarations.
pub fn validatePlanForBackend(
    config: types.BackendConfig,
    capability: types.BackendCapability,
    plan: types.RenderPlan,
) ExecutionValidationError!void {
    if (plan.surface_px.width != config.surface_px.width or plan.surface_px.height != config.surface_px.height) {
        return error.SurfaceMismatch;
    }
    if (plan.cell_px.width != config.cell_px.width or plan.cell_px.height != config.cell_px.height) {
        return error.CellMismatch;
    }
    if (!capability.supports_fill_rect and plan.fills.len > 0) {
        return error.FillUnsupported;
    }
    if (!capability.supports_glyph_quads and plan.glyphs.len > 0) {
        return error.GlyphUnsupported;
    }
    for (plan.atlas_uploads) |upload| {
        if (upload.slot >= capability.max_atlas_slots) {
            return error.AtlasSlotOutOfRange;
        }
    }
}

/// Summarize command counts in a render plan for backend reporting.
pub fn summarizePlan(plan: types.RenderPlan) types.PlanStats {
    return plan.stats();
}

const std = @import("std");

test "validation rejects surface mismatch" {
    const config = types.BackendConfig{
        .surface_px = .{ .width = 1280, .height = 720 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = types.BackendCapability{
        .max_atlas_slots = 32,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const plan = types.RenderPlan{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
    };

    try std.testing.expectError(error.SurfaceMismatch, validatePlanForBackend(config, cap, plan));
}

test "validation rejects atlas slots outside capability range" {
    const uploads = [_]types.AtlasUpload{
        .{ .slot = 1, .codepoint = 'A', .width = 8, .height = 16 },
        .{ .slot = 2, .codepoint = 'B', .width = 8, .height = 16 },
    };
    const config = types.BackendConfig{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
    };
    const cap = types.BackendCapability{
        .max_atlas_slots = 2,
        .supports_fill_rect = true,
        .supports_glyph_quads = true,
    };
    const plan = types.RenderPlan{
        .surface_px = .{ .width = 640, .height = 480 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 80, .rows = 30 },
        .atlas_uploads = &uploads,
    };

    try std.testing.expectError(error.AtlasSlotOutOfRange, validatePlanForBackend(config, cap, plan));
}

test "summary mirrors render-plan stats" {
    const plan = types.RenderPlan{
        .surface_px = .{ .width = 800, .height = 600 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 100, .rows = 37 },
        .cursor = .{
            .cell_col = 0,
            .cell_row = 0,
            .shape = .beam,
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        },
    };
    const stats = summarizePlan(plan);
    try std.testing.expect(stats.has_cursor);
}
