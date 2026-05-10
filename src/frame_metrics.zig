//! Responsibility: own render-frame metric contracts.
//! Ownership: prepare and submit timing/count readouts.
//! Reason: keep render diagnostics shaped by render-core, not terminal orchestration.

pub const PrepareMetrics = struct {
    us: u64 = 0,
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    renderer_us: u64 = 0,
    input_us: u64 = 0,
    sparse_us: u64 = 0,
    clusters_us: u64 = 0,
    resolve_us: u64 = 0,
    shape_us: u64 = 0,
    group_us: u64 = 0,
    scene_us: u64 = 0,
    raster_us: u64 = 0,
    atlas_us: u64 = 0,
};

pub const RenderMetrics = struct {
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    glyphs: usize = 0,
    fills: usize = 0,
    clear_fills: usize = 0,
    background_fills: usize = 0,
    decoration_fills: usize = 0,
    cursor_fills: usize = 0,
    uploads: usize = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,
};
