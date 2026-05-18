const std = @import("std");
const atlas_cache = @import("raster/cache.zig");
const cluster = @import("shape/cluster.zig");
const contract = @import("contract.zig");
const direct_scene = @import("direct_scene.zig");
const font_session = @import("font/session.zig");
const lane = @import("classify/lane.zig");
const pipeline = @import("pipeline.zig");
const provider = @import("font/provider.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("scene.zig");
const sprite_key = @import("raster/key.zig");

pub const Product = struct {
    damage: direct_scene.Damage,
    outputs: []rasterizer.RasterSpriteOutput = &.{},
    outputs_owned: bool = false,

    pub fn deinit(self: *Product, allocator: std.mem.Allocator) void {
        if (!self.outputs_owned) return;
        for (self.outputs) |*out| out.deinit();
        allocator.free(self.outputs);
        self.outputs = &.{};
        self.outputs_owned = false;
    }
};

pub const Policy = enum {
    require_all_normal,
    skip_complex,
};

pub const Source = union(enum) {
    raw_cells: []const contract.CellInput,
    inputs: []const cluster.CellTextInput,
    prepared: struct {
        cells: []const contract.RenderableCell,
        text_cache: contract.LineTextCache,
    },
};

pub const Scratch = struct {
    renderable: std.ArrayListUnmanaged(contract.RenderableCell) = .{ .items = &.{}, .capacity = 0 },
    missing: std.ArrayListUnmanaged(contract.MissingGlyph) = .{ .items = &.{}, .capacity = 0 },
    sprite_draws: std.ArrayListUnmanaged(contract.TextSpriteDraw) = .{ .items = &.{}, .capacity = 0 },
    background_draws: std.ArrayListUnmanaged(contract.TextBackgroundDraw) = .{ .items = &.{}, .capacity = 0 },
    clear_draws: std.ArrayListUnmanaged(contract.TextClearDraw) = .{ .items = &.{}, .capacity = 0 },
    decoration_draws: std.ArrayListUnmanaged(contract.TextDecorationDraw) = .{ .items = &.{}, .capacity = 0 },
    cursor_draws: std.ArrayListUnmanaged(contract.TextCursorDraw) = .{ .items = &.{}, .capacity = 0 },
    raster_reqs: std.ArrayListUnmanaged(pipeline.RasterizeRequest) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.raster_reqs.deinit(allocator);
        self.cursor_draws.deinit(allocator);
        self.decoration_draws.deinit(allocator);
        self.clear_draws.deinit(allocator);
        self.background_draws.deinit(allocator);
        self.sprite_draws.deinit(allocator);
        self.missing.deinit(allocator);
        self.renderable.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Scratch, allocator: std.mem.Allocator, visible_count: u32, cell_count: u32, rows: u16) !void {
        std.debug.assert(cell_count >= visible_count);
        try self.renderable.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.missing.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.sprite_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.background_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_draws.ensureTotalCapacity(allocator, @intCast(rows));
        try self.decoration_draws.ensureTotalCapacity(allocator, @intCast(cell_count * 2));
        try self.cursor_draws.ensureTotalCapacity(allocator, 4);
        try self.raster_reqs.ensureTotalCapacity(allocator, @intCast(cell_count));
        self.renderable.clearRetainingCapacity();
        self.missing.clearRetainingCapacity();
        self.sprite_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.clear_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.raster_reqs.clearRetainingCapacity();
    }
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    atlas: *atlas_cache.OwnedAtlasCache,
    glyph_lookup: provider.LookupGlyphOp,
    glyph_raster: pipeline.RasterizeGlyphOp,
    scratch: *Scratch,
};

pub fn prepare(
    driver: Driver,
    source: Source,
    policy: Policy,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    damage_input: scene.DamageInput,
    cursor: ?scene.CursorInput,
    lane_report: *lane.LaneReport,
) !?Product {
    const damage = direct_scene.Damage.init(damage_input, grid_metrics.rows);
    const source_len = sourceLen(source);
    const visible_count = countVisible(source, damage, grid_metrics, policy, lane_report) orelse return null;
    try driver.scratch.reset(driver.allocator, visible_count, source_len, grid_metrics.rows);
    try appendVisible(driver, source, damage, grid_metrics, session, policy, lane_report);
    direct_scene.appendBackgrounds(&driver.scratch.background_draws, driver.scratch.renderable.items, session.metrics, grid_metrics, damage);
    direct_scene.appendClears(&driver.scratch.clear_draws, session.metrics, grid_metrics, damage);
    direct_scene.appendDecorations(&driver.scratch.decoration_draws, driver.scratch.renderable.items, session.metrics, grid_metrics, damage);
    direct_scene.appendCursor(&driver.scratch.cursor_draws, cursor, session.metrics, damage);
    return try finishScene(driver, damage, lane_report);
}

