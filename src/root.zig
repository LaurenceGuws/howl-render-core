const std = @import("std");

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const CellGrid = struct {
    cols: u16,
    rows: u16,
};

pub const DrawCommandKind = enum {
    clear,
    glyph,
    cursor,
};

pub const DrawCommand = struct {
    kind: DrawCommandKind,
    x: u16 = 0,
    y: u16 = 0,
};

pub const RenderPlan = struct {
    pixel_size: PixelSize,
    grid: CellGrid,
    commands: []const DrawCommand = &.{},

    pub fn commandCount(self: RenderPlan) usize {
        return self.commands.len;
    }
};

test "render plan exposes command count" {
    const commands = [_]DrawCommand{
        .{ .kind = .clear },
        .{ .kind = .cursor, .x = 1, .y = 2 },
    };
    const plan = RenderPlan{
        .pixel_size = .{ .width = 800, .height = 600 },
        .grid = .{ .cols = 80, .rows = 24 },
        .commands = &commands,
    };

    try std.testing.expectEqual(@as(usize, 2), plan.commandCount());
}
