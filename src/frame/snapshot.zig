
const std = @import("std");
const pipeline = @import("pipeline.zig");
const surface = @import("surface.zig");

pub const Cell = surface.Cell;
pub const CursorInfo = surface.CursorInfo;

pub const Dirty = enum {
    none,
    partial,
    full,
};

pub const Damage = struct {
    start_row: u16,
    end_row: u16,
    start_col: u16,
    end_col: u16,
};

pub const DirtyView = struct {
    dirty: Dirty,
    damage: ?Damage,
    scroll_up_rows: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

pub const SourceView = struct {
    snapshot: *const Snapshot,
    cols: u16,
    rows: u16,
    scrollback_count: u64,
    scrollback_offset: u64,
    selection_anchor_depth: ?u64 = null,
    selection_anchor_col: ?u16 = null,
    selection_current_depth: ?u64 = null,
    selection_current_col: ?u16 = null,
    focused: bool = true,
    hover_link_id: u32 = 0,
    hover_underline_style: surface.UnderlineStyle = .straight,
    snapshot_seq: u64 = 0,
    vt_epoch: u64 = 0,
    last_alt_screen: bool = false,

    pub fn selectionActive(self: SourceView) bool {
        return self.selection_anchor_depth != null and
            self.selection_anchor_col != null and
            self.selection_current_depth != null and
            self.selection_current_col != null;
    }
};

pub const SourceResponse = struct {
    published: bool,
    queued: bool,
    damage_kind: pipeline.DamageKind,
    source_seq: u64,
    geometry_epoch: u64,
};

pub const Snapshot = struct {
    cells: std.ArrayListUnmanaged(Cell) = .empty,
    dirty_rows: std.ArrayListUnmanaged(bool) = .empty,
    dirty_cols_start: std.ArrayListUnmanaged(u16) = .empty,
    dirty_cols_end: std.ArrayListUnmanaged(u16) = .empty,
    dirty: Dirty = .none,
    damage: ?Damage = null,
    scroll_up_rows: u16 = 0,
    cursor: CursorInfo = .{},
    cols: u16 = 0,
    rows: u16 = 0,
    scroll_row: usize = 0,
    is_alternate_screen: bool = false,

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Snapshot {
        var self = Snapshot{ .cols = cols, .rows = rows };
        errdefer self.deinit(allocator);
        try self.resize(allocator, rows, cols);
        self.markFullDirty();
        return self;
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        self.dirty_rows.deinit(allocator);
        self.dirty_cols_start.deinit(allocator);
        self.dirty_cols_end.deinit(allocator);
        self.* = .{};
    }

    pub fn resize(self: *Snapshot, allocator: std.mem.Allocator, rows: u16, cols: u16) !void {
        self.rows = rows;
        self.cols = cols;
        try self.cells.resize(allocator, @as(usize, rows) * @as(usize, cols));
        try self.dirty_rows.resize(allocator, rows);
        try self.dirty_cols_start.resize(allocator, rows);
        try self.dirty_cols_end.resize(allocator, rows);
        @memset(self.cells.items, Cell{});
        self.markFullDirty();
    }

    pub fn view(self: *const Snapshot) DirtyView {
        return .{
            .dirty = self.dirty,
            .damage = self.damage,
            .scroll_up_rows = self.scroll_up_rows,
            .dirty_rows = self.dirty_rows.items,
            .dirty_cols_start = self.dirty_cols_start.items,
            .dirty_cols_end = self.dirty_cols_end.items,
        };
    }

    pub fn markFullDirty(self: *Snapshot) void {
        if (self.rows == 0 or self.cols == 0) {
            self.dirty = .none;
            self.damage = null;
            return;
        }
        self.dirty = .full;
        self.damage = .{
            .start_row = 0,
            .end_row = self.rows -| 1,
            .start_col = 0,
            .end_col = self.cols -| 1,
        };
        self.scroll_up_rows = 0;
        @memset(self.dirty_rows.items, true);
        @memset(self.dirty_cols_start.items, 0);
        @memset(self.dirty_cols_end.items, self.cols -| 1);
    }

    pub fn clearDirty(self: *Snapshot) void {
        self.dirty = .none;
        self.damage = null;
        self.scroll_up_rows = 0;
        @memset(self.dirty_rows.items, false);
        @memset(self.dirty_cols_start.items, 0);
        @memset(self.dirty_cols_end.items, 0);
    }

    pub fn copyFrom(self: *Snapshot, allocator: std.mem.Allocator, src: *const Snapshot) !void {
        if (self.rows != src.rows or self.cols != src.cols) {
            try self.resize(allocator, src.rows, src.cols);
        }
        switch (src.dirty) {
            .none => {},
            .full => @memcpy(self.cells.items, src.cells.items),
            .partial => {
                self.applyScrollUp(src.scroll_up_rows);
                self.copyDirtyCellsFrom(src);
            },
        }
        @memcpy(self.dirty_rows.items, src.dirty_rows.items);
        @memcpy(self.dirty_cols_start.items, src.dirty_cols_start.items);
        @memcpy(self.dirty_cols_end.items, src.dirty_cols_end.items);
        self.dirty = src.dirty;
        self.damage = src.damage;
        self.scroll_up_rows = src.scroll_up_rows;
        self.cursor = src.cursor;
        self.scroll_row = src.scroll_row;
        self.is_alternate_screen = src.is_alternate_screen;
    }

    fn copyDirtyCellsFrom(self: *Snapshot, src: *const Snapshot) void {
        const cols = @as(usize, src.cols);
        if (cols == 0) return;
        var row: usize = 0;
        while (row < src.dirty_rows.items.len) : (row += 1) {
            if (!src.dirty_rows.items[row]) continue;
            const start_col = @min(@as(usize, src.dirty_cols_start.items[row]), cols);
            const end_col = @min(@as(usize, src.dirty_cols_end.items[row]) +| 1, cols);
            if (start_col >= end_col) continue;
            const base = row * cols;
            @memcpy(self.cells.items[base + start_col .. base + end_col], src.cells.items[base + start_col .. base + end_col]);
        }
    }

    fn applyScrollUp(self: *Snapshot, rows_to_scroll: u16) void {
        const rows = @as(usize, self.rows);
        const cols = @as(usize, self.cols);
        const delta = @as(usize, rows_to_scroll);
        if (rows == 0 or cols == 0 or delta == 0) return;
        if (delta >= rows) {
            @memset(self.cells.items, Cell{});
            return;
        }
        const shift_cells = delta * cols;
        const keep_cells = (rows - delta) * cols;
        std.mem.copyForwards(Cell, self.cells.items[0..keep_cells], self.cells.items[shift_cells .. shift_cells + keep_cells]);
        @memset(self.cells.items[keep_cells..], Cell{});
    }

    pub fn frameData(self: *const Snapshot) surface.FrameData {
        return .{
            .viewport = .{
                .cols = self.cols,
                .rows = self.rows,
                .scroll_row = self.scroll_row,
                .is_alternate_screen = self.is_alternate_screen,
            },
            .grid = .{ .cells = self.cells.items, .cols = self.cols, .rows = self.rows },
            .cursor = self.cursor,
            .damage = .{
                .full = self.dirty == .full,
                .scroll_up_rows = self.scroll_up_rows,
                .dirty_rows = self.dirty_rows.items,
                .dirty_cols_start = self.dirty_cols_start.items,
                .dirty_cols_end = self.dirty_cols_end.items,
            },
        };
    }
};

test "frame snapshot partial copy applies scroll-up before dirty rows" {
    var src = try Snapshot.init(std.testing.allocator, 3, 2);
    defer src.deinit(std.testing.allocator);
    var dst = try Snapshot.init(std.testing.allocator, 3, 2);
    defer dst.deinit(std.testing.allocator);

    for (dst.cells.items, 0..) |*cell, idx| cell.codepoint = @intCast('a' + idx);
    src.clearDirty();
    src.scroll_up_rows = 1;
    src.dirty = .partial;
    src.dirty_rows.items[2] = true;
    src.dirty_cols_start.items[2] = 0;
    src.dirty_cols_end.items[2] = 1;
    src.cells.items[4].codepoint = 'X';
    src.cells.items[5].codepoint = 'Y';

    try dst.copyFrom(std.testing.allocator, &src);
    try std.testing.expectEqual(@as(u21, 'c'), dst.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), dst.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), dst.cells.items[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), dst.cells.items[3].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), dst.cells.items[4].codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), dst.cells.items[5].codepoint);
}
