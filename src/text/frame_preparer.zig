
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const direct_normal = @import("direct_normal.zig");
const direct_scene = @import("direct_scene.zig");
const pipeline = @import("pipeline.zig");
const atlas_cache = @import("raster/cache.zig");
const cluster = @import("shape/cluster.zig");
const font_resolver = @import("font/resolver.zig");
const font_session = @import("font/session.zig");
const ft_hb_provider = @import("font/ft_hb/provider.zig");
const grouping = @import("shape/grouping.zig");
const provider = @import("font/provider.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("scene.zig");
const shape_run = @import("shape/run.zig");
const lane = @import("classify/lane.zig");

pub const PrepareTimings = struct {
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

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

pub const TextFramePreparer = struct {
    allocator: std.mem.Allocator,
    counters: pipeline.TextPrepareCounters = .{},
    atlas: atlas_cache.OwnedAtlasCache,
    shaper: shape_run.Shaper,
    sprite_rasterizer: rasterizer.Rasterizer,
    glyph_lookup: provider.LookupGlyphOp,
    glyph_raster: pipeline.RasterizeGlyphOp,
    direct_normal: direct_normal.Scratch = .{},

    pub fn init(allocator: std.mem.Allocator) TextFramePreparer {
        return initCapacity(allocator, 4096) catch unreachable;
    }

    pub fn initCapacity(allocator: std.mem.Allocator, atlas_capacity: usize) !TextFramePreparer {
        return initWithProvider(allocator, atlas_capacity, provider.defaultProvider());
    }

    pub fn initWithShaper(allocator: std.mem.Allocator, atlas_capacity: usize, shaper: shape_run.Shaper) !TextFramePreparer {
        return initWithProvider(allocator, atlas_capacity, .{ .shaper = shaper });
    }

    pub fn initWithProvider(allocator: std.mem.Allocator, atlas_capacity: usize, text_provider: provider.TextProvider) !TextFramePreparer {
        return .{
            .allocator = allocator,
            .atlas = try atlas_cache.OwnedAtlasCache.init(allocator, atlas_capacity),
            .shaper = text_provider.shaper,
            .sprite_rasterizer = text_provider.rasterizer,
            .glyph_lookup = text_provider.glyph_lookup,
            .glyph_raster = text_provider.glyph_raster,
        };
    }

    pub fn deinit(self: *TextFramePreparer) void {
        self.direct_normal.deinit(self.allocator);
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn clearAtlas(self: *TextFramePreparer) void {
        self.atlas.len = 0;
        self.atlas.next_slot = 0;
    }

    pub fn prepareCellsWithSessionOptions(self: *TextFramePreparer, cells: []const contract.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: PrepareOptions) !OwnedPreparedTextFrame {
        var lane_report = lane.LaneReport{};
        if (try self.prepareDirectNormal(.{ .raw_cells = cells }, .require_all_normal, grid_metrics, session, options, &lane_report)) |direct| {
            return self.finishNormalOnlyFrame(direct, lane_report, .{});
        }
        var timings = PrepareTimings{};
        const sparse_start_ns = monotonicNs();
        var sparse = try cluster.buildSparseCellsWithDamage(self.allocator, cells, grid_metrics, options.scene.damage);
        timings.sparse_us = elapsedUs(sparse_start_ns);
        errdefer sparse.deinit();
        return self.preparePreparedFrame(sparse.text_cache, sparse.renderable, grid_metrics, session, options, timings);
    }

    pub fn prepareCellTextInputsWithSessionOptions(self: *TextFramePreparer, inputs: []const cluster.CellTextInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: PrepareOptions) !OwnedPreparedTextFrame {
        var lane_report = lane.LaneReport{};
        if (try self.prepareDirectNormal(.{ .inputs = inputs }, .require_all_normal, grid_metrics, session, options, &lane_report)) |direct| {
            return self.finishNormalOnlyFrame(direct, lane_report, .{});
        }
        var text_cache = try cluster.buildLineTextCacheFromInputs(self.allocator, inputs);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromInputs(self.allocator, inputs, text_cache.view());
        errdefer renderable.deinit();
        return self.preparePreparedFrame(text_cache, renderable, grid_metrics, session, options, .{});
    }

    fn preparePreparedFrame(
        self: *TextFramePreparer,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        initial_timings: PrepareTimings,
    ) !OwnedPreparedTextFrame {
        var timings = initial_timings;
        var owned_text_cache = text_cache;
        errdefer owned_text_cache.deinit();
        var owned_renderable = renderable;
        errdefer owned_renderable.deinit();
        const clusters_start_ns = monotonicNs();
        var clusters = try cluster.extractClustersWithDamage(self.allocator, owned_renderable.cells, owned_text_cache.view(), grid_metrics, options.scene.damage);
        timings.clusters_us = elapsedUs(clusters_start_ns);
        errdefer clusters.deinit();
        var final_lane_report = lane.LaneReport.init(owned_text_cache.view(), owned_renderable.cells, clusters.clusters);
        const direct = (try self.prepareDirectNormal(
            .{ .prepared = .{ .cells = owned_renderable.cells, .text_cache = owned_text_cache.view() } },
            .skip_complex,
            grid_metrics,
            session,
            options,
            &final_lane_report,
        )).?;

        if (final_lane_report.complex_cells == 0) {
            owned_text_cache.deinit();
            clusters.deinit();
            owned_renderable.deinit();
            return self.finishNormalOnlyFrame(direct, final_lane_report, timings);
        }

        return self.prepareComplexFrame(
            .{
                .text_cache = owned_text_cache,
                .renderable = owned_renderable,
                .clusters = clusters,
                .direct = direct,
                .lane_report = final_lane_report,
            },
            grid_metrics,
            session,
            options,
            &timings,
        );
    }

    fn prepareComplexFrame(
        self: *TextFramePreparer,
        prepared: PreparedComplexFrame,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        timings: *PrepareTimings,
    ) !OwnedPreparedTextFrame {
        var final_prepared = prepared;
        errdefer final_prepared.deinit(self.allocator);
        var complex = try cluster.selectComplexWithDamage(self.allocator, final_prepared.renderable.cells, final_prepared.text_cache.view(), final_prepared.clusters.clusters, grid_metrics, options.scene.damage);
        defer complex.deinit();
        std.debug.assert(complex.cells.len == final_prepared.lane_report.complex_cells);
        std.debug.assert(complex.clusters.len == final_prepared.lane_report.complex_clusters);

        final_prepared.runs = try resolveComplexRuns(self, final_prepared.text_cache.view(), complex.clusters, grid_metrics, session, timings, &final_prepared.lane_report, complex.cells);
        final_prepared.shaped_runs = try shapeComplexRuns(self, final_prepared.runs.?.runs, final_prepared.text_cache.view(), complex.clusters, session.metrics, timings, &final_prepared.lane_report, complex.cells);
        final_prepared.grouped = try groupComplexRuns(self, final_prepared.shaped_runs.?.runs, final_prepared.runs.?.sprite_routes, complex.clusters, session.metrics, timings, &final_prepared.lane_report, final_prepared.text_cache.view(), complex.cells);
        const scene_start_ns = monotonicNs();
        var text_scene = try scene.buildSceneWithAtlasCacheOptions(self.allocator, complex.cells, final_prepared.grouped.?.groups.groups, final_prepared.runs.?.missing, session.metrics, grid_metrics, &self.atlas, options.scene);
        timings.scene_us = elapsedUs(scene_start_ns);
        errdefer text_scene.deinit();
        for (text_scene.scene.sprite_draws) |draw| final_prepared.lane_report.recordLegacySceneSpriteDraw(final_prepared.text_cache.view(), complex.cells, draw);

        const raster_start_ns = monotonicNs();
        var raster_plan = try rasterizer.rasterizeRequestsWithRasterizer(self.allocator, self.sprite_rasterizer, text_scene.scene.raster_requests);
        timings.raster_us = elapsedUs(raster_start_ns);
        errdefer raster_plan.deinit();
        const complex_sprite_cache_hits = text_scene.scene.sprite_draws.len - text_scene.scene.raster_requests.len;

        const merged = try self.mergePreparedScene(final_prepared.direct, &text_scene, &raster_plan);
        final_prepared.direct.outputs = &.{};
        final_prepared.direct.outputs_owned = false;

        final_prepared.lane_report.assertValid();
        var counters = pipeline.TextPrepareCounters{
            .cell_texts = final_prepared.lane_report.visible_cells,
            .clusters = final_prepared.lane_report.normal_clusters + final_prepared.lane_report.complex_clusters,
            .resolved_runs = final_prepared.runs.?.runs.len,
            .shaped_runs = final_prepared.shaped_runs.?.runs.len,
            .glyph_groups = final_prepared.grouped.?.groups.groups.len,
            .sprite_cache_hits = @intCast((self.direct_normal.sprite_draws.items.len - self.direct_normal.raster_reqs.items.len) + complex_sprite_cache_hits),
            .sprite_cache_misses = @intCast(self.direct_normal.raster_reqs.items.len + text_scene.scene.raster_requests.len),
            .rasterized_sprites = @intCast(merged.raster_plan.outputs.len),
            .missing_glyphs = merged.scene.scene.missing.len,
        };
        for (final_prepared.shaped_runs.?.runs) |run| counters.shaped_glyphs += run.glyphs.len;
        applyCounters(&self.counters, counters);
        final_prepared.deinit(self.allocator);

        return .{
            .scene = merged.scene,
            .raster_plan = merged.raster_plan,
            .timings = timings.*,
        };
    }

    fn mergePreparedScene(
        self: *TextFramePreparer,
        direct: direct_normal.Product,
        text_scene: *scene.OwnedTextScene,
        raster_plan: *rasterizer.OwnedRasterPlan,
    ) !PreparedSceneMerge {
        const merged_clear_draws = try cloneSlice(contract.TextClearDraw, self.allocator, self.direct_normal.clear_draws.items);
        errdefer self.allocator.free(merged_clear_draws);
        const merged_cursor_draws = try cloneSlice(contract.TextCursorDraw, self.allocator, self.direct_normal.cursor_draws.items);
        errdefer self.allocator.free(merged_cursor_draws);
        const merged_background_draws = try mergeFirstCellSlices(contract.TextBackgroundDraw, self.allocator, self.direct_normal.background_draws.items, text_scene.scene.background_draws);
        errdefer self.allocator.free(merged_background_draws);
        const merged_sprite_draws = try mergeFirstCellSlices(contract.TextSpriteDraw, self.allocator, self.direct_normal.sprite_draws.items, text_scene.scene.sprite_draws);
        errdefer self.allocator.free(merged_sprite_draws);
        const merged_decoration_draws = try mergeFirstCellSlices(contract.TextDecorationDraw, self.allocator, self.direct_normal.decoration_draws.items, text_scene.scene.decoration_draws);
        errdefer self.allocator.free(merged_decoration_draws);
        const merged_missing = try mergeSlices(contract.MissingGlyph, self.allocator, self.direct_normal.missing.items, text_scene.scene.missing);
        errdefer self.allocator.free(merged_missing);
        var merged_raster_plan = try mergeRasterPlans(self.allocator, direct.outputs, direct.outputs_owned, raster_plan);
        errdefer merged_raster_plan.deinit();

        direct_scene.installMergedScene(text_scene, direct.damage, .{
            .clear_draws = merged_clear_draws,
            .cursor_draws = merged_cursor_draws,
            .background_draws = merged_background_draws,
            .sprite_draws = merged_sprite_draws,
            .decoration_draws = merged_decoration_draws,
            .missing = merged_missing,
        });
        return .{ .scene = text_scene.*, .raster_plan = merged_raster_plan };
    }

    fn finishNormalOnlyFrame(
        self: *TextFramePreparer,
        direct: direct_normal.Product,
        lane_report: lane.LaneReport,
        timings: PrepareTimings,
    ) OwnedPreparedTextFrame {
        var final_lane_report = lane_report;
        final_lane_report.assertValid();
        const counters = direct_normal.counters(&self.direct_normal, final_lane_report, direct);
        applyCounters(&self.counters, counters);
        return .{
            .scene = direct_scene.borrowScene(self.allocator, direct.damage, &self.direct_normal),
            .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
            .timings = timings,
        };
    }

    fn prepareDirectNormal(
        self: *TextFramePreparer,
        source: direct_normal.Source,
        policy: direct_normal.Policy,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: PrepareOptions,
        lane_report: *lane.LaneReport,
    ) !?direct_normal.Product {
        return try direct_normal.prepare(
            .{
                .allocator = self.allocator,
                .atlas = &self.atlas,
                .glyph_lookup = self.glyph_lookup,
                .glyph_raster = self.glyph_raster,
                .scratch = &self.direct_normal,
            },
            source,
            policy,
            grid_metrics,
            session,
            options.scene.damage,
            options.scene.cursor,
            lane_report,
        );
    }

};

const PreparedSceneMerge = struct {
    scene: scene.OwnedTextScene,
    raster_plan: rasterizer.OwnedRasterPlan,
};

const PreparedComplexFrame = struct {
    text_cache: cluster.OwnedLineTextCache,
    renderable: cluster.OwnedRenderableCells,
    clusters: cluster.OwnedClusters,
    direct: direct_normal.Product,
    lane_report: lane.LaneReport,
    runs: ?font_resolver.OwnedResolvedRuns = null,
    shaped_runs: ?shape_run.OwnedShapedRuns = null,
    grouped: ?PreparedGroups = null,

    fn deinit(self: *PreparedComplexFrame, allocator: std.mem.Allocator) void {
        if (self.grouped) |*grouped| grouped.deinit();
        if (self.shaped_runs) |*shaped_runs| shaped_runs.deinit();
        if (self.runs) |*runs| runs.deinit();
        self.direct.deinit(allocator);
        self.clusters.deinit();
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

const PreparedGroups = struct {
    font_groups: grouping.OwnedGlyphGroups,
    sprite_groups: grouping.OwnedGlyphGroups,
    groups: grouping.OwnedGlyphGroups,

    fn deinit(self: *PreparedGroups) void {
        self.groups.deinit();
        self.sprite_groups.deinit();
        self.font_groups.deinit();
        self.* = undefined;
    }
};

fn resolveComplexRuns(
    self: *TextFramePreparer,
    text_cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    cells: []const contract.RenderableCell,
) !font_resolver.OwnedResolvedRuns {
    const resolve_start_ns = monotonicNs();
    const runs = try font_resolver.resolveClusters(self.allocator, session, clusters, text_cache, grid_metrics);
    timings.resolve_us = elapsedUs(resolve_start_ns);
    for (runs.runs) |run| lane_report.recordLegacyResolvedRunWithCells(text_cache, cells, clusters, run);
    return runs;
}

fn shapeComplexRuns(
    self: *TextFramePreparer,
    runs: []const contract.ResolvedRun,
    text_cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    cells: []const contract.RenderableCell,
) !shape_run.OwnedShapedRuns {
    const shape_start_ns = monotonicNs();
    const shaped_runs = try shape_run.shapeResolvedRunsWithShaper(self.allocator, self.shaper, runs, text_cache, clusters, cell_metrics);
    timings.shape_us = elapsedUs(shape_start_ns);
    for (shaped_runs.runs) |run| lane_report.recordLegacyShapedRunWithCells(text_cache, cells, clusters, run.run);
    return shaped_runs;
}

fn groupComplexRuns(
    self: *TextFramePreparer,
    shaped_runs: []const shape_run.OwnedShapedRun,
    sprite_routes: []const font_resolver.SpriteRouteHit,
    clusters: []const contract.CellCluster,
    cell_metrics: contract.CellMetrics,
    timings: *PrepareTimings,
    lane_report: *lane.LaneReport,
    text_cache: contract.LineTextCache,
    cells: []const contract.RenderableCell,
) !PreparedGroups {
    const group_start_ns = monotonicNs();
    var font_groups = try grouping.groupShapedRunsWithPolicy(self.allocator, shaped_runs, clusters, cell_metrics, .{});
    errdefer font_groups.deinit();
    var sprite_groups = try grouping.groupSpriteRoutes(self.allocator, sprite_routes, clusters, cell_metrics);
    errdefer sprite_groups.deinit();
    const groups = try grouping.concatGroups(self.allocator, font_groups.groups, sprite_groups.groups);
    timings.group_us = elapsedUs(group_start_ns);
    for (groups.groups) |group| lane_report.recordLegacyGroup(text_cache, cells, group);
    return .{ .font_groups = font_groups, .sprite_groups = sprite_groups, .groups = groups };
}

pub const OwnedPreparedTextFrame = struct {
    scene: scene.OwnedTextScene,
    raster_plan: rasterizer.OwnedRasterPlan,
    timings: PrepareTimings = .{},

    pub fn deinit(self: *OwnedPreparedTextFrame) void {
        self.raster_plan.deinit();
        self.scene.deinit();
        self.* = undefined;
    }
};

fn applyCounters(total: *pipeline.TextPrepareCounters, delta: pipeline.TextPrepareCounters) void {
    total.cell_texts += delta.cell_texts;
    total.clusters += delta.clusters;
    total.resolved_runs += delta.resolved_runs;
    total.shaped_runs += delta.shaped_runs;
    total.shaped_glyphs += delta.shaped_glyphs;
    total.glyph_groups += delta.glyph_groups;
    total.sprite_cache_hits += delta.sprite_cache_hits;
    total.sprite_cache_misses += delta.sprite_cache_misses;
    total.rasterized_sprites += delta.rasterized_sprites;
    total.missing_glyphs += delta.missing_glyphs;
}

fn textForCluster(text_cache: contract.LineTextCache, cluster_value: contract.CellCluster) contract.CellText {
    const idx = @as(usize, @intCast(cluster_value.text_id.value));
    std.debug.assert(idx < text_cache.texts.len);
    return text_cache.texts[idx];
}

fn cloneSlice(comptime T: type, allocator: std.mem.Allocator, src: []const T) ![]T {
    const out = try allocator.alloc(T, src.len);
    @memcpy(out, src);
    return out;
}

fn mergeSlices(comptime T: type, allocator: std.mem.Allocator, lhs: []const T, rhs: []const T) ![]T {
    const out = try allocator.alloc(T, lhs.len + rhs.len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn mergeFirstCellSlices(comptime T: type, allocator: std.mem.Allocator, lhs: []const T, rhs: []const T) ![]T {
    const out = try allocator.alloc(T, lhs.len + rhs.len);
    var li: usize = 0;
    var ri: usize = 0;
    var oi: usize = 0;
    while (li < lhs.len and ri < rhs.len) {
        if (@field(lhs[li], "first_cell") <= @field(rhs[ri], "first_cell")) {
            out[oi] = lhs[li];
            li += 1;
        } else {
            out[oi] = rhs[ri];
            ri += 1;
        }
        oi += 1;
    }
    while (li < lhs.len) : (li += 1) {
        out[oi] = lhs[li];
        oi += 1;
    }
    while (ri < rhs.len) : (ri += 1) {
        out[oi] = rhs[ri];
        oi += 1;
    }
    return out;
}

fn mergeRasterPlans(
    allocator: std.mem.Allocator,
    direct_outputs: []rasterizer.RasterSpriteOutput,
    direct_outputs_owned: bool,
    complex_plan: *rasterizer.OwnedRasterPlan,
) !rasterizer.OwnedRasterPlan {
    const out = try allocator.alloc(rasterizer.RasterSpriteOutput, direct_outputs.len + complex_plan.outputs.len);
    @memcpy(out[0..direct_outputs.len], direct_outputs);
    @memcpy(out[direct_outputs.len..], complex_plan.outputs);
    if (direct_outputs_owned) allocator.free(direct_outputs);
    const complex_outputs = complex_plan.outputs;
    complex_plan.outputs = &.{};
    complex_plan.owned = false;
    allocator.free(complex_outputs);
    return .{ .allocator = allocator, .outputs = out };
}

    pub const PrepareOptions = struct {
    scene: scene.BuildOptions = .{},
};

test "text frame preparer prepares cell inputs into clusters and runs" {
    var engine = TextFramePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.cell_texts);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.glyph_groups);
}

test "text frame preparer records sprite routes through resolver" {
    var engine = TextFramePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 0x2500, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u32, 1), analysis.scene.scene.sprite_draws[1].first_cell);
    try std.testing.expect(analysis.scene.scene.sprite_draws[1].placement.advance_px > 0);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.sprite_cache_misses);
}

test "text frame preparer scene is grid positioned" {
    var engine = TextFramePreparer.init(std.testing.allocator);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
        .{ .codepoint = 'c', .fg = white, .bg = black },
        .{ .codepoint = 'd', .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 2 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 4), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(i32, 0), analysis.scene.scene.sprite_draws[2].x_px);
    try std.testing.expectEqual(@as(i32, 1), analysis.scene.scene.sprite_draws[2].y_px);
}

test "text frame preparer rerasterizes pending atlas entries across prepares" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 'z', .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    const first_slot = first.scene.scene.sprite_draws[0].sprite.slot;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer second.deinit();
    try std.testing.expectEqual(first_slot, second.scene.scene.sprite_draws[0].sprite.slot);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), engine.atlas.len);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.sprite_cache_hits);
    try std.testing.expect(!engine.atlas.get(.{ .value = second.scene.scene.sprite_draws[0].sprite.key.value }).?.rendered);
}

