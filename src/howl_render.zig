//! Responsibility: curate the howl-render public surface.
//! Ownership: none beyond export curation.
//! Reason: keep package-root naming explicit without moving owner policy upward.

const lib = @This();
const std = @import("std");
const render = @import("render_namespace.zig");
const ffi = render.Ffi;

pub const Render = render.Render;
pub const Ffi = ffi;
pub const Renderer = render.Renderer;

comptime {
    if (@import("root") == lib) {
        @export(&ffi.deriveGridSize, .{ .name = "howl_render_derive_grid_size" });
        @export(&ffi.deriveFrameGridSize, .{ .name = "howl_render_derive_frame_grid_size" });
        @export(&ffi.snapshotInit, .{ .name = "howl_render_snapshot_init" });
        @export(&ffi.snapshotDeinit, .{ .name = "howl_render_snapshot_deinit" });
        @export(&ffi.snapshotResize, .{ .name = "howl_render_snapshot_resize" });
        @export(&ffi.snapshotMarkFullDirty, .{ .name = "howl_render_snapshot_mark_full_dirty" });
        @export(&ffi.snapshotClearDirty, .{ .name = "howl_render_snapshot_clear_dirty" });
        @export(&ffi.snapshotSetViewport, .{ .name = "howl_render_snapshot_set_viewport" });
        @export(&ffi.snapshotSetCursor, .{ .name = "howl_render_snapshot_set_cursor" });
        @export(&ffi.snapshotWriteCell, .{ .name = "howl_render_snapshot_write_cell" });
        @export(&ffi.runtimeInit, .{ .name = "howl_render_runtime_init" });
        @export(&ffi.runtimeDeinit, .{ .name = "howl_render_runtime_deinit" });
        @export(&ffi.runtimeSetFontSizePx, .{ .name = "howl_render_runtime_set_font_size_px" });
        @export(&ffi.runtimeSyncGeometry, .{ .name = "howl_render_runtime_sync_geometry" });
        @export(&ffi.runtimePublishSnapshot, .{ .name = "howl_render_runtime_publish_snapshot" });
        @export(&ffi.runtimeAction, .{ .name = "howl_render_runtime_action" });
        @export(&ffi.runtimeMarkPresented, .{ .name = "howl_render_runtime_mark_presented" });
        @export(&ffi.runtimeSurfaceQuery, .{ .name = "howl_render_runtime_surface_query" });
        @export(&ffi.runtimeTakeMetrics, .{ .name = "howl_render_runtime_take_metrics" });
        @export(&ffi.runtimeResetMetrics, .{ .name = "howl_render_runtime_reset_metrics" });
        @export(&ffi.rendererInit, .{ .name = "howl_render_renderer_init" });
        @export(&ffi.rendererDeinit, .{ .name = "howl_render_renderer_deinit" });
        @export(&ffi.rendererSetFontSizePx, .{ .name = "howl_render_renderer_set_font_size_px" });
        @export(&ffi.rendererSetFontPath, .{ .name = "howl_render_renderer_set_font_path" });
        @export(&ffi.rendererPrepare, .{ .name = "howl_render_renderer_prepare" });
        @export(&ffi.rendererSubmit, .{ .name = "howl_render_renderer_submit" });
    }
}

test {
    _ = @import("test/root.zig");
    std.testing.refAllDecls(lib);
}
