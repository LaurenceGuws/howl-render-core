//! Responsibility: orchestrate the mature terminal text pipeline.
//! Ownership: render text engine.
//! Reason: keep text semantics out of backend draw/upload code.

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("time.h");
});
const contract = @import("../text_contract.zig");
const pipeline = @import("../text_pipeline.zig");
const types = @import("../types.zig");
const atlas_cache = @import("atlas_cache.zig");
const cluster = @import("cluster.zig");
const font_resolver = @import("font_resolver.zig");
const font_session = @import("font_session.zig");
const ft_hb_provider = @import("ft_hb_provider.zig");
const grouping = @import("grouping.zig");
const metrics_mod = @import("metrics.zig");
const provider_mod = @import("provider.zig");
const rasterizer = @import("rasterizer.zig");
const scene_mod = @import("scene.zig");
const shape_run = @import("shape_run.zig");
const sprite_key = @import("sprite_key.zig");
const text_lane = @import("text_lane.zig");

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
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn elapsedUs(start_ns: u64) u64 {
    return @divTrunc(monotonicNs() -| start_ns, std.time.ns_per_us);
}

pub const Engine = struct {
    allocator: std.mem.Allocator,
    counters: pipeline.TextEngineCounters = .{},
    atlas: atlas_cache.OwnedAtlasCache,
    shaper: shape_run.Shaper,
    sprite_rasterizer: rasterizer.Rasterizer,
    glyph_lookup: provider_mod.LookupGlyphOp,
    glyph_raster: pipeline.RasterizeGlyphOp,
    normal_renderable: std.ArrayListUnmanaged(contract.RenderableCell) = .{ .items = &.{}, .capacity = 0 },
    normal_missing: std.ArrayListUnmanaged(contract.MissingGlyph) = .{ .items = &.{}, .capacity = 0 },
    normal_sprite_draws: std.ArrayListUnmanaged(contract.TextSpriteDraw) = .{ .items = &.{}, .capacity = 0 },
    normal_background_draws: std.ArrayListUnmanaged(contract.TextBackgroundDraw) = .{ .items = &.{}, .capacity = 0 },
    normal_clear_draws: std.ArrayListUnmanaged(contract.TextClearDraw) = .{ .items = &.{}, .capacity = 0 },
    normal_decoration_draws: std.ArrayListUnmanaged(contract.TextDecorationDraw) = .{ .items = &.{}, .capacity = 0 },
    normal_cursor_draws: std.ArrayListUnmanaged(contract.TextCursorDraw) = .{ .items = &.{}, .capacity = 0 },
    normal_raster_reqs: std.ArrayListUnmanaged(pipeline.RasterizeRequest) = .{ .items = &.{}, .capacity = 0 },

    pub fn init(allocator: std.mem.Allocator) Engine {
        return initCapacity(allocator, 4096) catch unreachable;
    }

    pub fn initCapacity(allocator: std.mem.Allocator, atlas_capacity: usize) !Engine {
        return initWithProvider(allocator, atlas_capacity, provider_mod.defaultProvider());
    }

    pub fn initWithShaper(allocator: std.mem.Allocator, atlas_capacity: usize, shaper: shape_run.Shaper) !Engine {
        return initWithProvider(allocator, atlas_capacity, .{ .shaper = shaper });
    }

    pub fn initWithProvider(allocator: std.mem.Allocator, atlas_capacity: usize, provider: provider_mod.TextProvider) !Engine {
        return .{
            .allocator = allocator,
            .atlas = try atlas_cache.OwnedAtlasCache.init(allocator, atlas_capacity),
            .shaper = provider.shaper,
            .sprite_rasterizer = provider.rasterizer,
            .glyph_lookup = provider.glyph_lookup,
            .glyph_raster = provider.glyph_raster,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.normal_raster_reqs.deinit(self.allocator);
        self.normal_cursor_draws.deinit(self.allocator);
        self.normal_decoration_draws.deinit(self.allocator);
        self.normal_clear_draws.deinit(self.allocator);
        self.normal_background_draws.deinit(self.allocator);
        self.normal_sprite_draws.deinit(self.allocator);
        self.normal_missing.deinit(self.allocator);
        self.normal_renderable.deinit(self.allocator);
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn clearAtlas(self: *Engine) void {
        self.atlas.len = 0;
        self.atlas.next_slot = 0;
    }

    pub fn analyzeCells(self: *Engine, cells: []const types.CellInput, face_id: contract.FontFaceId) !OwnedTextAnalysis {
        return self.analyzeCellsGrid(cells, .{ .cols = @intCast(@max(cells.len, 1)) }, face_id);
    }

    pub fn analyzeCellsGrid(self: *Engine, cells: []const types.CellInput, grid_metrics: contract.GridMetrics, face_id: contract.FontFaceId) !OwnedTextAnalysis {
        return self.analyzeCellsWithSession(cells, grid_metrics, .{ .primary_face = face_id });
    }

    pub fn analyzeCellsWithSession(self: *Engine, cells: []const types.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession) !OwnedTextAnalysis {
        return self.analyzeCellsWithSessionOptions(cells, grid_metrics, session, .{});
    }

    pub fn analyzeCellsWithSessionOptions(self: *Engine, cells: []const types.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: AnalysisOptions) !OwnedTextAnalysis {
        if (try self.analyzeDirectNormalCells(cells, grid_metrics, session, options)) |analysis| return analysis;
        var timings = PrepareTimings{};
        const sparse_start_ns = monotonicNs();
        var sparse = try cluster.buildSparseCellsWithDamage(self.allocator, cells, grid_metrics, options.scene.damage);
        timings.sparse_us = elapsedUs(sparse_start_ns);
        errdefer sparse.deinit();
        return self.analyzePrepared(sparse.text_cache, sparse.renderable, grid_metrics, session, options, timings);
    }

    fn analyzeDirectNormalCells(
        self: *Engine,
        cells: []const types.CellInput,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: AnalysisOptions,
    ) !?OwnedTextAnalysis {
        const damage = DirectDamage.init(options.scene.damage, grid_metrics.rows, session.metrics.cell_h_px);
        var visible_count: usize = 0;
        for (cells, 0..) |cell, idx| {
            if (cell.continuation or cell.empty) continue;
            const renderable = rawRenderableCell(cell, idx, cells);
            if (!includeDirectSpan(damage, grid_metrics, renderable.first_cell, renderable.cell_span)) continue;
            const codepoints = [_]u32{cell.codepoint};
            const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = cell.codepoint, .codepoints = &codepoints };
            if (text_lane.classifyRenderableCell(renderable, text).lane != .normal) return null;
            visible_count += 1;
        }

        try initDirectNormalBuffers(self, visible_count, cells.len, grid_metrics.rows);

        var lane_report = text_lane.LaneReport{};
        var row: u16 = 0;
        while (row < grid_metrics.rows) : (row += 1) {
            if (!directRowDirty(damage, row)) continue;
            var col: u16 = 0;
            while (col < grid_metrics.cols) {
                const idx = @as(usize, row) * @as(usize, grid_metrics.cols) + @as(usize, col);
                if (idx >= cells.len) break;
                const cell = cells[idx];
                if (cell.continuation or cell.empty) {
                    col += 1;
                    continue;
                }
                const renderable = rawRenderableCell(cell, idx, cells);
                if (!includeDirectSpan(damage, grid_metrics, renderable.first_cell, renderable.cell_span)) {
                    col += renderable.cell_span;
                    continue;
                }
                const codepoints = [_]u32{cell.codepoint};
                const text = contract.CellText{ .id = .{ .value = 0 }, .first_cp = cell.codepoint, .codepoints = &codepoints };
                std.debug.assert(text_lane.classifyRenderableCell(renderable, text).lane == .normal);
                lane_report.visible_cells += 1;
                lane_report.normal_cells += 1;
                if (!blankText(text)) lane_report.normal_clusters += 1;
                try appendDirectNormalRenderable(self, renderable, text, grid_metrics, session, &lane_report);
                col += renderable.cell_span;
            }
        }

        appendDirectBackgrounds(&self.normal_background_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
        appendDirectClears(&self.normal_clear_draws, session.metrics, grid_metrics, damage);
        appendDirectDecorations(&self.normal_decoration_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
        appendDirectCursor(&self.normal_cursor_draws, options.scene.cursor, session.metrics, damage);

        const direct = try finishDirectNormalScene(self, damage, &lane_report);

        lane_report.assertValid();
        self.counters.cell_texts += lane_report.visible_cells;
        self.counters.clusters += lane_report.normal_clusters;
        self.counters.sprite_cache_misses += @intCast(self.normal_raster_reqs.items.len);
        self.counters.sprite_cache_hits += @intCast(self.normal_sprite_draws.items.len - self.normal_raster_reqs.items.len);
        self.counters.rasterized_sprites += @intCast(direct.outputs.len);

        return .{
            .text_cache = .{ .allocator = self.allocator, .texts = &.{}, .codepoints = &.{}, .owned = false },
            .renderable = .{ .allocator = self.allocator, .cells = self.normal_renderable.items, .owned = false },
            .clusters = .{ .allocator = self.allocator, .clusters = &.{}, .owned = false },
            .runs = .{ .allocator = self.allocator, .runs = &.{}, .missing = &.{}, .sprite_routes = &.{}, .owned = false },
            .shaped_runs = .{ .allocator = self.allocator, .runs = &.{}, .owned = false },
            .font_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .sprite_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .scene = .{ .allocator = self.allocator, .scene = .{
                .cells = self.normal_renderable.items,
                .full_redraw = damage.full,
                .scroll_up_px = damage.scroll_up_px,
                .clear_draws = self.normal_clear_draws.items,
                .background_draws = self.normal_background_draws.items,
                .sprite_draws = self.normal_sprite_draws.items,
                .decoration_draws = self.normal_decoration_draws.items,
                .cursor_draws = self.normal_cursor_draws.items,
                .raster_requests = &.{},
                .missing = self.normal_missing.items,
            }, .owned = false },
            .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
            .counters = .{
                .cell_texts = lane_report.visible_cells,
                .clusters = lane_report.normal_clusters,
                .glyph_groups = 0,
                .sprite_cache_hits = @intCast(self.normal_sprite_draws.items.len - self.normal_raster_reqs.items.len),
                .sprite_cache_misses = @intCast(self.normal_raster_reqs.items.len),
                .rasterized_sprites = @intCast(direct.outputs.len),
            },
            .lane_report = lane_report,
            .timings = .{},
        };
    }

    pub fn analyzeCellsWithProvider(self: *Engine, cells: []const types.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, provider: provider_mod.TextProvider) !OwnedTextAnalysis {
        return self.analyzeCellsWithSession(cells, grid_metrics, provider.applyToSession(session));
    }

    pub fn analyzeCellTextInputs(self: *Engine, inputs: []const cluster.CellTextInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession) !OwnedTextAnalysis {
        return self.analyzeCellTextInputsOptions(inputs, grid_metrics, session, .{});
    }

    pub fn analyzeCellTextInputsOptions(self: *Engine, inputs: []const cluster.CellTextInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: AnalysisOptions) !OwnedTextAnalysis {
        if (try self.analyzeDirectNormalTextInputs(inputs, grid_metrics, session, options)) |analysis| return analysis;
        var text_cache = try cluster.buildLineTextCacheFromInputs(self.allocator, inputs);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromInputs(self.allocator, inputs, text_cache.view());
        errdefer renderable.deinit();
        return self.analyzePrepared(text_cache, renderable, grid_metrics, session, options, .{});
    }

    fn analyzePrepared(
        self: *Engine,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: AnalysisOptions,
        initial_timings: PrepareTimings,
    ) !OwnedTextAnalysis {
        var timings = initial_timings;
        var owned_text_cache = text_cache;
        errdefer owned_text_cache.deinit();
        var owned_renderable = renderable;
        errdefer owned_renderable.deinit();
        const clusters_start_ns = monotonicNs();
        var clusters = try cluster.extractClustersWithDamage(self.allocator, owned_renderable.cells, owned_text_cache.view(), grid_metrics, options.scene.damage);
        timings.clusters_us = elapsedUs(clusters_start_ns);
        errdefer clusters.deinit();
        const lane_report = text_lane.LaneReport.init(owned_text_cache.view(), owned_renderable.cells, clusters.clusters);
        return self.analyzePreparedLanes(owned_text_cache, owned_renderable, clusters, grid_metrics, session, options, lane_report, timings);
    }

    fn analyzeDirectNormalTextInputs(
        self: *Engine,
        inputs: []const cluster.CellTextInput,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: AnalysisOptions,
    ) !?OwnedTextAnalysis {
        const damage = DirectDamage.init(options.scene.damage, grid_metrics.rows, session.metrics.cell_h_px);
        var lane_report = text_lane.LaneReport{};
        var visible_count: usize = 0;
        for (inputs, 0..) |input, idx| {
            if (input.continuation) continue;
            const renderable = inputRenderableCell(input, idx, inputs);
            if (!includeDirectSpan(damage, grid_metrics, renderable.first_cell, renderable.cell_span)) continue;
            const text = inputCellText(input);
            const choice = text_lane.classifyRenderableCell(renderable, text);
            if (choice.lane != .normal) return null;
            visible_count += 1;
            lane_report.visible_cells += 1;
            lane_report.normal_cells += 1;
            if (!blankText(text)) lane_report.normal_clusters += 1;
        }

        try initDirectNormalBuffers(self, visible_count, inputs.len, grid_metrics.rows);
        for (inputs, 0..) |input, idx| {
            if (input.continuation) continue;
            const renderable = inputRenderableCell(input, idx, inputs);
            if (!includeDirectSpan(damage, grid_metrics, renderable.first_cell, renderable.cell_span)) continue;
            try appendDirectNormalRenderable(self, renderable, inputCellText(input), grid_metrics, session, &lane_report);
        }
        appendDirectBackgrounds(&self.normal_background_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
        appendDirectClears(&self.normal_clear_draws, session.metrics, grid_metrics, damage);
        appendDirectDecorations(&self.normal_decoration_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
        appendDirectCursor(&self.normal_cursor_draws, options.scene.cursor, session.metrics, damage);

        const direct = try finishDirectNormalScene(self, damage, &lane_report);
        lane_report.assertValid();
        const counters = pipeline.TextEngineCounters{
            .cell_texts = lane_report.visible_cells,
            .clusters = lane_report.normal_clusters,
            .sprite_cache_hits = @intCast(self.normal_sprite_draws.items.len - self.normal_raster_reqs.items.len),
            .sprite_cache_misses = @intCast(self.normal_raster_reqs.items.len),
            .rasterized_sprites = @intCast(direct.outputs.len),
            .missing_glyphs = self.normal_missing.items.len,
        };
        self.counters.cell_texts += counters.cell_texts;
        self.counters.clusters += counters.clusters;
        self.counters.sprite_cache_hits += counters.sprite_cache_hits;
        self.counters.sprite_cache_misses += counters.sprite_cache_misses;
        self.counters.rasterized_sprites += counters.rasterized_sprites;
        self.counters.missing_glyphs += counters.missing_glyphs;

        return .{
            .text_cache = .{ .allocator = self.allocator, .texts = &.{}, .codepoints = &.{}, .owned = false },
            .renderable = .{ .allocator = self.allocator, .cells = self.normal_renderable.items, .owned = false },
            .clusters = .{ .allocator = self.allocator, .clusters = &.{}, .owned = false },
            .runs = .{ .allocator = self.allocator, .runs = &.{}, .missing = &.{}, .sprite_routes = &.{}, .owned = false },
            .shaped_runs = .{ .allocator = self.allocator, .runs = &.{}, .owned = false },
            .font_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .sprite_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
            .scene = .{ .allocator = self.allocator, .scene = .{
                .cells = self.normal_renderable.items,
                .full_redraw = direct.damage.full,
                .scroll_up_px = direct.damage.scroll_up_px,
                .clear_draws = self.normal_clear_draws.items,
                .background_draws = self.normal_background_draws.items,
                .sprite_draws = self.normal_sprite_draws.items,
                .decoration_draws = self.normal_decoration_draws.items,
                .cursor_draws = self.normal_cursor_draws.items,
                .raster_requests = &.{},
                .missing = self.normal_missing.items,
            }, .owned = false },
            .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
            .counters = counters,
            .lane_report = lane_report,
            .timings = .{},
        };
    }

    fn analyzePreparedLanes(
        self: *Engine,
        owned_text_cache: cluster.OwnedLineTextCache,
        owned_renderable: cluster.OwnedRenderableCells,
        clusters: cluster.OwnedClusters,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: AnalysisOptions,
        lane_report: text_lane.LaneReport,
        initial_timings: PrepareTimings,
    ) !OwnedTextAnalysis {
        var final_lane_report = lane_report;
        var timings = initial_timings;
        const direct = try buildDirectNormalPrepared(self, owned_renderable.cells, owned_text_cache.view(), grid_metrics, session, options, &final_lane_report);

        if (final_lane_report.complex_cells == 0) {
            final_lane_report.assertValid();
            const counters = pipeline.TextEngineCounters{
                .cell_texts = final_lane_report.visible_cells,
                .clusters = final_lane_report.normal_clusters,
                .sprite_cache_hits = @intCast(self.normal_sprite_draws.items.len - self.normal_raster_reqs.items.len),
                .sprite_cache_misses = @intCast(self.normal_raster_reqs.items.len),
                .rasterized_sprites = @intCast(direct.outputs.len),
                .missing_glyphs = self.normal_missing.items.len,
            };
            self.counters.cell_texts += counters.cell_texts;
            self.counters.clusters += counters.clusters;
            self.counters.sprite_cache_hits += counters.sprite_cache_hits;
            self.counters.sprite_cache_misses += counters.sprite_cache_misses;
            self.counters.rasterized_sprites += counters.rasterized_sprites;
            self.counters.missing_glyphs += counters.missing_glyphs;

            return .{
                .text_cache = owned_text_cache,
                .renderable = owned_renderable,
                .clusters = clusters,
                .runs = .{ .allocator = self.allocator, .runs = &.{}, .missing = &.{}, .sprite_routes = &.{}, .owned = false },
                .shaped_runs = .{ .allocator = self.allocator, .runs = &.{}, .owned = false },
                .font_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
                .sprite_groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
                .groups = .{ .allocator = self.allocator, .groups = &.{}, .owned = false },
                .scene = .{ .allocator = self.allocator, .scene = .{
                    .cells = owned_renderable.cells,
                    .full_redraw = direct.damage.full,
                    .scroll_up_px = direct.damage.scroll_up_px,
                    .clear_draws = self.normal_clear_draws.items,
                    .background_draws = self.normal_background_draws.items,
                    .sprite_draws = self.normal_sprite_draws.items,
                    .decoration_draws = self.normal_decoration_draws.items,
                    .cursor_draws = self.normal_cursor_draws.items,
                    .raster_requests = &.{},
                    .missing = self.normal_missing.items,
                }, .owned = false },
                .raster_plan = .{ .allocator = self.allocator, .outputs = direct.outputs, .owned = direct.outputs_owned },
                .counters = counters,
                .lane_report = final_lane_report,
                .timings = timings,
            };
        }

        var complex = try selectComplexPrepared(self.allocator, owned_renderable.cells, owned_text_cache.view(), clusters.clusters, grid_metrics, DirectDamage.init(options.scene.damage, grid_metrics.rows, session.metrics.cell_h_px));
        defer complex.deinit();
        std.debug.assert(complex.cells.len == final_lane_report.complex_cells);
        std.debug.assert(complex.clusters.len == final_lane_report.complex_clusters);

        const resolve_start_ns = monotonicNs();
        var runs = try font_resolver.resolveClusters(self.allocator, session, complex.clusters, owned_text_cache.view(), grid_metrics);
        timings.resolve_us = elapsedUs(resolve_start_ns);
        errdefer runs.deinit();
        for (runs.runs) |run| final_lane_report.recordLegacyResolvedRunWithCells(owned_text_cache.view(), complex.cells, complex.clusters, run);

        const shape_start_ns = monotonicNs();
        var shaped_runs = try shape_run.shapeResolvedRunsWithShaper(self.allocator, self.shaper, runs.runs, owned_text_cache.view(), complex.clusters, session.metrics);
        timings.shape_us = elapsedUs(shape_start_ns);
        errdefer shaped_runs.deinit();
        for (shaped_runs.runs) |run| final_lane_report.recordLegacyShapedRunWithCells(owned_text_cache.view(), complex.cells, complex.clusters, run.run);

        const group_start_ns = monotonicNs();
        var font_groups = try grouping.groupShapedRuns(self.allocator, shaped_runs.runs, complex.clusters, session.metrics);
        errdefer font_groups.deinit();
        var sprite_groups = try grouping.groupSpriteRoutes(self.allocator, runs.sprite_routes, complex.clusters, session.metrics);
        errdefer sprite_groups.deinit();
        var groups = try grouping.concatGroups(self.allocator, font_groups.groups, sprite_groups.groups);
        timings.group_us = elapsedUs(group_start_ns);
        errdefer groups.deinit();
        for (groups.groups) |group| final_lane_report.recordLegacyGroup(owned_text_cache.view(), complex.cells, group);

        const scene_start_ns = monotonicNs();
        var scene = try scene_mod.buildSceneWithAtlasCacheOptions(self.allocator, complex.cells, groups.groups, runs.missing, session.metrics, grid_metrics, &self.atlas, options.scene);
        timings.scene_us = elapsedUs(scene_start_ns);
        errdefer scene.deinit();
        for (scene.scene.sprite_draws) |draw| final_lane_report.recordLegacySceneSpriteDraw(owned_text_cache.view(), complex.cells, draw);

        const raster_start_ns = monotonicNs();
        var raster_plan = try rasterizer.rasterizeRequestsWithRasterizer(self.allocator, self.sprite_rasterizer, scene.scene.raster_requests);
        timings.raster_us = elapsedUs(raster_start_ns);
        errdefer raster_plan.deinit();
        const complex_sprite_cache_hits = scene.scene.sprite_draws.len - scene.scene.raster_requests.len;

        const merged_clear_draws = try cloneSlice(contract.TextClearDraw, self.allocator, self.normal_clear_draws.items);
        errdefer self.allocator.free(merged_clear_draws);
        const merged_cursor_draws = try cloneSlice(contract.TextCursorDraw, self.allocator, self.normal_cursor_draws.items);
        errdefer self.allocator.free(merged_cursor_draws);
        const merged_background_draws = try mergeFirstCellSlices(contract.TextBackgroundDraw, self.allocator, self.normal_background_draws.items, scene.scene.background_draws);
        errdefer self.allocator.free(merged_background_draws);
        const merged_sprite_draws = try mergeFirstCellSlices(contract.TextSpriteDraw, self.allocator, self.normal_sprite_draws.items, scene.scene.sprite_draws);
        errdefer self.allocator.free(merged_sprite_draws);
        const merged_decoration_draws = try mergeFirstCellSlices(contract.TextDecorationDraw, self.allocator, self.normal_decoration_draws.items, scene.scene.decoration_draws);
        errdefer self.allocator.free(merged_decoration_draws);
        const merged_missing = try mergeSlices(contract.MissingGlyph, self.allocator, self.normal_missing.items, scene.scene.missing);
        errdefer self.allocator.free(merged_missing);
        var merged_raster_plan = try mergeRasterPlans(self.allocator, direct.outputs, direct.outputs_owned, &raster_plan);
        errdefer merged_raster_plan.deinit();

        self.allocator.free(scene.scene.clear_draws);
        self.allocator.free(scene.scene.cursor_draws);
        self.allocator.free(scene.scene.background_draws);
        self.allocator.free(scene.scene.sprite_draws);
        self.allocator.free(scene.scene.decoration_draws);
        self.allocator.free(scene.scene.missing);
        scene.scene.cells = owned_renderable.cells;
        scene.scene.full_redraw = direct.damage.full;
        scene.scene.scroll_up_px = direct.damage.scroll_up_px;
        scene.scene.clear_draws = merged_clear_draws;
        scene.scene.cursor_draws = merged_cursor_draws;
        scene.scene.background_draws = merged_background_draws;
        scene.scene.sprite_draws = merged_sprite_draws;
        scene.scene.decoration_draws = merged_decoration_draws;
        scene.scene.missing = merged_missing;

        final_lane_report.assertValid();
        var counters = pipeline.TextEngineCounters{
            .cell_texts = final_lane_report.visible_cells,
            .clusters = final_lane_report.normal_clusters + final_lane_report.complex_clusters,
            .resolved_runs = runs.runs.len,
            .shaped_runs = shaped_runs.runs.len,
            .glyph_groups = groups.groups.len,
            .sprite_cache_hits = @intCast((self.normal_sprite_draws.items.len - self.normal_raster_reqs.items.len) + complex_sprite_cache_hits),
            .sprite_cache_misses = @intCast(self.normal_raster_reqs.items.len + scene.scene.raster_requests.len),
            .rasterized_sprites = @intCast(merged_raster_plan.outputs.len),
            .missing_glyphs = scene.scene.missing.len,
        };
        for (shaped_runs.runs) |run| counters.shaped_glyphs += run.glyphs.len;
        self.counters.cell_texts += counters.cell_texts;
        self.counters.clusters += counters.clusters;
        self.counters.resolved_runs += counters.resolved_runs;
        self.counters.shaped_runs += counters.shaped_runs;
        self.counters.shaped_glyphs += counters.shaped_glyphs;
        self.counters.glyph_groups += counters.glyph_groups;
        self.counters.sprite_cache_hits += counters.sprite_cache_hits;
        self.counters.sprite_cache_misses += counters.sprite_cache_misses;
        self.counters.rasterized_sprites += counters.rasterized_sprites;
        self.counters.missing_glyphs += counters.missing_glyphs;

        return .{
            .text_cache = owned_text_cache,
            .renderable = owned_renderable,
            .clusters = clusters,
            .runs = runs,
            .shaped_runs = shaped_runs,
            .font_groups = font_groups,
            .sprite_groups = sprite_groups,
            .groups = groups,
            .scene = scene,
            .raster_plan = merged_raster_plan,
            .counters = counters,
            .lane_report = final_lane_report,
            .timings = timings,
        };
    }
};

pub const OwnedTextAnalysis = struct {
    text_cache: cluster.OwnedLineTextCache,
    renderable: cluster.OwnedRenderableCells,
    clusters: cluster.OwnedClusters,
    runs: font_resolver.OwnedResolvedRuns,
    shaped_runs: shape_run.OwnedShapedRuns,
    font_groups: grouping.OwnedGlyphGroups,
    sprite_groups: grouping.OwnedGlyphGroups,
    groups: grouping.OwnedGlyphGroups,
    scene: scene_mod.OwnedTextScene,
    raster_plan: rasterizer.OwnedRasterPlan,
    counters: pipeline.TextEngineCounters = .{},
    lane_report: text_lane.LaneReport = .{},
    timings: PrepareTimings = .{},

    pub fn deinit(self: *OwnedTextAnalysis) void {
        self.raster_plan.deinit();
        self.scene.deinit();
        self.groups.deinit();
        self.sprite_groups.deinit();
        self.font_groups.deinit();
        self.shaped_runs.deinit();
        self.runs.deinit();
        self.clusters.deinit();
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

const DirectNormalBuild = struct {
    damage: DirectDamage,
    outputs: []rasterizer.RasterSpriteOutput = &.{},
    outputs_owned: bool = false,
};

const ComplexPrepared = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    clusters: []contract.CellCluster,

    fn deinit(self: *ComplexPrepared) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.clusters);
        self.* = undefined;
    }
};

fn buildDirectNormalPrepared(
    self: *Engine,
    cells: []const contract.RenderableCell,
    text_cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    options: AnalysisOptions,
    lane_report: *text_lane.LaneReport,
) !DirectNormalBuild {
    const damage = DirectDamage.init(options.scene.damage, grid_metrics.rows, session.metrics.cell_h_px);
    var visible_count: usize = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const text = textForRenderableCell(text_cache, cell);
        if (text_lane.classifyRenderableCell(cell, text).lane == .complex) continue;
        visible_count += 1;
    }

    try initDirectNormalBuffers(self, visible_count, cells.len, grid_metrics.rows);
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const text = textForRenderableCell(text_cache, cell);
        if (text_lane.classifyRenderableCell(cell, text).lane == .complex) continue;
        try appendDirectNormalRenderable(self, cell, text, grid_metrics, session, lane_report);
    }

    appendDirectBackgrounds(&self.normal_background_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
    appendDirectClears(&self.normal_clear_draws, session.metrics, grid_metrics, damage);
    appendDirectDecorations(&self.normal_decoration_draws, self.normal_renderable.items, session.metrics, grid_metrics, damage);
    appendDirectCursor(&self.normal_cursor_draws, options.scene.cursor, session.metrics, damage);
    return finishDirectNormalScene(self, damage, lane_report);
}

fn selectComplexPrepared(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    text_cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    damage: DirectDamage,
) !ComplexPrepared {
    var complex_cell_count: usize = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        if (text_lane.classifyRenderableCell(cell, textForRenderableCell(text_cache, cell)).lane == .complex) complex_cell_count += 1;
    }

    const complex_cells = try allocator.alloc(contract.RenderableCell, complex_cell_count);
    errdefer allocator.free(complex_cells);
    var complex_cell_idx: usize = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        if (text_lane.classifyRenderableCell(cell, textForRenderableCell(text_cache, cell)).lane != .complex) continue;
        complex_cells[complex_cell_idx] = cell;
        complex_cell_idx += 1;
    }

    var complex_cluster_count: usize = 0;
    for (clusters) |cluster_value| {
        if (text_lane.classifyClusterInCells(cells, cluster_value, textForCluster(text_cache, cluster_value)).lane == .complex) complex_cluster_count += 1;
    }

    const complex_clusters = try allocator.alloc(contract.CellCluster, complex_cluster_count);
    errdefer allocator.free(complex_clusters);
    var complex_cluster_idx: usize = 0;
    for (clusters) |cluster_value| {
        if (text_lane.classifyClusterInCells(cells, cluster_value, textForCluster(text_cache, cluster_value)).lane != .complex) continue;
        complex_clusters[complex_cluster_idx] = cluster_value;
        complex_cluster_idx += 1;
    }

    return .{ .allocator = allocator, .cells = complex_cells, .clusters = complex_clusters };
}

fn initDirectNormalBuffers(self: *Engine, visible_count: usize, cell_count: usize, rows: u16) !void {
    std.debug.assert(cell_count >= visible_count);
    try self.normal_renderable.ensureTotalCapacity(self.allocator, cell_count);
    try self.normal_missing.ensureTotalCapacity(self.allocator, cell_count);
    try self.normal_sprite_draws.ensureTotalCapacity(self.allocator, cell_count);
    try self.normal_background_draws.ensureTotalCapacity(self.allocator, cell_count);
    try self.normal_clear_draws.ensureTotalCapacity(self.allocator, @as(usize, rows));
    try self.normal_decoration_draws.ensureTotalCapacity(self.allocator, cell_count * 2);
    try self.normal_cursor_draws.ensureTotalCapacity(self.allocator, 4);
    try self.normal_raster_reqs.ensureTotalCapacity(self.allocator, cell_count);
    self.normal_renderable.clearRetainingCapacity();
    self.normal_missing.clearRetainingCapacity();
    self.normal_sprite_draws.clearRetainingCapacity();
    self.normal_background_draws.clearRetainingCapacity();
    self.normal_clear_draws.clearRetainingCapacity();
    self.normal_decoration_draws.clearRetainingCapacity();
    self.normal_cursor_draws.clearRetainingCapacity();
    self.normal_raster_reqs.clearRetainingCapacity();
}

fn appendDirectNormalRenderable(
    self: *Engine,
    renderable: contract.RenderableCell,
    text: contract.CellText,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    lane_report: *text_lane.LaneReport,
) !void {
    self.normal_renderable.appendAssumeCapacity(renderable);
    if (text.first_cp == 0 or text.first_cp == '\t') return;

    const face = resolveDirectNormalFace(session, renderable, text) orelse {
        self.normal_missing.appendAssumeCapacity(.{
            .codepoint = text.first_cp,
            .style = renderable.style,
            .presentation = renderable.presentation,
            .reason = .no_fallback_face,
        });
        return;
    };

    const lookup = self.glyph_lookup.lookupGlyph(face.id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, session.metrics);
    const residency = self.atlas.ensureDetailed(key, false);
    if (residency.created) {
        self.normal_raster_reqs.appendAssumeCapacity(.{
            .face_id = face.id.value,
            .glyph_id = lookup.glyph_id,
            .atlas_key = key.value,
            .cell_metrics = session.metrics,
            .cell_span = span,
        });
    }

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const col = renderable.first_cell % cols;
    const row = renderable.first_cell / cols;
    self.normal_sprite_draws.appendAssumeCapacity(.{
        .sprite = residency.position,
        .x_px = @as(i32, @intCast(col * @as(u32, session.metrics.cell_w_px))),
        .y_px = @as(i32, @intCast(row * @as(u32, session.metrics.cell_h_px))),
        .width_px = @intCast(@as(u32, span) * @as(u32, session.metrics.cell_w_px)),
        .height_px = session.metrics.cell_h_px,
        .placement = .{ .advance_px = @max(lookup.advance_px, @as(f32, @floatFromInt(@as(u32, span) * @as(u32, session.metrics.cell_w_px)))) },
        .color = renderable.fg,
        .first_cell = renderable.first_cell,
        .cell_span = span,
    });
    lane_report.direct_normal_draws += 1;
}

fn finishDirectNormalScene(self: *Engine, damage: DirectDamage, lane_report: *text_lane.LaneReport) !DirectNormalBuild {
    var outputs: []rasterizer.RasterSpriteOutput = &.{};
    var outputs_owned = false;
    if (self.normal_raster_reqs.items.len > 0) {
        lane_report.direct_normal_raster_misses = self.normal_raster_reqs.items.len;
        outputs = try self.allocator.alloc(rasterizer.RasterSpriteOutput, self.normal_raster_reqs.items.len);
        outputs_owned = true;
        var filled: usize = 0;
        errdefer {
            for (outputs[0..filled]) |*out| out.deinit();
            self.allocator.free(outputs);
        }
        for (self.normal_raster_reqs.items, 0..) |req, idx| {
            var raster = try self.glyph_raster.rasterize(self.allocator, req);
            outputs[idx] = .{
                .allocator = raster.allocator,
                .key = .{ .value = req.atlas_key },
                .width_px = raster.width_px,
                .height_px = raster.height_px,
                .pixels = raster.alpha_mask,
            };
            raster.alpha_mask = &.{};
            filled += 1;
        }
    }
    return .{ .damage = damage, .outputs = outputs, .outputs_owned = outputs_owned };
}

fn resolveDirectNormalFace(session: font_session.FontSession, cell: contract.RenderableCell, text: contract.CellText) ?font_session.FontFaceRecord {
    return session.findStyle(cell.style, cell.presentation, text) orelse session.findFallback(cell.style, cell.presentation, text);
}

fn rawRenderableCell(cell: types.CellInput, idx: usize, cells: []const types.CellInput) contract.RenderableCell {
    return .{
        .text_id = .{ .value = 0 },
        .first_cell = @intCast(idx),
        .cell_span = inferredCellSpan(cells, idx),
        .style = .regular,
        .presentation = .any,
        .fg = cell.fg,
        .bg = cell.bg,
        .underline_color = cell.underline_color,
        .underline_style = switch (cell.underline_style) {
            .straight => .straight,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        },
        .underline = cell.underline,
        .strikethrough = cell.strikethrough,
    };
}

fn inputRenderableCell(input: cluster.CellTextInput, idx: usize, inputs: []const cluster.CellTextInput) contract.RenderableCell {
    const cps = normalizedInputCodepoints(input.codepoints);
    return .{
        .text_id = .{ .value = 0 },
        .first_cell = @intCast(idx),
        .cell_span = @max(@max(input.cell_span, 1), inferredInputCellSpan(inputs, idx)),
        .style = input.style,
        .presentation = cluster.detectPresentation(cps, input.presentation),
        .fg = input.fg,
        .bg = input.bg,
        .underline_color = input.underline_color,
        .underline_style = input.underline_style,
        .underline = input.underline,
        .strikethrough = input.strikethrough,
        .continuation = input.continuation,
    };
}

fn inputCellText(input: cluster.CellTextInput) contract.CellText {
    const cps = normalizedInputCodepoints(input.codepoints);
    return .{ .id = .{ .value = 0 }, .first_cp = cps[0], .codepoints = cps };
}

fn normalizedInputCodepoints(cps: []const u32) []const u32 {
    return if (cps.len == 0) &[_]u32{0} else cps;
}

fn textForRenderableCell(text_cache: contract.LineTextCache, cell: contract.RenderableCell) contract.CellText {
    const idx = @as(usize, @intCast(cell.text_id.value));
    std.debug.assert(idx < text_cache.texts.len);
    return text_cache.texts[idx];
}

fn textForCluster(text_cache: contract.LineTextCache, cluster_value: contract.CellCluster) contract.CellText {
    const idx = @as(usize, @intCast(cluster_value.text_id.value));
    std.debug.assert(idx < text_cache.texts.len);
    return text_cache.texts[idx];
}

fn blankText(text: contract.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

fn inferredInputCellSpan(inputs: []const cluster.CellTextInput, idx: usize) u8 {
    var span: usize = 1;
    while (idx + span < inputs.len and inputs[idx + span].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
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

const DirectDamage = struct {
    full: bool,
    scroll_up_px: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,

    fn init(damage: scene_mod.DamageInput, rows: u16, cell_h_px: u16) DirectDamage {
        const valid = !damage.full and
            damage.dirty_rows.len == @as(usize, rows) and
            damage.dirty_cols_start.len == @as(usize, rows) and
            damage.dirty_cols_end.len == @as(usize, rows);
        return .{
            .full = !valid,
            .scroll_up_px = if (valid) @intCast(@as(u32, @min(damage.scroll_up_rows, rows)) * @as(u32, cell_h_px)) else 0,
            .dirty_rows = if (valid) damage.dirty_rows else &.{},
            .dirty_cols_start = if (valid) damage.dirty_cols_start else &.{},
            .dirty_cols_end = if (valid) damage.dirty_cols_end else &.{},
        };
    }
};

fn directRowDirty(damage: DirectDamage, row: u16) bool {
    if (damage.full) return true;
    const idx = @as(usize, row);
    return idx < damage.dirty_rows.len and damage.dirty_rows[idx];
}

fn includeDirectSpan(damage: DirectDamage, grid_metrics: contract.GridMetrics, first_cell: u32, cell_span: u8) bool {
    if (damage.full) return true;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const row = @as(u16, @intCast(first_cell / cols));
    if (!directRowDirty(damage, row)) return false;
    const idx = @as(usize, row);
    const start_col = @as(u16, @intCast(first_cell % cols));
    const end_col = start_col +| (@max(cell_span, 1) - 1);
    const dirty_start = damage.dirty_cols_start[idx];
    const dirty_end = damage.dirty_cols_end[idx];
    return !(end_col < dirty_start or start_col > dirty_end);
}

fn inferredCellSpan(cells: []const types.CellInput, idx: usize) u8 {
    var span: u8 = 1;
    var next = idx + 1;
    while (next < cells.len and cells[next].continuation and span < std.math.maxInt(u8)) : (next += 1) {
        span += 1;
    }
    return span;
}

fn appendDirectBackgrounds(
    out: *std.ArrayListUnmanaged(contract.TextBackgroundDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: DirectDamage,
) void {
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    var idx: usize = 0;
    while (idx < cells.len) {
        const cell = cells[idx];
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span) or cell.bg.a == 0) {
            idx += 1;
            continue;
        }
        const row = cell.first_cell / cols;
        var span_cell_count: u32 = @max(cell.cell_span, 1);
        var span_end = cell.first_cell + span_cell_count;
        var next = idx + 1;
        while (next < cells.len) : (next += 1) {
            const other = cells[next];
            if (!includeDirectSpan(damage, grid_metrics, other.first_cell, other.cell_span)) break;
            if (!sameRgba8(cell.bg, other.bg)) break;
            if (other.first_cell / cols != row) break;
            if (other.first_cell != span_end) break;
            const other_span = @max(other.cell_span, 1);
            span_cell_count += other_span;
            span_end += other_span;
        }
        const col = cell.first_cell % cols;
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cell_count * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = cell.bg,
            .first_cell = cell.first_cell,
            .cell_span = @intCast(@min(span_cell_count, @as(u32, std.math.maxInt(u8)))),
        });
        idx = next;
    }
}

fn appendDirectClears(
    out: *std.ArrayListUnmanaged(contract.TextClearDraw),
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: DirectDamage,
) void {
    if (damage.full) return;
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    var row: usize = 0;
    while (row < grid_metrics.rows and row < damage.dirty_rows.len) : (row += 1) {
        if (!damage.dirty_rows[row]) continue;
        const start_col = @min(damage.dirty_cols_start[row], @as(u16, @intCast(cols - 1)));
        const end_col = @min(damage.dirty_cols_end[row], @as(u16, @intCast(cols - 1)));
        if (end_col < start_col) continue;
        const span_cells = @as(u32, end_col - start_col) + 1;
        out.appendAssumeCapacity(.{
            .x_px = @as(i32, @intCast(start_col)) * @as(i32, @intCast(cell_metrics.cell_w_px)),
            .y_px = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px)),
            .width_px = @intCast(span_cells * @as(u32, cell_metrics.cell_w_px)),
            .height_px = cell_metrics.cell_h_px,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .first_cell = @as(u32, @intCast(row)) * cols + @as(u32, start_col),
            .cell_span = @intCast(@min(span_cells, @as(u32, std.math.maxInt(u8)))),
        });
    }
}