test "text frame preparer rerasterizes sprites after cell metrics change" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x2588, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } }, .{});
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 16, .cell_h_px = 32, .baseline_px = 24 } }, .{});
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u16, 16), second.raster_plan.outputs[0].width_px);
    try std.testing.expectEqual(@as(u16, 32), second.raster_plan.outputs[0].height_px);
}

test "text frame preparer rerasterizes sprites after box thickness change" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x256d, .fg = white, .bg = black }};
    var first = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 1 } }, .{});
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 3 } }, .{});
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
}

test "text frame preparer accepts configurable shaper" {
    const Stub = struct {
        hits: usize = 0,

        fn shape(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return shape_run.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    var stub = Stub{};
    var engine = try TextFramePreparer.initWithShaper(std.testing.allocator, 8, .{ .ctx = &stub, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'q', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text frame preparer accepts unified provider rasterizer" {
    const Stub = struct {
        hits: usize = 0,

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return rasterizer.placeholderRaster(allocator, req);
        }
    };
    var stub = Stub{};
    var engine = try TextFramePreparer.initWithProvider(std.testing.allocator, 8, .{ .rasterizer = .{ .ctx = &stub, .rasterize_sprite = Stub.raster } });
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 0x2500, .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
}

test "text frame preparer prepare options produce scene cursor draws" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{ .codepoint = 'c', .fg = white, .bg = black }};
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{
        .primary_face = .{ .value = 1 },
        .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    }, .{
        .scene = .{ .cursor = .{ .cell_col = 0, .cell_row = 0, .shape = .block, .color = white } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.cursor_draws.len);
    try std.testing.expectEqual(@as(u16, 8), analysis.scene.scene.cursor_draws[0].width_px);
}

test "text frame preparer prepares rich multi-codepoint cell inputs" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332, 0x0308 };
    const emoji = [_]u32{ 0x2716, 0xfe0f };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &combining, .fg = white, .bg = black },
        .{ .codepoints = &emoji, .fg = white, .bg = black, .cell_span = 2 },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 4, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u8, 2), analysis.scene.scene.sprite_draws[1].cell_span);
    try std.testing.expectEqual(@as(u16, 2), analysis.scene.scene.sprite_draws[1].width_px);
}

