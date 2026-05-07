//! Responsibility: orchestrate the mature terminal text pipeline.
//! Ownership: render-core text engine.
//! Reason: keep text semantics out of backend draw/upload code.

const std = @import("std");
const contract = @import("../text_contract.zig");
const pipeline = @import("../text_pipeline.zig");
const render_batch = @import("../render_batch.zig");
const atlas_cache = @import("atlas_cache.zig");
const cluster = @import("cluster.zig");
const font_resolver = @import("font_resolver.zig");
const font_session = @import("font_session.zig");
const ft_hb_provider = @import("ft_hb_provider.zig");
const grouping = @import("grouping.zig");
const provider_mod = @import("provider.zig");
const rasterizer = @import("rasterizer.zig");
const scene_mod = @import("scene.zig");
const shape_run = @import("shape_run.zig");

pub const Engine = struct {
    allocator: std.mem.Allocator,
    counters: pipeline.TextEngineCounters = .{},
    atlas: atlas_cache.OwnedAtlasCache,
    shaper: shape_run.Shaper,
    sprite_rasterizer: rasterizer.Rasterizer,

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
        };
    }

    pub fn deinit(self: *Engine) void {
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn prepareScene(_: *Engine, req: PrepareSceneRequest) PrepareSceneResult {
        return .{ .scene = .{
            .cells = req.cells,
            .background_draws = &.{},
            .sprite_draws = &.{},
            .decoration_draws = &.{},
            .cursor_draws = &.{},
            .missing = &.{},
        } };
    }

    pub fn analyzeLegacyCells(self: *Engine, cells: []const render_batch.CellInput, face_id: contract.FontFaceId) !OwnedTextAnalysis {
        return self.analyzeLegacyCellsGrid(cells, .{ .cols = @intCast(@max(cells.len, 1)) }, face_id);
    }

    pub fn analyzeLegacyCellsGrid(self: *Engine, cells: []const render_batch.CellInput, grid_metrics: contract.GridMetrics, face_id: contract.FontFaceId) !OwnedTextAnalysis {
        return self.analyzeLegacyCellsWithSession(cells, grid_metrics, .{ .primary_face = face_id });
    }

    pub fn analyzeLegacyCellsWithSession(self: *Engine, cells: []const render_batch.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession) !OwnedTextAnalysis {
        return self.analyzeLegacyCellsWithSessionOptions(cells, grid_metrics, session, .{});
    }

    pub fn analyzeLegacyCellsWithSessionOptions(self: *Engine, cells: []const render_batch.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: AnalysisOptions) !OwnedTextAnalysis {
        var text_cache = try cluster.buildLineTextCacheFromLegacy(self.allocator, cells);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromLegacy(self.allocator, cells, text_cache.view());
        errdefer renderable.deinit();
        return self.analyzePrepared(text_cache, renderable, grid_metrics, session, options);
    }

    pub fn analyzeLegacyCellsWithProvider(self: *Engine, cells: []const render_batch.CellInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, provider: provider_mod.TextProvider) !OwnedTextAnalysis {
        return self.analyzeLegacyCellsWithSession(cells, grid_metrics, provider.applyToSession(session));
    }

    pub fn analyzeCellTextInputs(self: *Engine, inputs: []const cluster.CellTextInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession) !OwnedTextAnalysis {
        return self.analyzeCellTextInputsOptions(inputs, grid_metrics, session, .{});
    }

    pub fn analyzeCellTextInputsOptions(self: *Engine, inputs: []const cluster.CellTextInput, grid_metrics: contract.GridMetrics, session: font_session.FontSession, options: AnalysisOptions) !OwnedTextAnalysis {
        var text_cache = try cluster.buildLineTextCacheFromInputs(self.allocator, inputs);
        errdefer text_cache.deinit();
        var renderable = try cluster.buildRenderableCellsFromInputs(self.allocator, inputs, text_cache.view());
        errdefer renderable.deinit();
        return self.analyzePrepared(text_cache, renderable, grid_metrics, session, options);
    }

    fn analyzePrepared(
        self: *Engine,
        text_cache: cluster.OwnedLineTextCache,
        renderable: cluster.OwnedRenderableCells,
        grid_metrics: contract.GridMetrics,
        session: font_session.FontSession,
        options: AnalysisOptions,
    ) !OwnedTextAnalysis {
        var owned_text_cache = text_cache;
        errdefer owned_text_cache.deinit();
        var owned_renderable = renderable;
        errdefer owned_renderable.deinit();
        var clusters = try cluster.extractClusters(self.allocator, owned_renderable.cells, owned_text_cache.view());
        errdefer clusters.deinit();
        var runs = try font_resolver.resolveClusters(self.allocator, session, clusters.clusters, owned_text_cache.view());
        errdefer runs.deinit();
        var shaped_runs = try shape_run.shapeResolvedRunsWithShaper(self.allocator, self.shaper, runs.runs, owned_text_cache.view(), clusters.clusters, session.metrics);
        errdefer shaped_runs.deinit();
        var font_groups = try grouping.groupShapedRuns(self.allocator, shaped_runs.runs, clusters.clusters, session.metrics);
        errdefer font_groups.deinit();
        var sprite_groups = try grouping.groupSpriteRoutes(self.allocator, runs.sprite_routes, clusters.clusters, session.metrics);
        errdefer sprite_groups.deinit();
        var groups = try grouping.concatGroups(self.allocator, font_groups.groups, sprite_groups.groups);
        errdefer groups.deinit();
        var scene = try scene_mod.buildSceneWithAtlasCacheOptions(self.allocator, owned_renderable.cells, groups.groups, runs.missing, session.metrics, grid_metrics, &self.atlas, options.scene);
        errdefer scene.deinit();
        var raster_plan = try rasterizer.rasterizeRequestsWithRasterizer(self.allocator, self.sprite_rasterizer, scene.scene.raster_requests);
        errdefer raster_plan.deinit();
        for (raster_plan.outputs) |output| {
            _ = self.atlas.markRendered(output.key);
        }

        var counters = pipeline.TextEngineCounters{
            .cell_texts = owned_text_cache.texts.len,
            .clusters = clusters.clusters.len,
            .resolved_runs = runs.runs.len,
            .shaped_runs = shaped_runs.runs.len,
            .glyph_groups = groups.groups.len,
            .sprite_cache_misses = @intCast(scene.scene.raster_requests.len),
            .sprite_cache_hits = @intCast(scene.scene.sprite_draws.len - scene.scene.raster_requests.len),
            .rasterized_sprites = @intCast(raster_plan.outputs.len),
            .missing_glyphs = runs.missing.len,
        };
        for (shaped_runs.runs) |run| counters.shaped_glyphs += run.glyphs.len;
        self.counters.cell_texts += counters.cell_texts;
        self.counters.clusters += counters.clusters;
        self.counters.resolved_runs += counters.resolved_runs;
        self.counters.shaped_runs += counters.shaped_runs;
        self.counters.shaped_glyphs += counters.shaped_glyphs;
        self.counters.glyph_groups += counters.glyph_groups;
        self.counters.sprite_cache_misses += counters.sprite_cache_misses;
        self.counters.sprite_cache_hits += counters.sprite_cache_hits;
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
            .raster_plan = raster_plan,
            .counters = counters,
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

pub const AnalysisOptions = struct {
    scene: scene_mod.BuildOptions = .{},
};

pub const PrepareSceneRequest = struct {
    cells: []const contract.RenderableCell,
    cell_metrics: contract.CellMetrics,
    font_metrics: contract.FontMetrics,
};

pub const PrepareSceneResult = struct {
    scene: contract.TextScene,
};

test "text engine skeleton preserves input cells" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const cell = contract.RenderableCell{
        .text_id = .{ .value = 1 },
        .first_cell = 0,
        .cell_span = 1,
        .style = .regular,
        .presentation = .text,
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const result = engine.prepareScene(.{
        .cells = &.{cell},
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
        .font_metrics = .{ .ascent_px = 10, .descent_px = 3, .line_gap_px = 1, .underline_pos_px = 12, .underline_thickness_px = 1, .strikethrough_pos_px = 6, .strikethrough_thickness_px = 1 },
    });
    try std.testing.expectEqual(@as(usize, 1), result.scene.cells.len);
    try std.testing.expectEqual(@as(usize, 0), result.scene.sprite_draws.len);
}

test "text engine analyzes legacy cells into clusters and runs" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.text_cache.texts.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.clusters.clusters.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.runs.runs.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.shaped_runs.runs.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.cell_texts);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.resolved_runs);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.glyph_groups);
}

