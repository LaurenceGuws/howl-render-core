//! Responsibility: define backend-neutral atlas residency vocabulary.
//! Ownership: render text engine.
//! Reason: keep atlas identity policy separate from concrete GL texture ownership.

const std = @import("std");
const contract = @import("../text_contract.zig");

pub const AtlasResidency = union(enum) {
    resident: contract.SpritePosition,
    missing: contract.SpriteKey,
};

pub fn resident(slot: u32, key: contract.SpriteKey) AtlasResidency {
    return .{ .resident = .{ .slot = slot, .key = key, .rendered = true } };
}

pub const Entry = struct {
    key: contract.SpriteKey,
    position: contract.SpritePosition,
};

pub const EnsureResult = struct {
    position: contract.SpritePosition,
    created: bool,
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

    pub fn ensure(self: *OwnedAtlasCache, key: contract.SpriteKey, colored: bool) contract.SpritePosition {
        return self.ensureDetailed(key, colored).position;
    }

    pub fn ensureDetailed(self: *OwnedAtlasCache, key: contract.SpriteKey, colored: bool) EnsureResult {
        if (self.get(key)) |pos| return .{ .position = pos, .created = !pos.rendered };
        if (self.entries.len == 0) return .{ .position = .{ .slot = 0, .key = key, .rendered = false, .colored = colored }, .created = true };
        const idx = if (self.len < self.entries.len) self.len else @as(usize, @intCast(self.next_slot % @as(u32, @intCast(self.entries.len))));
        const slot: u32 = @intCast(idx);
        const pos = contract.SpritePosition{ .slot = slot, .key = key, .rendered = false, .colored = colored };
        self.entries[idx] = .{ .key = key, .position = pos };
        if (self.len < self.entries.len) self.len += 1;
        self.next_slot = (slot + 1) % @as(u32, @intCast(self.entries.len));
        return .{ .position = pos, .created = true };
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
    const first = cache.ensure(.{ .value = 11 }, false);
    const second = cache.ensure(.{ .value = 11 }, false);
    const third = cache.ensure(.{ .value = 12 }, true);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expectEqual(@as(u32, 1), third.slot);
    try std.testing.expect(third.colored);
}

test "atlas cache marks entries rendered after raster" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const pos = cache.ensure(.{ .value = 99 }, false);
    try std.testing.expect(!pos.rendered);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    try std.testing.expect(cache.get(.{ .value = 99 }).?.rendered);
}

test "atlas cache requests pending sprites until marked rendered" {
    var cache = try OwnedAtlasCache.init(std.testing.allocator, 4);
    defer cache.deinit();
    const first = cache.ensureDetailed(.{ .value = 99 }, false);
    const pending = cache.ensureDetailed(.{ .value = 99 }, false);
    try std.testing.expect(first.created);
    try std.testing.expect(pending.created);
    try std.testing.expectEqual(first.position.slot, pending.position.slot);
    try std.testing.expect(cache.markRendered(.{ .value = 99 }));
    const committed = cache.ensureDetailed(.{ .value = 99 }, false);
    try std.testing.expect(!committed.created);
}