test "text frame preparer direct-renders pure normal cell text inputs" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const b = [_]u32{'b'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &b, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.shaped_runs);
}

test "text frame preparer keeps mixed cell text normals out of legacy path" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &combining, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 2, .rows = 1 }, .{}, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
}

test "text frame preparer marks curly underline cells complex before shaping" {
    var engine = try TextFramePreparer.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black, .underline = true, .underline_style = .curly },
    };
    var analysis = try engine.prepareCellsWithSessionOptions(&cells, .{ .cols = 2, .rows = 1 }, .{ .primary_face = .{ .value = 1 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 3), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.scene.scene.decoration_draws.len);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text frame preparer keeps icon codepoints out of the normal lane" {
    const Stub = struct {
        fn shape(_: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!shape_run.OwnedShapedRun {
            _ = text_cache;
            _ = cell_metrics;
            std.debug.assert(clusters.len >= 1);
            const glyphs = try allocator.alloc(contract.GlyphInstance, 1);
            glyphs[0] = .{
                .face_id = run.run.font.face_id,
                .glyph_id = clusters[0].first_cp,
                .cluster_index = 0,
                .x_advance_px = 16,
            };
            return .{ .allocator = allocator, .run = run, .glyphs = glyphs };
        }
    };

    var engine = try TextFramePreparer.initWithShaper(std.testing.allocator, 16, .{ .ctx = undefined, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const icon = [_]u32{0xf101};
    const blank = [_]u32{' '};
    const ascii = [_]u32{'a'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &icon, .fg = white, .bg = black },
        .{ .codepoints = &blank, .fg = white, .bg = black },
        .{ .codepoints = &ascii, .fg = white, .bg = black },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 3, .rows = 1 }, .{ .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), analysis.scene.scene.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.shaped_runs);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.glyph_groups);
}

test "text frame preparer uses ft hb source coverage for fallback" {
    const FallbackShaper = struct {
        last_face_id: u32 = 0,
        inner: shape_run.Shaper,

        fn shape(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last_face_id = run.run.font.face_id.value;
            return self.inner.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var ft_hb = ft_hb_provider.FtHbSource{ .ctx = &dummy, .has_codepoint = Backend.has };
    var text_provider = ft_hb.textProvider();
    var shaper = FallbackShaper{ .inner = text_provider.shaper };
    text_provider.shaper = .{ .ctx = &shaper, .shape_run = FallbackShaper.shape };
    var engine = try TextFramePreparer.initWithProvider(std.testing.allocator, 16, text_provider);
    defer engine.deinit();
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var analysis = try engine.prepareCellTextInputsWithSessionOptions(&inputs, .{ .cols = 1, .rows = 1 }, ft_hb.textProvider().applyToSession(.{ .faces = &faces }), .{});
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 2), shaper.last_face_id);
}