fn appendDirectCursor(
    out: *std.ArrayListUnmanaged(contract.TextCursorDraw),
    cursor: ?scene_mod.CursorInput,
    cell_metrics: contract.CellMetrics,
    damage: DirectDamage,
) void {
    const cursor_value = cursor orelse return;
    if (!damage.full and !directRowDirty(damage, cursor_value.cell_row)) return;
    const base_x: i32 = @as(i32, @intCast(cursor_value.cell_col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
    const base_y: i32 = @as(i32, @intCast(cursor_value.cell_row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
    const geom = metrics_mod.cursorGeometry(cell_metrics);
    switch (cursor_value.shape) {
        .block => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color }),
        .beam => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = geom.beam_w_px, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color }),
        .underline => out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - geom.underline_h_px)), .width_px = cell_metrics.cell_w_px, .height_px = geom.underline_h_px, .color = cursor_value.color }),
        .hollow_block => {
            const stroke = geom.hollow_stroke_px;
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y + @as(i32, @intCast(cell_metrics.cell_h_px - stroke)), .width_px = cell_metrics.cell_w_px, .height_px = stroke, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x, .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color });
            out.appendAssumeCapacity(.{ .x_px = base_x + @as(i32, @intCast(cell_metrics.cell_w_px - stroke)), .y_px = base_y, .width_px = stroke, .height_px = cell_metrics.cell_h_px, .color = cursor_value.color });
        },
    }
}