test "text engine records sprite routes through resolver" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 0x2500, .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 1), analysis.runs.runs.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.runs.sprite_routes.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.font_groups.groups.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.sprite_groups.groups.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.groups.groups.len);
    try std.testing.expectEqual(contract.GlyphGroupKind.box_fallback, analysis.groups.groups[1].kind);
    try std.testing.expectEqual(@as(usize, 2), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(u32, 1), analysis.scene.scene.sprite_draws[1].first_cell);
    try std.testing.expectEqual(@as(u64, 2), engine.counters.sprite_cache_misses);
}

test "text engine scene is grid positioned" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{
        .{ .codepoint = 'a', .fg = white, .bg = black },
        .{ .codepoint = 'b', .fg = white, .bg = black },
        .{ .codepoint = 'c', .fg = white, .bg = black },
        .{ .codepoint = 'd', .fg = white, .bg = black },
    };
    var analysis = try engine.analyzeLegacyCellsGrid(&cells, .{ .cols = 2, .rows = 2 }, .{ .value = 1 });
    defer analysis.deinit();

    try std.testing.expectEqual(@as(usize, 4), analysis.scene.scene.sprite_draws.len);
    try std.testing.expectEqual(@as(i32, 0), analysis.scene.scene.sprite_draws[2].x_px);
    try std.testing.expectEqual(@as(i32, 1), analysis.scene.scene.sprite_draws[2].y_px);
}

