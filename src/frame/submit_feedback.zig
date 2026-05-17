const text = @import("../text/text.zig");
const pipeline = @import("pipeline.zig");

pub fn markRendered(atlas: *text.AtlasCache.OwnedAtlasCache, outputs: []const text.Rasterizer.RasterSpriteOutput) void {
    for (outputs) |output| {
        _ = atlas.storeRendered(output) catch {
            _ = atlas.markRendered(output.key);
            continue;
        };
    }
}

pub fn damageKind(prepared: anytype) pipeline.DamageKind {
    if (prepared.text_frame.scene.scene.full_redraw) return .full;
    if (prepared.text_frame.scene.scene.scroll_up_px > 0) return .scroll;
    return .partial;
}

pub fn renderMetrics(comptime RenderMetrics: type, prepare_metrics: anytype, prepared: anytype, uploads_committed: u64, counters: anytype, render_us: u64) RenderMetrics {
    return .{
        .sync_us = prepare_metrics.sync_us,
        .copy_us = prepare_metrics.copy_us,
        .render_us = render_us,
        .glyphs = prepared.text_frame.scene.scene.sprite_draws.len,
        .fills = prepared.text_frame.scene.scene.clear_draws.len +
            prepared.text_frame.scene.scene.background_draws.len +
            prepared.text_frame.scene.scene.decoration_draws.len +
            prepared.text_frame.scene.scene.cursor_draws.len,
        .clear_fills = prepared.text_frame.scene.scene.clear_draws.len,
        .background_fills = prepared.text_frame.scene.scene.background_draws.len,
        .decoration_fills = prepared.text_frame.scene.scene.decoration_draws.len,
        .cursor_fills = prepared.text_frame.scene.scene.cursor_draws.len,
        .uploads = uploads_committed,
        .face_checks = counters.face_checks,
        .face_cache_hits = counters.face_cache_hits,
        .shape_requests = counters.shape_requests,
        .shape_cache_hits = counters.shape_cache_hits,
        .fallback_hits = counters.fallback_hits,
        .fallback_misses = counters.fallback_misses,
        .missing_glyphs = counters.missing_glyphs,
    };
}