fn appendDirectDecorations(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    grid_metrics: contract.GridMetrics,
    damage: DirectDamage,
) void {
    const font_metrics = metrics_mod.defaultFontMetrics(cell_metrics);
    const deco = metrics_mod.decorationGeometry(cell_metrics, font_metrics);
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    for (cells) |cell| {
        if (!cell.underline and !cell.strikethrough) continue;
        if (!includeDirectSpan(damage, grid_metrics, cell.first_cell, cell.cell_span)) continue;
        const col = cell.first_cell % cols;
        const row = cell.first_cell / cols;
        const base_x = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_metrics.cell_w_px));
        const base_y = @as(i32, @intCast(row)) * @as(i32, @intCast(cell_metrics.cell_h_px));
        const width_px: u16 = @intCast(@as(u32, @max(cell.cell_span, 1)) * @as(u32, cell_metrics.cell_w_px));
        if (cell.underline) {
            const color = if (cell.underline_color.a == 0) cell.fg else cell.underline_color;
            switch (cell.underline_style) {
                .straight => appendDirectDecoration(out, .underline, cell, base_x, base_y + deco.underline_y_px, width_px, deco.underline_h_px, color),
                .double => {
                    const gap: i32 = @max(@as(i32, @intCast(deco.underline_h_px)), 1);
                    appendDirectDecoration(out, .underline, cell, base_x, @max(base_y + deco.underline_y_px - gap - @as(i32, @intCast(deco.underline_h_px)), 0), width_px, deco.underline_h_px, color);
                    appendDirectDecoration(out, .underline, cell, base_x, base_y + deco.underline_y_px, width_px, deco.underline_h_px, color);
                },
                .dotted => {
                    const dot: u16 = @max(deco.underline_h_px, 1);
                    const step: u16 = @max(dot * 2, 2);
                    var off: u16 = 0;
                    while (off < width_px) : (off += step) {
                        appendDirectDecoration(out, .underline_dotted, cell, base_x + @as(i32, @intCast(off)), base_y + deco.underline_y_px, @min(dot, width_px - off), deco.underline_h_px, color);
                    }
                },
                .dashed => {
                    const dash: u16 = @max(width_px / 3, @as(u16, 2));
                    const step: u16 = @max(dash + 2, 3);
                    var off: u16 = 0;
                    while (off < width_px) : (off += step) {
                        appendDirectDecoration(out, .underline_dashed, cell, base_x + @as(i32, @intCast(off)), base_y + deco.underline_y_px, @min(dash, width_px - off), deco.underline_h_px, color);
                    }
                },
                .curly => unreachable,
            }
        }
        if (cell.strikethrough) appendDirectDecoration(out, .strikethrough, cell, base_x, base_y + deco.strikethrough_y_px, width_px, deco.strikethrough_h_px, cell.fg);
    }
}

