
const ffi = @import("ffi.zig");

comptime {
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
    @export(&ffi.runtimeMarkPresented, .{ .name = "howl_render_runtime_mark_presented" });
    @export(&ffi.runtimeSurfaceQuery, .{ .name = "howl_render_runtime_surface_query" });
    @export(&ffi.runtimeTakeMetrics, .{ .name = "howl_render_runtime_take_metrics" });
    @export(&ffi.runtimeResetMetrics, .{ .name = "howl_render_runtime_reset_metrics" });
    @export(&ffi.surfaceSessionDeriveFrameLayout, .{ .name = "howl_render_surface_session_derive_frame_layout" });
    @export(&ffi.surfaceSessionInit, .{ .name = "howl_render_surface_session_init" });
    @export(&ffi.surfaceSessionDeinit, .{ .name = "howl_render_surface_session_deinit" });
    @export(&ffi.surfaceSessionSetFontSizePx, .{ .name = "howl_render_surface_session_set_font_size_px" });
    @export(&ffi.surfaceSessionSetFontPath, .{ .name = "howl_render_surface_session_set_font_path" });
    @export(&ffi.surfaceSessionSetFallbackFontPaths, .{ .name = "howl_render_surface_session_set_fallback_font_paths" });
    @export(&ffi.surfacePrepareHandle, .{ .name = "howl_render_surface_prepare_handle" });
    @export(&ffi.preparedSurfaceRelease, .{ .name = "howl_render_prepared_surface_release" });
    @export(&ffi.preparedSurfaceDescribe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&ffi.preparedSurfaceDamagePlan, .{ .name = "howl_render_prepared_surface_damage_plan" });
    @export(&ffi.preparedSurfaceUploadPlan, .{ .name = "howl_render_prepared_surface_upload_plan" });
    @export(&ffi.preparedSurfaceDrawPlan, .{ .name = "howl_render_prepared_surface_draw_plan" });
    @export(&ffi.preparedSurfaceDiagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&ffi.surfaceSubmit, .{ .name = "howl_render_surface_submit" });
}