pub fn counters(scratch: *const Scratch, lane_report: lane.LaneReport, direct: Product) pipeline.TextPrepareCounters {
    return .{
        .cell_texts = lane_report.visible_cells,
        .clusters = lane_report.normal_clusters,
        .sprite_cache_hits = @intCast(scratch.sprite_draws.items.len - scratch.raster_reqs.items.len),
        .sprite_cache_misses = @intCast(scratch.raster_reqs.items.len),
        .rasterized_sprites = @intCast(direct.outputs.len),
        .missing_glyphs = scratch.missing.items.len,
    };
}

const Decision = enum { include, skip, reject };

const actions = [2][6]Decision{
    .{ .include, .reject, .reject, .reject, .reject, .reject },
    .{ .include, .skip, .skip, .skip, .skip, .skip },
};

const Candidate = struct {
    item: Item,
    text: contract.CellText,
    choice: lane.LaneClass,
};

const Item = struct {
    renderable: contract.RenderableCell,
    first_cp: u32,
    borrowed_codepoints: []const u32 = &.{},
    inline_codepoints: [1]u32 = .{0},

    fn text(self: *const Item) contract.CellText {
        const codepoints = if (self.borrowed_codepoints.len > 0) self.borrowed_codepoints else self.inline_codepoints[0..1];
        return .{ .id = .{ .value = 0 }, .first_cp = self.first_cp, .codepoints = codepoints };
    }
};

fn countVisible(source: Source, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics, policy: Policy, lane_report: *lane.LaneReport) ?u32 {
    var visible_count: u32 = 0;
    var idx: u32 = 0;
    while (idx < sourceLen(source)) : (idx += 1) {
        const candidate = sourceCandidate(source, idx, damage, grid_metrics) orelse continue;
        switch (candidateDecision(policy, lane_report, candidate)) {
            .include => visible_count += 1,
            .skip => {},
            .reject => return null,
        }
    }
    return visible_count;
}

fn appendVisible(driver: Driver, source: Source, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics, session: font_session.FontSession, policy: Policy, lane_report: *lane.LaneReport) !void {
    var idx: u32 = 0;
    while (idx < sourceLen(source)) : (idx += 1) {
        const candidate = sourceCandidate(source, idx, damage, grid_metrics) orelse continue;
        switch (candidate.choice.lane) {
            .normal => try appendRenderable(driver, candidate.item.renderable, candidate.text, grid_metrics, session, lane_report),
            .complex => switch (policy) {
                .require_all_normal => unreachable,
                .skip_complex => continue,
            },
        }
    }
}

fn candidateDecision(policy: Policy, lane_report: *lane.LaneReport, candidate: Candidate) Decision {
    const class = candidate.choice.renderableClass();
    const action = actions[@intFromEnum(policy)][@intFromEnum(class)];
    if (action == .include and policy == .require_all_normal) recordLane(lane_report, candidate.text);
    return action;
}

fn sourceCandidate(source: Source, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) ?Candidate {
    const item = sourceItem(source, idx) orelse return null;
    if (!direct_scene.includeSpan(damage, grid_metrics, item.renderable.first_cell, item.renderable.cell_span)) return null;
    const text = item.text();
    return .{ .item = item, .text = text, .choice = lane.classifyRenderableCell(item.renderable, text) };
}

fn sourceLen(source: Source) u32 {
    return switch (source) {
        .raw_cells => |cells| @intCast(cells.len),
        .inputs => |inputs| @intCast(inputs.len),
        .prepared => |prepared| @intCast(prepared.cells.len),
    };
}

fn sourceItem(source: Source, idx: u32) ?Item {
    return switch (source) {
        .raw_cells => |cells| {
            const cell = cells[idx];
            if (cell.continuation or cell.empty) return null;
            return .{ .renderable = rawRenderableCell(cell, idx, cells), .first_cp = cell.codepoint, .inline_codepoints = .{cell.codepoint} };
        },
        .inputs => |inputs| {
            const input = inputs[idx];
            if (input.continuation) return null;
            const text = inputCellText(input);
            return .{ .renderable = inputRenderableCell(input, idx, inputs), .first_cp = text.first_cp, .borrowed_codepoints = text.codepoints };
        },
        .prepared => |prepared| {
            const renderable = prepared.cells[idx];
            if (renderable.continuation) return null;
            const text = textForRenderableCell(prepared.text_cache, renderable);
            return .{ .renderable = renderable, .first_cp = text.first_cp, .borrowed_codepoints = text.codepoints };
        },
    };
}