test "text engine reuses atlas slots across analyses" {
    var engine = try Engine.initCapacity(std.testing.allocator, 8);
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{.{ .codepoint = 'z', .fg = white, .bg = black }};
    var first = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
    const first_slot = first.scene.scene.sprite_draws[0].sprite.slot;
    first.deinit();
    var second = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
    defer second.deinit();
    try std.testing.expectEqual(first_slot, second.scene.scene.sprite_draws[0].sprite.slot);
    try std.testing.expectEqual(@as(usize, 0), second.raster_plan.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), engine.atlas.len);
    try std.testing.expectEqual(@as(u64, 1), engine.counters.sprite_cache_hits);
    try std.testing.expect(engine.atlas.get(.{ .value = second.scene.scene.sprite_draws[0].sprite.key.value }).?.rendered);
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
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{.{ .codepoint = 'q', .fg = white, .bg = black }};
    var analysis = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
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
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{.{ .codepoint = 'r', .fg = white, .bg = black }};
    var analysis = try engine.analyzeLegacyCells(&cells, .{ .value = 1 });
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), stub.hits);
}

test "text engine analysis options produce scene cursor draws" {
    var engine = try Engine.initCapacity(std.testing.allocator, 16);
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]render_batch.CellInput{.{ .codepoint = 'c', .fg = white, .bg = black }};
    var analysis = try engine.analyzeLegacyCellsWithSessionOptions(&cells, .{ .cols = 1, .rows = 1 }, .{
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
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
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

test "text engine uses ft hb adapter coverage for fallback" {
    const Backend = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, cp: u32) bool {
            _ = ctx;
            if (face_id.value == 1) return cp >= 'a' and cp <= 'z';
            return true;
        }
    };
    var dummy: u8 = 0;
    var adapter = ft_hb_provider.Adapter{ .ctx = &dummy, .has_codepoint = Backend.has };
    var engine = try Engine.initWithProvider(std.testing.allocator, 16, adapter.textProvider());
    defer engine.deinit();
    const white = render_batch.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = render_batch.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]cluster.CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var analysis = try engine.analyzeCellTextInputs(&inputs, .{ .cols = 1, .rows = 1 }, adapter.textProvider().applyToSession(.{ .faces = &faces }));
    defer analysis.deinit();
    try std.testing.expectEqual(@as(u32, 2), analysis.runs.runs[0].run.font.face_id.value);
}
