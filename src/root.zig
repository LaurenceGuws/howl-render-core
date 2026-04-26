//! Responsibility: publish the render-core public API.
//! Ownership: backend-neutral renderer contract.
//! Reason: keep root thin while internal modules own policy details.

const types = @import("types.zig");
const theme = @import("theme.zig");
const planner = @import("planner.zig");

pub const BackendConfig = types.BackendConfig;
pub const BackendCapability = types.BackendCapability;
pub const PixelSize = types.PixelSize;
pub const CellSize = types.CellSize;
pub const GridSize = types.GridSize;
pub const Rgba8 = types.Rgba8;
pub const FillRect = types.FillRect;
pub const GlyphQuad = types.GlyphQuad;
pub const CursorShape = types.CursorShape;
pub const CursorDraw = types.CursorDraw;
pub const AtlasUpload = types.AtlasUpload;
pub const PlanStats = types.PlanStats;
pub const RenderPlan = types.RenderPlan;
pub const CellInput = types.CellInput;
pub const GridInput = types.GridInput;
pub const CursorInput = types.CursorInput;
pub const FrameInput = types.FrameInput;
pub const FrameTheme = types.FrameTheme;
pub const OwnedPlan = types.OwnedPlan;

pub const linux_mvp_theme = theme.linux_mvp_theme;

pub const buildPlan = planner.buildPlan;

test "module wiring: render-core internals compile" {
    _ = types;
    _ = theme;
    _ = planner;
}
