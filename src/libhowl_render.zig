
const ffi = @import("ffi.zig");

comptime {
    @export(&ffi.deriveGridSize, .{ .name = "howl_render_derive_grid_size" });
    @export(&ffi.deriveFrameGridSize, .{ .name = "howl_render_derive_frame_grid_size" });
    @export(&ffi.surfaceTextDeriveFrameLayout, .{ .name = "howl_render_surface_text_derive_frame_layout" });
    @export(&ffi.surfaceTextInit, .{ .name = "howl_render_surface_text_init" });
    @export(&ffi.surfaceTextDeinit, .{ .name = "howl_render_surface_text_deinit" });
    @export(&ffi.surfaceTextSetFontSizePx, .{ .name = "howl_render_surface_text_set_font_size_px" });
    @export(&ffi.surfaceTextSetFontPath, .{ .name = "howl_render_surface_text_set_font_path" });
    @export(&ffi.surfaceTextSetFallbackFontPaths, .{ .name = "howl_render_surface_text_set_fallback_font_paths" });
    @export(&ffi.surfaceTextPrepareHandle, .{ .name = "howl_render_surface_text_prepare_handle" });
    @export(&ffi.preparedSurfaceRelease, .{ .name = "howl_render_prepared_surface_release" });
    @export(&ffi.preparedSurfaceDescribe, .{ .name = "howl_render_prepared_surface_describe" });
    @export(&ffi.preparedSurfaceDamagePlan, .{ .name = "howl_render_prepared_surface_damage_plan" });
    @export(&ffi.preparedSurfaceUploadPlan, .{ .name = "howl_render_prepared_surface_upload_plan" });
    @export(&ffi.preparedSurfaceDrawPlan, .{ .name = "howl_render_prepared_surface_draw_plan" });
    @export(&ffi.preparedSurfaceDiagnostics, .{ .name = "howl_render_prepared_surface_diagnostics" });
    @export(&ffi.surfaceTextSubmit, .{ .name = "howl_render_surface_text_submit" });
    @export(&ffi.surfaceTextCachedSprite, .{ .name = "howl_render_surface_text_cached_sprite" });
}
