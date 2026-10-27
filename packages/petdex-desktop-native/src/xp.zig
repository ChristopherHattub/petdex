//! Pet experience: every pet can level up, with no ceiling.
//!
//! Pure data and arithmetic, plus a small JSON file, so the curve and the
//! award rules are testable without a window. The rules live in main.zig
//! (who earns what, when); this file only answers "how many levels is that
//! much XP" and keeps the totals.

const std = @import("std");
const plat = @import("plat.zig");

/// One finished work cycle (red, then green) for an agent's pet.
pub const cycle_xp: u64 = 10;
/// A thread that finished and left the tab.
pub const thread_xp: u64 = 15;
/// Per full minute an agent spends working.
pub const minute_xp: u64 = 1;

/// XP from level 1 to level 2, and how much longer each next level takes.
const first_gap: u64 = 60;
const gap_growth: u64 = 20;

/// XP needed to climb from `level` to `level + 1`.
pub fn gap(level: u32) u64 {
    return first_gap + gap_growth * (@as(u64, @max(level, 1)) - 1);
}

/// Total XP at which `level` begins; level 1 starts at zero.
pub fn threshold(level: u32) u64 {
    const n: u64 = @as(u64, @max(level, 1)) - 1;
    return first_gap * n + gap_growth * (n * (n -| 1)) / 2;
}

pub const Progress = struct {
    level: u32,
    /// XP earned inside the current level.
    into: u64,
    /// XP the current level asks for in total.
    needed: u64,

    pub fn fraction(self: Progress) f32 {
        if (self.needed == 0) return 0;
        return @as(f32, @floatFromInt(self.into)) / @as(f32, @floatFromInt(self.needed));
    }
};

pub fn progress(xp: u64) Progress {
    var level: u32 = 1;
    // Estimate from the quadratic, then settle by comparison so rounding
    // can never leave the level off by one.
    const est = std.math.sqrt(@as(f64, @floatFromInt(xp)) / @as(f64, @floatFromInt(gap_growth / 2)));
    level = @intCast(@min(@as(u64, @intFromFloat(est)), 1_000_000));
    level = @max(level, 1);
    while (level > 1 and threshold(level) > xp) level -= 1;
    while (threshold(level + 1) <= xp) level += 1;
    return .{ .level = level, .into = xp - threshold(level), .needed = gap(level) };
}

pub const max_pets = 96;

pub const Entry = struct {
    name: [64]u8 = @splat(0),
    len: u8 = 0,
    xp: u64 = 0,

    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
};

pub const Store = struct {
    entries: [max_pets]Entry = @splat(.{}),
    len: usize = 0,

    pub fn xpOf(self: *const Store, name: []const u8) u64 {
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.slice(), name)) return entry.xp;
        }
        return 0;
    }

    pub fn progressOf(self: *const Store, name: []const u8) Progress {
        return progress(self.xpOf(name));
    }

    /// Credit `amount` to a pet. Returns the new level when that crossed a
    /// level boundary, so the caller can celebrate.
    pub fn add(self: *Store, name: []const u8, amount: u64) ?u32 {
        if (name.len == 0 or name.len > 64 or amount == 0) return null;
        const entry = for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, e.slice(), name)) break e;
        } else blk: {
            if (self.len == max_pets) return null;
            const fresh = &self.entries[self.len];
            self.len += 1;
            @memcpy(fresh.name[0..name.len], name);
            fresh.len = @intCast(name.len);
            fresh.xp = 0;
            break :blk fresh;
        };
        const before = progress(entry.xp).level;
        entry.xp +|= amount;
        const after = progress(entry.xp).level;
        return if (after > before) after else null;
    }
};

fn filePath(buf: []u8, home: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.petdex/pet-xp.json", .{home}) catch null;
}

