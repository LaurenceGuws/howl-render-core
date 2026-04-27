//! Responsibility: publish the render-core public API.
//! Ownership: backend-neutral renderer contract.
//! Reason: keep root thin while internal modules own policy details.

const types = @import("types.zig");
const theme = @import("theme.zig");
const planner = @import("planner.zig");
const execution_contract = @import("execution_contract.zig");

/// Configuration shared by renderer backend implementations at initialization.
pub const BackendConfig = types.BackendConfig;
/// Runtime capability report used by render-core planning.
pub const BackendCapability = types.BackendCapability;
/// Pixel dimensions for a drawable surface.
pub const PixelSize = types.PixelSize;
/// Pixel dimensions for one terminal grid cell.
pub const CellSize = types.CellSize;
/// Terminal grid dimensions in cells.
pub const GridSize = types.GridSize;
/// Eight-bit RGBA color used in render plans.
pub const Rgba8 = types.Rgba8;
/// Solid rectangle command emitted before glyph drawing.
pub const FillRect = types.FillRect;
/// Textured glyph rectangle with its atlas slot and foreground color.
pub const GlyphQuad = types.GlyphQuad;
/// Cursor shape variants supported by the shared plan contract.
pub const CursorShape = types.CursorShape;
/// Cursor command positioned in grid coordinates.
pub const CursorDraw = types.CursorDraw;
/// Glyph upload request keyed by atlas slot and codepoint.
pub const AtlasUpload = types.AtlasUpload;
/// Summary counts for a render plan.
pub const PlanStats = types.PlanStats;
/// Backend-neutral draw plan produced by render-core.
pub const RenderPlan = types.RenderPlan;
/// Backend-neutral terminal cell input consumed by the planner.
pub const CellInput = types.CellInput;
/// Row-major terminal cell buffer and dimensions consumed by the planner.
pub const GridInput = types.GridInput;
/// Cursor input from the surface-facing frame contract.
pub const CursorInput = types.CursorInput;
/// Complete frame input consumed by render-core planning.
pub const FrameInput = types.FrameInput;
/// Color theme used when converting frame colors before planning.
pub const FrameTheme = types.FrameTheme;
/// Owned render plan with buffers that must be released by the caller.
pub const OwnedPlan = types.OwnedPlan;
/// Errors returned when a backend validates a render plan before execution.
pub const ExecutionValidationError = execution_contract.ExecutionValidationError;

/// Default color theme used by the Linux MVP terminal frame path.
pub const linux_mvp_theme = theme.linux_mvp_theme;

/// Build an owned backend-neutral draw plan from a complete frame input.
pub const buildPlan = planner.buildPlan;
/// Validate a render plan against backend config and capability declarations.
pub const validatePlanForBackend = execution_contract.validatePlanForBackend;
/// Summarize command counts in a render plan for backend reporting.
pub const summarizePlan = execution_contract.summarizePlan;

test "module wiring: render-core internals compile" {
    _ = types;
    _ = theme;
    _ = planner;
    _ = execution_contract;
}