fn recordLane(lane_report: *lane.LaneReport, text: contract.CellText) void {
    lane_report.visible_cells += 1;
    lane_report.normal_cells += 1;
    if (!blankText(text)) lane_report.normal_clusters += 1;
}

fn appendRenderable(driver: Driver, renderable: contract.RenderableCell, text: contract.CellText, grid_metrics: contract.GridMetrics, session: font_session.FontSession, lane_report: *lane.LaneReport) !void {
    driver.scratch.renderable.appendAssumeCapacity(renderable);
    if (text.first_cp == 0 or text.first_cp == '\t') return;

    const face = resolveFace(session, renderable, text) orelse {
        driver.scratch.missing.appendAssumeCapacity(.{ .codepoint = text.first_cp, .style = renderable.style, .presentation = renderable.presentation, .reason = .no_fallback_face });
        return;
    };

    const lookup = driver.glyph_lookup.lookupGlyph(face.id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, session.metrics);
    const residency = driver.atlas.reserve(key, false);
    if (residency.pending) {
        driver.scratch.raster_reqs.appendAssumeCapacity(.{ .face_id = face.id.value, .glyph_id = lookup.glyph_id, .atlas_key = key.value, .cell_metrics = session.metrics, .cell_span = span });
    }

    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const col = renderable.first_cell % cols;
    const row = renderable.first_cell / cols;
    driver.scratch.sprite_draws.appendAssumeCapacity(.{
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

fn finishScene(driver: Driver, damage: direct_scene.Damage, lane_report: *lane.LaneReport) !Product {
    var outputs: []rasterizer.RasterSpriteOutput = &.{};
    var outputs_owned = false;
    if (driver.scratch.raster_reqs.items.len > 0) {
        lane_report.direct_normal_raster_misses = driver.scratch.raster_reqs.items.len;
        outputs = try driver.allocator.alloc(rasterizer.RasterSpriteOutput, driver.scratch.raster_reqs.items.len);
        outputs_owned = true;
        var filled: usize = 0;
        errdefer {
            for (outputs[0..filled]) |*out| out.deinit();
            driver.allocator.free(outputs);
        }
        for (driver.scratch.raster_reqs.items, 0..) |req, idx| {
            var raster = try driver.glyph_raster.rasterize(driver.allocator, req);
            outputs[idx] = .{ .allocator = raster.allocator, .key = .{ .value = req.atlas_key }, .width_px = raster.width_px, .height_px = raster.height_px, .pixels = raster.alpha_mask };
            raster.alpha_mask = &.{};
            filled += 1;
        }
    }
    return .{ .damage = damage, .outputs = outputs, .outputs_owned = outputs_owned };
}

fn resolveFace(session: font_session.FontSession, cell: contract.RenderableCell, text: contract.CellText) ?font_session.FontFaceRecord {
    return session.findStyle(cell.style, cell.presentation, text) orelse session.findFallback(cell.style, cell.presentation, text);
}

fn rawRenderableCell(cell: contract.CellInput, idx: u32, cells: []const contract.CellInput) contract.RenderableCell {
    return .{
        .text_id = .{ .value = 0 },
        .first_cell = idx,
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

fn inputRenderableCell(input: cluster.CellTextInput, idx: u32, inputs: []const cluster.CellTextInput) contract.RenderableCell {
    const cps = normalizedInputCodepoints(input.codepoints);
    return .{
        .text_id = .{ .value = 0 },
        .first_cell = idx,
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

fn blankText(text: contract.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

fn inferredInputCellSpan(inputs: []const cluster.CellTextInput, idx: u32) u8 {
    var span: u8 = 1;
    for (inputs[@intCast(idx + 1)..]) |input| {
        if (!input.continuation or span == std.math.maxInt(u8)) break;
        span += 1;
    }
    return span;
}

fn inferredCellSpan(cells: []const contract.CellInput, idx: u32) u8 {
    var span: u8 = 1;
    for (cells[@intCast(idx + 1)..]) |cell| {
        if (!cell.continuation or span == std.math.maxInt(u8)) break;
        span += 1;
    }
    return span;
}
