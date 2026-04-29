//! Responsibility: publish the render-core public API.
//! Ownership: backend-neutral renderer api.
//! Reason: keep root thin while internal modules own policy details.

const types = @import("types.zig");
const render_batch = @import("render_batch.zig");
const vt_state = @import("vt_state.zig");

/// Configuration shared by renderer backend implementations at initialization.
pub const BackendConfig = types.BackendConfig;
/// Runtime capability report used by render-core batch generation.
pub const BackendCapability = types.BackendCapability;
/// Pixel dimensions for a drawable surface.
pub const PixelSize = types.PixelSize;
/// Pixel dimensions for one terminal grid cell.
pub const CellSize = types.CellSize;
/// Terminal grid dimensions in cells.
pub const GridSize = types.GridSize;
/// Eight-bit RGBA color used in render batches.
pub const Rgba8 = types.Rgba8;
/// Solid rectangle command emitted before glyph drawing.
pub const FillRect = types.FillRect;
/// Textured glyph rectangle with its atlas slot and foreground color.
pub const GlyphQuad = types.GlyphQuad;
/// Cursor shape variants supported by the shared batch api.
pub const CursorShape = types.CursorShape;
/// Cursor command positioned in grid coordinates.
pub const CursorDraw = types.CursorDraw;
/// Glyph upload request keyed by atlas slot and codepoint.
pub const AtlasUpload = types.AtlasUpload;
/// Summary counts for a render batch.
pub const RenderBatchStats = types.RenderBatchStats;
/// Backend-neutral draw batch produced by render-core.
pub const RenderBatch = types.RenderBatch;
/// Backend-neutral terminal cell input consumed by render batch generation.
pub const CellInput = types.CellInput;
/// Row-major terminal cell buffer and dimensions consumed by render batch generation.
pub const GridInput = types.GridInput;
/// Cursor input from VT state mapping.
pub const CursorInput = types.CursorInput;
/// Complete VT state consumed by render-core batch generation.
pub const VtState = types.VtState;
/// Color theme used while mapping VT state colors before batch generation.
pub const FrameTheme = types.FrameTheme;
/// Owned render batch with buffers that must be released by the caller.
pub const OwnedRenderBatch = types.OwnedRenderBatch;
/// Errors returned when a backend validates a render batch before render.
pub const RenderBatchValidationError = render_batch.RenderBatchValidationError;

/// Default color theme used by VT state conversion.
pub const default_theme = vt_state.default_theme;

/// Build an owned backend-neutral draw batch from a complete frame input.
pub const renderBatch = render_batch.renderBatch;
/// Build an owned backend-neutral draw batch from VT state.
pub const vtStateToRenderBatch = vt_state.vtStateToRenderBatch;
/// Build an owned backend-neutral draw batch from VT state with explicit theme.
pub const vtStateToRenderBatchWithTheme = vt_state.vtStateToRenderBatchWithTheme;
/// Validate a render batch against backend config and capability declarations.
pub const validateRenderBatch = render_batch.validateRenderBatch;
/// Summarize command counts in a render batch for backend reporting.
pub const summarizeRenderBatch = render_batch.summarizeRenderBatch;

test "module wiring: render-core internals compile" {
    _ = types;
    _ = render_batch;
    _ = vt_state;
}