fn appendDirectDecoration(
    out: *std.ArrayListUnmanaged(contract.TextDecorationDraw),
    kind: contract.DecorationKind,
    cell: contract.RenderableCell,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: contract.Rgba8,
) void {
    out.appendAssumeCapacity(.{
        .kind = kind,
        .x_px = x_px,
        .y_px = y_px,
        .width_px = width_px,
        .height_px = height_px,
        .color = color,
        .first_cell = cell.first_cell,
        .cell_span = cell.cell_span,
    });
}

fn sameRgba8(a: contract.Rgba8, b: contract.Rgba8) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

pub const AnalysisOptions = struct {
    scene: scene_mod.BuildOptions = .{},
};

test "text engine analyzes cell inputs into clusters and runs" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCells(&cells, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 0), analysis.text_cache.texts.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.renderable.cells.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.clusters.clusters.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.runs.runs.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.shaped_runs.runs.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.cell_texts);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.glyph_groups);
    try std.testing.expect(analysis.lane_report.frameFullyNormalInput());
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
    try std.testing.expect(analysis.lane_report.frameStayedOutOfLegacyPath());
}

test "text engine records sprite routes through resolver" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 0x2500, .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCells(&cells, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 0), analysis.runs.runs.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.runs.sprite_routes.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.font_groups.groups.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.sprite_groups.groups.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.groups.groups.len);
    try std.testing.expectEqual(contract.GlyphGroupKind.box_fallback, analysis.groups.groups[0].kind);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u32, 1), analysis.scene.scene.sprite_draws[1].first_cell);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.sprite_cache_misses);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.direct_normal_draws);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
}

