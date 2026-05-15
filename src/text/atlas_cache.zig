
const std = @import("std");
const contract = @import("contract.zig");

pub const Entry = struct {
    key: contract.SpriteKey,
    position: contract.SpritePosition,
};

pub const ReserveResult = struct {
    position: contract.SpritePosition,
    pending: bool,
};

pub const OwnedAtlasCache = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    len: usize = 0,
    next_slot: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !OwnedAtlasCache {
        return .{ .allocator = allocator, .entries = try allocator.alloc(Entry, capacity) };
    }

    pub fn deinit(self: *OwnedAtlasCache) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn get(self: *const OwnedAtlasCache, key: contract.SpriteKey) ?contract.SpritePosition {
        for (self.entries[0..self.len]) |entry| {
            if (entry.key.value == key.value) return entry.position;
        }
        return null;
    }

    pub fn reserve(self: *OwnedAtlasCache, key: contract.SpriteKey, colored: bool) ReserveResult {
        if (self.get(key)) |pos| return .{ .position = pos, .pending = !pos.rendered };
        if (self.entries.len == 0) return .{ .position = .{ .slot = 0, .key = key, .rendered = false, .colored = colored }, .pending = true };
        const idx = if (self.len < self.entries.len) self.len else @as(usize, @intCast(self.next_slot % @as(u32, @intCast(self.entries.len))));
        const slot: u32 = @intCast(idx);
        const pos = contract.SpritePosition{ .slot = slot, .key = key, .rendered = false, .colored = colored };
        self.entries[idx] = .{ .key = key, .position = pos };
        if (self.len < self.entries.len) self.len += 1;
        self.next_slot = (slot + 1) % @as(u32, @intCast(self.entries.len));
        return .{ .position = pos, .pending = true };
    }

    pub fn reserveRequest(self: *OwnedAtlasCache, req: contract.SpriteRasterRequest) ReserveResult {
        return self.reserve(req.key, req.color_mode == .color);
    }

    pub fn markRendered(self: *OwnedAtlasCache, key: contract.SpriteKey) bool {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.key.value != key.value) continue;
            entry.position.rendered = true;
            return true;
        }
        return false;
    }
};

test "atlas cache reuses slots by sprite key" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const first = cache.reserve(.{ .value = 11 }, false);
    const second = cache.reserve(.{ .value = 11 }, false);
    const third = cache.reserve(.{ .value = 12 }, true);
    try std.testing.expectEqual(first.position.slot, second.position.slot);
    try std.testing.expectEqual(@as(u32, 1), third.position.slot);
    try std.testing.expect(third.position.colored);
}

test "atlas cache marks entries rendered after raster" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const pos = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(!pos.position.rendered);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    try std.testing.expect(cache.get(.{ .value = 99 }).?.rendered);
}

test "atlas cache requests pending sprites until marked rendered" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const first = cache.reserve(.{ .value = 99 }, false);
    const pending = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(first.pending);
    try std.testing.expect(pending.pending);
    try std.testing.expectEqual(first.position.slot, pending.position.slot);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    const committed = cache.reserve(.{ .value = 99 }, false);
    try std.testing.expect(!committed.pending);
}
