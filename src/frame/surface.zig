const std = @import("std");
const pipeline = @import("pipeline.zig");
const contract = @import("../text/contract.zig");
const text_pipeline = @import("../text/pipeline.zig");
const text = @import("../text/text.zig");

pub const SurfaceState = enum {
    idle,
    running,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const FramePixels = struct {
    render_width: i32,
    render_height: i32,
    grid_width: i32,
    grid_height: i32,

    pub fn renderWidth(self: FramePixels) u16 {
        return @intCast(@max(self.render_width, 1));
    }

    pub fn renderHeight(self: FramePixels) u16 {
        return @intCast(@max(self.render_height, 1));
    }

    pub fn gridWidth(self: FramePixels) u16 {
        return @intCast(@max(self.grid_width, 1));
    }

    pub fn gridHeight(self: FramePixels) u16 {
        return @intCast(@max(self.grid_height, 1));
    }
};

pub const GeometryResponse = struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
};

pub const Geometry = struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
};

pub const SurfaceQuery = struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    font_size_px: u16,
    epoch: u64,
};

pub const FillRect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    color: contract.Rgba8,
};

pub const GlyphQuad = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    codepoint: u21,
    fg: contract.Rgba8,
    bg: ?contract.Rgba8 = null,
};

pub const AtlasUpload = struct {
    codepoint: u21,
    width: u16,
    height: u16,
};

pub const RenderStats = struct {
    fills: usize,
    glyphs: usize,
    atlas_uploads: usize,
    has_cursor: bool,
    full_redraw: bool,
};

pub const PrepareMetrics = struct {
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    us: u64 = 0,
    surface_us: u64 = 0,
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
    glyphs: u64 = 0,
    fills: u64 = 0,
    clear_fills: u64 = 0,
    background_fills: u64 = 0,
    decoration_fills: u64 = 0,
    cursor_fills: u64 = 0,
    uploads: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,
};

pub const Color = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    value: u24 = 0,
};

pub const CellFlags = packed struct {
    continuation: bool = false,
    _pad: u7 = 0,
};

pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    underline_color_set: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    underline_color: Color = .{ .kind = .default, .value = 0 },
    underline_style: UnderlineStyle = .straight,
    attrs: CellAttrs = .{},
    link_id: u32 = 0,
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
};

pub const DamageInfo = struct {
    full: bool = true,
    scroll_up_rows: u16 = 0,
    dirty_rows: []const bool = &.{},
    dirty_cols_start: []const u16 = &.{},
    dirty_cols_end: []const u16 = &.{},
};

pub const ViewportInfo = struct {
    cols: u16,
    rows: u16,
    scroll_row: usize = 0,
    is_alternate_screen: bool = false,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
};

pub const FrameData = struct {
    viewport: ViewportInfo,
    grid: GridModel,
    cursor: CursorInfo,
    damage: DamageInfo = .{},
};

pub const SurfaceHandle = struct {
    texture_id: u32,
    width: u16,
    height: u16,
    epoch: u64,
};

pub const SurfaceLayout = struct {
    cell_px: CellSize,
    grid: GridSize,
};

pub const SurfaceExecutionReport = struct {
    texture_id: u32,
    raster_uploads_committed: usize,
    full_redraw: bool,
    scroll_up_px: u16,
    clear_draws: usize,
    background_draws: usize,
    sprite_draws: usize,
    decoration_draws: usize,
    cursor_draws: usize,
};

pub const DamageRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const SpriteBatchPassKind = enum(u8) {
    alpha,
    color,
};

pub const SpriteBatch = struct {
    atlas_page: u16,
    pass_kind: SpriteBatchPassKind,
    first_instance: u32,
    instance_count: u32,
};

pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: pipeline.RenderRequest,
    required_surface_epoch: u64,
    geometry_epoch: u64,
    atlas_page_slots: u32,
    render_px: PixelSize,
    cell_px: CellSize,
    grid: GridSize,
    surface_damage_rects: []DamageRect = &.{},
    buffer_damage_rects: []DamageRect = &.{},
    sprite_batches: []SpriteBatch = &.{},
    text_frame: text.OwnedPreparedTextFrame,
    resolve: text_pipeline.ResolveObservability = .{},
    prepare_metrics: PrepareMetrics = .{},

    pub fn deinit(self: *PreparedSurface) void {
        if (self.surface_damage_rects.len > 0) self.allocator.free(self.surface_damage_rects);
        if (self.buffer_damage_rects.len > 0) self.allocator.free(self.buffer_damage_rects);
        if (self.sprite_batches.len > 0) self.allocator.free(self.sprite_batches);
        self.text_frame.deinit();
        self.* = undefined;
    }

    pub fn damageKind(self: *const PreparedSurface) pipeline.DamageKind {
        if (self.text_frame.scene.scene.full_redraw) return .full;
        if (self.text_frame.scene.scene.scroll_up_px > 0) return .scroll;
        return .partial;
    }

    pub fn pipelineFrame(self: *const PreparedSurface) pipeline.PreparedFrame {
        const damage_kind = self.damageKind();
        const damage_base_seq = if (damage_kind == .partial or damage_kind == .scroll)
            self.request.token.damage_base_seq
        else
            0;
        return .{
            .token = .{
                .snapshot_seq = self.request.token.snapshot_seq,
                .dirty_epoch = self.request.token.dirty_epoch,
                .geometry_epoch = self.geometry_epoch,
                .damage_base_seq = damage_base_seq,
                .damage_kind = damage_kind,
            },
            .required_base_seq = damage_base_seq,
            .required_target_epoch = self.required_surface_epoch,
        };
    }
};

pub const SurfaceFeedback = struct {
    report: SurfaceExecutionReport,
    resolve: text_pipeline.ResolveObservability,
    surface: SurfaceHandle,
    metrics: RenderMetrics,
    render_us: u64,
    content_valid: bool = true,

    pub fn damageKind(self: SurfaceFeedback) pipeline.DamageKind {
        if (self.report.full_redraw) return .full;
        if (self.report.scroll_up_px > 0) return .scroll;
        return .partial;
    }
};
