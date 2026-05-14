//! Responsibility: define the howl-render ABI export root.
//! Ownership: export `howl_render_*` symbols only.
//! Reason: keep the shipped boundary on the C ABI instead of a Zig root.

const ffi = @import("ffi.zig");

comptime {
    @export(&ffi.deriveGridSize, .{ .name = "howl_render_derive_grid_size" });
    @export(&ffi.deriveFrameGridSize, .{ .name = "howl_render_derive_frame_grid_size" });
    @export(&ffi.rendererDeriveFrameLayout, .{ .name = "howl_render_renderer_derive_frame_layout" });
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
    @export(&ffi.runtimeMarkPresented, .{ .name = "howl_render_runtime_mark_presented" });
    @export(&ffi.runtimeSurfaceQuery, .{ .name = "howl_render_runtime_surface_query" });
    @export(&ffi.runtimeTakeMetrics, .{ .name = "howl_render_runtime_take_metrics" });
    @export(&ffi.runtimeResetMetrics, .{ .name = "howl_render_runtime_reset_metrics" });
    @export(&ffi.rendererInit, .{ .name = "howl_render_renderer_init" });
    @export(&ffi.rendererDeinit, .{ .name = "howl_render_renderer_deinit" });
    @export(&ffi.rendererSetFontSizePx, .{ .name = "howl_render_renderer_set_font_size_px" });
    @export(&ffi.rendererSetFontPath, .{ .name = "howl_render_renderer_set_font_path" });
    @export(&ffi.rendererSetFallbackFontPaths, .{ .name = "howl_render_renderer_set_fallback_font_paths" });
    @export(&ffi.rendererPrepare, .{ .name = "howl_render_renderer_prepare" });
    @export(&ffi.rendererSubmit, .{ .name = "howl_render_renderer_submit" });
}
