//! Responsibility: provide a single render-core object surface.
//! Ownership: render-core orchestration API.
//! Reason: keep hosts/backends on one coherent entrypoint.

const std = @import("std");
const render_batch = @import("render_batch.zig");
const vt_state = @import("vt_state.zig");
const surface = @import("frame_state.zig");

pub const RenderCore = struct {
    pub const BackendConfig = render_batch.BackendConfig;
    pub const BackendCapability = render_batch.BackendCapability;
    pub const PixelSize = render_batch.PixelSize;
    pub const CellSize = render_batch.CellSize;
    pub const GridSize = render_batch.GridSize;
    pub const Rgba8 = render_batch.Rgba8;
    pub const FillRect = render_batch.FillRect;
    pub const GlyphQuad = render_batch.GlyphQuad;
    pub const CursorShape = render_batch.CursorShape;
    pub const CursorDraw = render_batch.CursorDraw;
    pub const AtlasUpload = render_batch.AtlasUpload;
    pub const RenderBatchStats = render_batch.RenderBatchStats;
    pub const RenderBatch = render_batch.RenderBatch;
    pub const CellInput = render_batch.CellInput;
    pub const GridInput = render_batch.GridInput;
    pub const CursorInput = render_batch.CursorInput;
    pub const VtState = render_batch.VtState;
    pub const FrameTheme = vt_state.FrameTheme;
    pub const OwnedRenderBatch = render_batch.OwnedRenderBatch;
    pub const SurfaceState = surface.SurfaceState;
    pub const SurfaceColor = surface.Color;
    pub const SurfaceCellFlags = surface.CellFlags;
    pub const SurfaceCellAttrs = surface.CellAttrs;
    pub const SurfaceCell = surface.Cell;
    pub const SurfaceGridModel = surface.GridModel;
    pub const SurfaceViewportInfo = surface.ViewportInfo;
    pub const SurfaceCursorShape = surface.CursorShape;
    pub const SurfaceCursorInfo = surface.CursorInfo;
    pub const SurfaceFrameData = surface.FrameData;
    pub const RenderBatchValidationError = render_batch.RenderBatchValidationError;
    pub const RenderBatchBuildError = render_batch.RenderBatchBuildError;
    pub const defaultTheme = vt_state.default_theme;

    config: render_batch.BackendConfig,
    capability: render_batch.BackendCapability,

    pub fn init(config: BackendConfig, capability: BackendCapability) RenderCore {
        return .{
            .config = config,
            .capability = capability,
        };
    }

    pub fn renderBatch(self: *const RenderCore, allocator: std.mem.Allocator, frame: VtState) RenderBatchBuildError!OwnedRenderBatch {
        return render_batch.renderBatch(allocator, frame, self.capability);
    }

    pub fn vtStateToRenderBatch(
        self: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: PixelSize,
        cell_px: CellSize,
    ) RenderBatchBuildError!OwnedRenderBatch {
        return vt_state.vtStateToRenderBatch(allocator, state, surface_px, cell_px, self.capability);
    }

    pub fn vtStateToRenderBatchWithTheme(
        self: *const RenderCore,
        allocator: std.mem.Allocator,
        state: anytype,
        surface_px: PixelSize,
        cell_px: CellSize,
        theme: FrameTheme,
    ) RenderBatchBuildError!OwnedRenderBatch {
        return vt_state.vtStateToRenderBatchWithTheme(allocator, state, surface_px, cell_px, theme, self.capability);
    }

    pub fn validateRenderBatch(self: *const RenderCore, batch: RenderBatch) RenderBatchValidationError!void {
        return render_batch.validateRenderBatch(self.config, self.capability, batch);
    }

    pub fn summarizeRenderBatch(_: *const RenderCore, batch: RenderBatch) RenderBatchStats {
        return render_batch.summarizeRenderBatch(batch);
    }

    /// Derive grid dimensions from pixel-space area and cell-size policy.
    pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
        const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
        const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
        return .{
            .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
            .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
        };
    }
};

test "render-core object: validate and summarize surface" {
    const rc = RenderCore.init(
        .{
            .surface_px = .{ .width = 16, .height = 16 },
            .cell_px = .{ .width = 8, .height = 16 },
        },
        .{
            .max_atlas_slots = 8,
            .supports_fill_rect = true,
            .supports_glyph_quads = true,
        },
    );

    const batch = render_batch.RenderBatch{
        .surface_px = .{ .width = 16, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
        .grid = .{ .cols = 2, .rows = 1 },
    };
    try rc.validateRenderBatch(batch);
    const stats = rc.summarizeRenderBatch(batch);
    try std.testing.expectEqual(@as(usize, 0), stats.glyphs);
}
