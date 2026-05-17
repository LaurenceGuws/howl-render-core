const text = @import("../text/text.zig");

pub fn markRendered(atlas: *text.AtlasCache.OwnedAtlasCache, outputs: []const text.Rasterizer.RasterSpriteOutput) void {
    for (outputs) |output| {
        _ = atlas.storeRendered(output) catch {
            _ = atlas.markRendered(output.key);
            continue;
        };
    }
}

pub fn buildReport(comptime Report: type, prepared: anytype, execution: anytype) Report {
    return .{
        .texture_id = execution.surface.texture_id,
        .raster_uploads_committed = execution.uploads_committed,
        .full_redraw = prepared.text_frame.scene.scene.full_redraw,
        .scroll_up_px = prepared.text_frame.scene.scene.scroll_up_px,
        .clear_draws = prepared.text_frame.scene.scene.clear_draws.len,
        .background_draws = prepared.text_frame.scene.scene.background_draws.len,
        .sprite_draws = prepared.text_frame.scene.scene.sprite_draws.len,
        .decoration_draws = prepared.text_frame.scene.scene.decoration_draws.len,
        .cursor_draws = prepared.text_frame.scene.scene.cursor_draws.len,
    };
}

pub fn renderMetrics(comptime RenderMetrics: type, prepare_metrics: anytype, report: anytype, counters: anytype, render_us: u64) RenderMetrics {
    return .{
        .sync_us = prepare_metrics.sync_us,
        .copy_us = prepare_metrics.copy_us,
        .render_us = render_us,
        .glyphs = report.sprite_draws,
        .fills = report.clear_draws + report.background_draws + report.decoration_draws + report.cursor_draws,
        .clear_fills = report.clear_draws,
        .background_fills = report.background_draws,
        .decoration_fills = report.decoration_draws,
        .cursor_fills = report.cursor_draws,
        .uploads = report.raster_uploads_committed,
        .face_checks = counters.face_checks,
        .face_cache_hits = counters.face_cache_hits,
        .shape_requests = counters.shape_requests,
        .shape_cache_hits = counters.shape_cache_hits,
        .fallback_hits = counters.fallback_hits,
        .fallback_misses = counters.fallback_misses,
        .missing_glyphs = counters.missing_glyphs,
    };
}
