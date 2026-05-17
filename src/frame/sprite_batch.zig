const std = @import("std");
const contract = @import("../text/contract.zig");
const text = @import("../text/text.zig");

pub fn buildBatches(
    comptime Batch: type,
    comptime PassKind: type,
    allocator: std.mem.Allocator,
    atlas_page_slots: u32,
    draws: []const contract.TextSpriteDraw,
    outputs: []const text.Rasterizer.RasterSpriteOutput,
) ![]Batch {
    if (draws.len == 0) return &.{};

    var batches = std.ArrayList(Batch).empty;
    errdefer batches.deinit(allocator);
    var current_pass: ?PassKind = null;
    var first_instance: u32 = 0;
    var instance_count: u32 = 0;
    for (draws, 0..) |draw, idx| {
        const pass_kind = passKindForDraw(PassKind, draw, outputs);
        if (current_pass == null) {
            current_pass = pass_kind;
            first_instance = @intCast(idx);
            instance_count = 1;
            continue;
        }
        if (current_pass.? != pass_kind) {
            try batches.append(allocator, batch(Batch, draws, atlas_page_slots, current_pass.?, first_instance, instance_count));
            current_pass = pass_kind;
            first_instance = @intCast(idx);
            instance_count = 1;
            continue;
        }
        instance_count += 1;
    }
    try batches.append(allocator, batch(Batch, draws, atlas_page_slots, current_pass.?, first_instance, instance_count));
    return try batches.toOwnedSlice(allocator);
}

fn batch(
    comptime Batch: type,
    draws: []const contract.TextSpriteDraw,
    atlas_page_slots: u32,
    pass_kind: anytype,
    first_instance: u32,
    instance_count: u32,
) Batch {
    return .{
        .atlas_page = atlasPageForSlot(draws[first_instance].sprite.slot, atlas_page_slots),
        .pass_kind = pass_kind,
        .first_instance = first_instance,
        .instance_count = instance_count,
    };
}

fn passKindForDraw(
    comptime PassKind: type,
    draw: contract.TextSpriteDraw,
    outputs: []const text.Rasterizer.RasterSpriteOutput,
) PassKind {
    for (outputs) |output| {
        if (output.key.value != draw.sprite.key.value) continue;
        return switch (output.color_mode) {
            .alpha => .alpha,
            .color => .color,
        };
    }
    return .alpha;
}

fn atlasPageForSlot(slot: u32, atlas_page_slots: u32) u16 {
    if (atlas_page_slots == 0) return 0;
    return @intCast(slot / atlas_page_slots);
}