test "text engine scene is grid positioned" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
        .{ .codepoint = 'c', .fg = white, .bg = black },
        .{ .codepoint = 'd', .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCellsGrid(&cells, .{ .cols = 2, .rows = 2 }, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 4), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(i32, 0), analysis.scene.scene.sprite_draws[2].x_px);
    try std.testing.expectEqual(@as(i32, 1), analysis.scene.scene.sprite_draws[2].y_px);
}

test "text engine rerasterizes pending atlas entries across analyses" {
    var engine = try Engine.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{.{ .codepoint = 'z', .fg = white, .bg = black }};
    var first = try engine.analyzeCells(&cells, .{ .value = 1 });
    const first_slot = first.scene.scene.sprite_draws[0].sprite.slot;
    first.deinit();
    var second = try engine.analyzeCells(&cells, .{ .value = 1 });
    defer second.deinit();
    try std.testing.expectEqual(first_slot, second.scene.scene.sprite_draws[0].sprite.slot);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), engine.atlas.len);
    try std.testing.expectEqual(@as(u64, 0), engine.counters.sprite_cache_hits);
    try std.testing.expect(!engine.atlas.get(.{ .value = second.scene.scene.sprite_draws[0].sprite.key.value }).?.rendered);
}

test "text engine rerasterizes sprites after cell metrics change" {
    var engine = try Engine.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{.{ .codepoint = 0x2588, .fg = white, .bg = black }};
    var first = try engine.analyzeCellsWithSession(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } });
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.analyzeCellsWithSession(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 16, .cell_h_px = 32, .baseline_px = 24 } });
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u16, 16), second.raster_plan.outputs[0].width_px);
    try std.testing.expectEqual(@as(u16, 32), second.raster_plan.outputs[0].height_px);
}