/// Read the saved totals. A missing or unreadable file is simply an empty
/// store: losing XP to a corrupt file is better than refusing to start.
pub fn load(allocator: std.mem.Allocator, home: []const u8) Store {
    var store: Store = .{};
    var path_buf: [512]u8 = undefined;
    const path = filePath(&path_buf, home) orelse return store;
    const bytes = plat.readFileAlloc(allocator, path, 256 * 1024) orelse return store;
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch return store;
    if (root != .object) return store;
    const pets = root.object.get("pets") orelse return store;
    if (pets != .object) return store;
    var it = pets.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .integer or kv.value_ptr.integer < 0) continue;
        _ = store.add(kv.key_ptr.*, @intCast(kv.value_ptr.integer));
    }
    return store;
}

pub fn save(allocator: std.mem.Allocator, home: []const u8, store: *const Store) bool {
    var path_buf: [512]u8 = undefined;
    const path = filePath(&path_buf, home) orelse return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pets = std.json.ObjectMap.init(a, &.{}, &.{}) catch return false;
    for (store.entries[0..store.len]) |*entry| {
        const value: i64 = @intCast(@min(entry.xp, std.math.maxInt(i64)));
        pets.put(a, a.dupe(u8, entry.slice()) catch return false, .{ .integer = value }) catch return false;
    }
    var root = std.json.ObjectMap.init(a, &.{}, &.{}) catch return false;
    root.put(a, "pets", .{ .object = pets }) catch return false;
    const text = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }) catch return false;
    return plat.writeFile(path, text);
}

test "levels climb forever and each gap is longer than the last" {
    try std.testing.expectEqual(@as(u32, 1), progress(0).level);
    try std.testing.expectEqual(@as(u32, 1), progress(59).level);
    try std.testing.expectEqual(@as(u32, 2), progress(60).level);
    try std.testing.expectEqual(@as(u64, 80), gap(2));
    try std.testing.expectEqual(@as(u64, 140), threshold(3));
    var level: u32 = 1;
    while (level < 2000) : (level += 1) {
        try std.testing.expect(gap(level + 1) > gap(level));
        try std.testing.expectEqual(threshold(level) + gap(level), threshold(level + 1));
        // The level is found exactly at each boundary and one short of it.
        try std.testing.expectEqual(level + 1, progress(threshold(level + 1)).level);
        try std.testing.expectEqual(level, progress(threshold(level + 1) - 1).level);
    }
    const mid = progress(100);
    try std.testing.expectEqual(@as(u32, 2), mid.level);
    try std.testing.expectEqual(@as(u64, 40), mid.into);
    try std.testing.expectEqual(@as(u64, 80), mid.needed);
    try std.testing.expectEqual(@as(f32, 0.5), mid.fraction());
}

test "adding xp reports only real level ups" {
    var store: Store = .{};
    try std.testing.expect(store.add("boba", 10) == null);
    try std.testing.expect(store.add("boba", 49) == null);
    try std.testing.expectEqual(@as(?u32, 2), store.add("boba", 1));
    try std.testing.expectEqual(@as(u64, 60), store.xpOf("boba"));
    try std.testing.expectEqual(@as(u64, 0), store.xpOf("ghost-ai"));
    try std.testing.expect(store.add("", 5) == null);
}

test "xp survives a save and load" {
    const home = ".zig-cache/petdex-xp-test";
    defer _ = plat.deleteTree(home);
    plat.makeDir(home ++ "/.petdex");
    var store: Store = .{};
    _ = store.add("boba", 250);
    _ = store.add("ghost-ai", 7);
    try std.testing.expect(save(std.testing.allocator, home, &store));
    const loaded = load(std.testing.allocator, home);
    try std.testing.expectEqual(@as(u64, 250), loaded.xpOf("boba"));
    try std.testing.expectEqual(@as(u64, 7), loaded.xpOf("ghost-ai"));
    // A missing file is an empty store.
    try std.testing.expectEqual(@as(usize, 0), load(std.testing.allocator, home ++ "/nowhere").len);
}
