//! Responsibility: define font resolution inputs and outputs.
//! Ownership: render-core text engine.
//! Reason: keep fallback and symbol-route semantics backend independent.

const std = @import("std");
const contract = @import("../text_contract.zig");
const pipeline = @import("../text_pipeline.zig");
const font_session = @import("font_session.zig");
const symbol_map = @import("symbol_map.zig");

pub const ResolveCellRequest = struct {
    text: contract.CellText,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
};

pub const ResolveCellResult = union(enum) {
    hit: contract.ResolvedRun,
    miss: contract.MissingGlyph,
    sprite_route: contract.SpecialSpriteRoute,
};

pub const OwnedResolvedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ResolvedRun,
    missing: []contract.MissingGlyph,
    sprite_routes: []SpriteRouteHit,
    owned: bool = true,

    pub fn deinit(self: *OwnedResolvedRuns) void {
        if (self.owned) {
            self.allocator.free(self.runs);
            self.allocator.free(self.missing);
            self.allocator.free(self.sprite_routes);
        }
        self.* = undefined;
    }
};

pub const ResolvedClusterFace = struct {
    cluster_index: u32,
    face_id: contract.FontFaceId,
};

pub const OwnedResolvedClusterFaces = struct {
    allocator: std.mem.Allocator,
    faces: []ResolvedClusterFace,
    missing: []contract.MissingGlyph,
    owned: bool = true,

    pub fn deinit(self: *OwnedResolvedClusterFaces) void {
        if (self.owned) {
            self.allocator.free(self.faces);
            self.allocator.free(self.missing);
        }
        self.* = undefined;
    }
};

pub const SpriteRouteHit = struct {
    cluster_index: u32,
    route: contract.SpecialSpriteRoute,
};

const ResolveMemoKey = struct {
    text_id: u32,
    style: contract.FontStyle,
    presentation: contract.TextPresentation,
};

const ResolveMemoValue = union(enum) {
    hit: font_session.FontFaceRecord,
    miss,
};

pub fn resolveClusters(
    allocator: std.mem.Allocator,
    session: font_session.FontSession,
    clusters: []const contract.CellCluster,
    text_cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
) !OwnedResolvedRuns {
    var runs = std.ArrayList(contract.ResolvedRun).empty;
    errdefer runs.deinit(allocator);
    var missing_list = std.ArrayList(contract.MissingGlyph).empty;
    errdefer missing_list.deinit(allocator);
    var sprite_routes = std.ArrayList(SpriteRouteHit).empty;
    errdefer sprite_routes.deinit(allocator);
    var resolve_memo = std.AutoHashMap(ResolveMemoKey, ResolveMemoValue).init(allocator);
    defer resolve_memo.deinit();

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    var idx: usize = 0;
    while (idx < clusters.len) {
        const cluster = clusters[idx];
        const route = symbol_map.builtinRoute(cluster.first_cp);
        if (route) |r| {
            try sprite_routes.append(allocator, .{ .cluster_index = @intCast(idx), .route = r });
            idx += 1;
            continue;
        }

        const text = textForCluster(text_cache, cluster);
        const face = (try resolveFaceMemoized(&resolve_memo, session, cluster, text)) orelse {
            try missing_list.append(allocator, .{
                .codepoint = cluster.first_cp,
                .style = cluster.style,
                .presentation = cluster.presentation,
                .reason = .no_fallback_face,
            });
            idx += 1;
            continue;
        };

        const start = idx;
        idx += 1;
        while (idx < clusters.len) : (idx += 1) {
            const next = clusters[idx];
            if (symbol_map.builtinRoute(next.first_cp) != null) break;
            if (next.first_cell / cols != cluster.first_cell / cols) break;
            const next_face = (try resolveFaceMemoized(&resolve_memo, session, next, textForCluster(text_cache, next))) orelse break;
            if (next_face.id.value != face.id.value or next.style != cluster.style or next.presentation != cluster.presentation) break;
        }

        try runs.append(allocator, resolvedRun(@intCast(start), @intCast(idx - start), face.id, cluster.style, cluster.presentation));
    }

    return .{
        .allocator = allocator,
        .runs = try runs.toOwnedSlice(allocator),
        .missing = try missing_list.toOwnedSlice(allocator),
        .sprite_routes = try sprite_routes.toOwnedSlice(allocator),
    };
}

pub fn resolveClusterFaces(
    allocator: std.mem.Allocator,
    session: font_session.FontSession,
    clusters: []const contract.CellCluster,
    text_cache: contract.LineTextCache,
) !OwnedResolvedClusterFaces {
    var faces = std.ArrayList(ResolvedClusterFace).empty;
    errdefer faces.deinit(allocator);
    var missing_list = std.ArrayList(contract.MissingGlyph).empty;
    errdefer missing_list.deinit(allocator);
    var resolve_memo = std.AutoHashMap(ResolveMemoKey, ResolveMemoValue).init(allocator);
    defer resolve_memo.deinit();

    for (clusters, 0..) |cluster, idx| {
        const text = textForCluster(text_cache, cluster);
        const face = (try resolveFaceMemoized(&resolve_memo, session, cluster, text)) orelse {
            try missing_list.append(allocator, .{
                .codepoint = cluster.first_cp,
                .style = cluster.style,
                .presentation = cluster.presentation,
                .reason = .no_fallback_face,
            });
            continue;
        };
        try faces.append(allocator, .{ .cluster_index = @intCast(idx), .face_id = face.id });
    }

    return .{
        .allocator = allocator,
        .faces = try faces.toOwnedSlice(allocator),
        .missing = try missing_list.toOwnedSlice(allocator),
    };
}