test "text engine rerasterizes sprites after box thickness change" {
    var engine = try Engine.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{.{ .codepoint = 0x256d, .fg = white, .bg = black }};
    var first = try engine.analyzeCellsWithSession(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 1 } });
    const first_key = first.scene.scene.sprite_draws[0].sprite.key.value;
    first.deinit();
    var second = try engine.analyzeCellsWithSession(&cells, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 }, .metrics = .{ .cell_w_px = 18, .cell_h_px = 18, .baseline_px = 14, .box_thickness_px = 3 } });
    defer second.deinit();
    try std.testing.expect(first_key != second.scene.scene.sprite_draws[0].sprite.key.value);
    try std.testing.expectEqual(@as(usize, 1), second.raster_plan.outputs.len);
}

test "text engine accepts configurable shaper" {
    const Stub = struct {
        hits: usize = 0,

        fn shape(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!shape_run.OwnedShapedRun {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return shape_run.shapeRun(allocator, run, text_cache, clusters, cell_metrics);
        }
    };

    var stub = Stub{};
    var engine = try Engine.initWithShaper(std.testing.allocator, 8, .{ .ctx = &stub, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'q', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 1, .rows = 1 }, .{ .primary_face = .{ .value = 1 } });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
    try std.testing.expectEqual(@as(usize, 1), analysis.shaped_runs.runs.len);
}

test "text engine accepts unified provider rasterizer" {
    const Stub = struct {
        hits: usize = 0,

        fn raster(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;
            return rasterizer.placeholderRaster(allocator, req);
        }
    };
    var stub = Stub{};
    var engine = try Engine.initWithProvider(std.testing.allocator, 8, .{ .rasterizer = .{ .ctx = &stub, .rasterize_sprite = Stub.raster } });
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{.{ .codepoint = 0x2500, .fg = white, .bg = black }};
    var analysis = try engine.analyzeCells(&cells, .{ .value = 1 });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
}

test "text engine analysis options produce scene cursor draws" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{.{ .codepoint = 'c', .fg = white, .bg = black }};
    var analysis = try engine.analyzeCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{
        .primary_face = .{ .value = 1 },
        .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    }, .{
        .scene = .{ .cursor = .{ .cell_col = 0, .cell_row = 0, .shape = .block, .color = white } },
    });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.scene.scene.cursor_draws.len);
    try std.testing.expectEqual(@as(u16, 8), analysis.scene.scene.cursor_draws[0].width_px);
}