fn resolveFace(session: font_session.FontSession, cluster: contract.CellCluster, text: contract.CellText) ?font_session.FontFaceRecord {
    if (session.findSymbol(cluster.first_cp)) |face| return face;
    if (session.findStyle(cluster.style, cluster.presentation, text)) |face| return face;
    return session.findFallback(cluster.style, cluster.presentation, text);
}

fn resolveFaceMemoized(
    memo: *std.AutoHashMap(ResolveMemoKey, ResolveMemoValue),
    session: font_session.FontSession,
    cluster: contract.CellCluster,
    text: contract.CellText,
) !?font_session.FontFaceRecord {
    const key = ResolveMemoKey{
        .text_id = text.id.value,
        .style = cluster.style,
        .presentation = cluster.presentation,
    };
    const entry = try memo.getOrPut(key);
    if (!entry.found_existing) {
        entry.value_ptr.* = if (resolveFace(session, cluster, text)) |face|
            .{ .hit = face }
        else
            .miss;
    }
    return switch (entry.value_ptr.*) {
        .hit => |face| face,
        .miss => null,
    };
}

fn textForCluster(cache: contract.LineTextCache, cluster: contract.CellCluster) contract.CellText {
    const idx = @as(usize, @intCast(cluster.text_id.value));
    if (idx < cache.texts.len) return cache.texts[idx];
    return .{ .id = cluster.text_id, .first_cp = cluster.first_cp, .codepoints = &.{cluster.first_cp} };
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: contract.FontFaceId, style: contract.FontStyle, presentation: contract.TextPresentation) contract.ResolvedRun {
    return .{ .run = .{
        .cluster_start = cluster_start,
        .cluster_count = cluster_count,
        .font = .{
            .face_id = face_id,
            .style = style,
            .presentation = presentation,
        },
    } };
}

pub fn missing(req: ResolveCellRequest, reason: contract.MissingGlyphReason) ResolveCellResult {
    return .{ .miss = .{
        .codepoint = req.text.first_cp,
        .style = req.style,
        .presentation = req.presentation,
        .reason = reason,
    } };
}

pub fn stageForRoute(route: contract.SpecialSpriteRoute) pipeline.ResolveStage {
    return switch (route) {
        .blank => .blank,
        .box, .block, .braille, .powerline, .legacy_computing => .sprite_route,
    };
}

test "resolver groups adjacent primary clusters and separates sprite routes" {
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 2 }, .first_cell = 2, .cell_span = 1, .first_cp = 0x2500, .style = .regular, .presentation = .any },
    };
    const texts = [_]contract.CellText{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
        .{ .id = .{ .value = 2 }, .first_cp = 0x2500, .codepoints = &.{0x2500} },
    };
    var resolved = try resolveClusters(std.testing.allocator, .{}, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolved.runs.len);
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.cluster_count);
    try std.testing.expectEqual(@as(usize, 1), resolved.sprite_routes.len);
    try std.testing.expectEqual(contract.SpecialSpriteRoute.box, resolved.sprite_routes[0].route);
}

test "resolver falls back when primary cannot cover whole cell text" {
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    const session = font_session.FontSession{ .faces = &faces };
    const clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'i', .style = .regular, .presentation = .any }};
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } }};
    var resolved = try resolveClusters(std.testing.allocator, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolved.runs.len);
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
}

test "resolver uses face provider validation" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
            _ = ctx;
            if (face_id.value == 1 and text.codepoints.len > 1) return false;
            return true;
        }
    };
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var dummy: u8 = 0;
    const session = font_session.FontSession{ .faces = &faces, .provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any }};
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x', 0x0332 } }};
    var resolved = try resolveClusters(std.testing.allocator, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
}

test "resolver memoizes repeated text face validation" {
    const Provider = struct {
        calls: usize = 0,

        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (face_id.value == 1 and text.first_cp == 'x') return false;
            return true;
        }
    };

    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 1, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 0 }, .first_cell = 2, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any },
    };
    const texts = [_]contract.CellText{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{'x'} }};
    var provider = Provider{};
    const session = font_session.FontSession{ .faces = &faces, .provider = .{ .ctx = &provider, .has_cell_text = Provider.has } };

    var resolved = try resolveClusters(std.testing.allocator, session, &clusters, .{ .texts = &texts }, .{ .cols = 3, .rows = 1 });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolved.runs.len);
    try std.testing.expectEqual(@as(u32, 2), resolved.runs[0].run.font.face_id.value);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
}