test "text engine analyzes rich multi-codepoint cell inputs" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332, 0x0308 };
    const emoji = [_]u32{ 0x2716, 0xfe0f };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &combining, .fg = white, .bg = black },
        .{ .codepoints = &emoji, .fg = white, .bg = black, .cell_span = 2 },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 4, .rows = 1 }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.text_cache.texts.len);
    try std.testing.expectEqual(@as(u32, 'i'), analysis.clusters.clusters[0].first_cp);
    try std.testing.expectEqual(contract.TextPresentation.emoji, analysis.clusters.clusters[1].presentation);
    try std.testing.expectEqual(@as(u8, 2), analysis.groups.groups[1].cell_span);
    try std.testing.expectEqual(contract.GlyphGroupKind.emoji, analysis.groups.groups[1].kind);
}

test "text engine direct-renders pure normal cell text inputs" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const b = [_]u32{'b'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &b, .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 2, .rows = 1 }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 0), analysis.text_cache.texts.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.lane_report.direct_normal_draws);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
    try std.testing.expect(analysis.lane_report.frameFullyNormalInput());
}

test "text engine keeps mixed cell text normals out of legacy path" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const a = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &a, .fg = white, .bg = black },
        .{ .codepoints = &combining, .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 2, .rows = 1 }, .{});
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.direct_normal_draws);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.legacy.resolved_clusters.complex);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.legacy.shaped_clusters.complex);
}

test "text engine marks curly underline cells complex before shaping" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]types.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black, .underline = true, .underline_style = .curly },
    };
    var analysis = try engine.analyzeCellsGrid(&cells, .{ .cols = 2, .rows = 1 }, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.normal_cells);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.complex_cells);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.complex_curly_underline_cells);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.direct_normal_draws);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.legacy.resolved_clusters.complex);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.legacy.shaped_clusters.complex);
    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.legacy.grouped_groups.complex);
    try std.testing.expectEqual(@as(usize, 2), analysis.lane_report.legacy.scene_sprite_draws.complex);
}

test "text engine keeps icon codepoints out of the normal lane" {
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

    var engine = try Engine.initWithShaper(std.testing.allocator, 16, .{ .ctx = undefined, .shape_run = Stub.shape });
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const icon = [_]u32{0xf101};
    const blank = [_]u32{' '};
    const ascii = [_]u32{'a'};
    const inputs = [_]cluster.CellTextInput{
        .{ .codepoints = &icon, .fg = white, .bg = black },
        .{ .codepoints = &blank, .fg = white, .bg = black },
        .{ .codepoints = &ascii, .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 3, .rows = 1 }, .{ .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 } });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 1), analysis.lane_report.complex_icon_cells);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.resolved_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.shaped_clusters.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.grouped_groups.normal);
    try std.testing.expectEqual(@as(usize, 0), analysis.lane_report.legacy.scene_sprite_draws.normal);
    try std.testing.expectEqual(@as(usize, 1), analysis.groups.groups.len);
    try std.testing.expectEqual(contract.GlyphGroupKind.icon, analysis.groups.groups[0].kind);
    try std.testing.expectEqual(@as(u16, 16), analysis.scene.scene.sprite_draws[0].width_px);
    try std.testing.expectEqual(@as(u8, 2), analysis.scene.scene.sprite_draws[0].cell_span);
}

test "text engine uses ft hb source coverage for fallback" {
    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var ft_hb = ft_hb_provider.FtHbSource{ .ctx = &dummy, .has_codepoint = Backend.has };
    var engine = try Engine.initWithProvider(std.testing.allocator, 16, ft_hb.textProvider());
    defer engine.deinit();
    const white = types.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = types.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 1, .rows = 1 }, ft_hb.textProvider().applyToSession(.{ .faces = &faces }));
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 2), analysis.runs.runs[0].run.font.face_id.value);
}
