//! Pet evolution: every pet belongs to an evolution tree.
//!
//! Traditional trees (a species turning into a later one) are listed in
//! `traditional`. Evolving never replaces a pet: reaching the step's level
//! unlocks the next species as its own collection entry while the earlier
//! one stays. Until then the later species is locked and hidden from the
//! collection. A pet that is in no traditional tree follows the default
//! tree: its own sprite, tinted purple at its first evolution and gold at
//! its second.

const std = @import("std");

/// Levels at which the default tree evolves.
pub const first_evolution_level: u32 = 5;
pub const second_evolution_level: u32 = 12;

pub const Tint = enum(u8) { none, purple, gold };

/// One step of a traditional line: `to` unlocks once `from` reaches `level`.
pub const Step = struct {
    from: []const u8,
    to: []const u8,
    level: u32,
};

/// Pokémon-style lines, by pet slug. Levels follow the shape of 16 and 36
/// scaled to this XP curve and counted in the earlier pet's own XP: level 5
/// (360 XP) and level 8 (840 XP).
pub const traditional = [_]Step{
    .{ .from = "squirtle", .to = "wartortle", .level = 5 },
    .{ .from = "wartortle", .to = "blastoise", .level = 8 },
};

/// Evolution stage for a level in the default tree: 0 base, 1, 2.
pub fn stageFor(level: u32) u8 {
    if (level >= second_evolution_level) return 2;
    if (level >= first_evolution_level) return 1;
    return 0;
}

pub fn tintFor(stage: u8) Tint {
    return switch (stage) {
        0 => .none,
        1 => .purple,
        else => .gold,
    };
}

/// Whether `slug` appears in a traditional line, as any member.
pub fn inTraditionalTree(slug: []const u8) bool {
    for (traditional) |step| {
        if (std.mem.eql(u8, step.from, slug) or std.mem.eql(u8, step.to, slug)) return true;
    }
    return false;
}

/// The step that unlocks `slug`, if it is the later half of a line.
pub fn unlockStep(slug: []const u8) ?Step {
    for (traditional) |step| {
        if (std.mem.eql(u8, step.to, slug)) return step;
    }
    return null;
}

/// Whether `slug` is still locked: it is evolved from a pet that has not
/// reached the step's level. `level_of` maps a slug to its current level.
pub fn isLocked(slug: []const u8, context: anytype, comptime level_of: fn (@TypeOf(context), []const u8) u32) bool {
    const step = unlockStep(slug) orelse return false;
    return level_of(context, step.from) < step.level;
}

/// How far a pet has evolved. Pets in a traditional line keep their own
/// sprite (the next stage is a separate entry), so they show no stage.
pub fn stageOf(slug: []const u8, level: u32) u8 {
    if (inTraditionalTree(slug)) return 0;
    return stageFor(level);
}

/// Tint the opaque pixels of RGBA `pixels`. Colour is kept as shading: the
/// tint replaces hue, while darker pixels (outlines, eyes) stay dark.
pub fn applyTint(pixels: []u8, tint: Tint) void {
    if (tint == .none) return;
    const target: [3]u32 = switch (tint) {
        .purple => .{ 164, 88, 238 },
        .gold => .{ 255, 208, 72 },
        .none => unreachable,
    };
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        if (pixels[i + 3] == 0) continue;
        const r: u32 = pixels[i];
        const g: u32 = pixels[i + 1];
        const b: u32 = pixels[i + 2];
        const lum = (r * 299 + g * 587 + b * 114) / 1000;
        // 0..255 shading; 200 is "full colour", brighter pixels clamp.
        const shade = @min(lum * 256 / 200, 300);
        const channels = [3]u32{ r, g, b };
        for (0..3) |c| {
            const tinted: u32 = @min(target[c] * shade / 256, 255);
            // 70% tint, 30% original keeps some of the sprite's own detail.
            pixels[i + c] = @intCast((tinted * 7 + channels[c] * 3) / 10);
        }
    }
}

test "the default tree evolves twice and tints purple then gold" {
    try std.testing.expectEqual(@as(u8, 0), stageFor(1));
    try std.testing.expectEqual(@as(u8, 0), stageFor(first_evolution_level - 1));
    try std.testing.expectEqual(@as(u8, 1), stageFor(first_evolution_level));
    try std.testing.expectEqual(@as(u8, 2), stageFor(second_evolution_level));
    try std.testing.expectEqual(@as(u8, 2), stageFor(500));
    try std.testing.expectEqual(Tint.none, tintFor(0));
    try std.testing.expectEqual(Tint.purple, tintFor(1));
    try std.testing.expectEqual(Tint.gold, tintFor(2));
}

test "a tinted pixel keeps its transparency and darkness" {
    var px = [_]u8{ 200, 120, 40, 255, 10, 10, 10, 255, 90, 90, 90, 0 };
    applyTint(&px, .purple);
    // Transparent pixel untouched, alpha untouched.
    try std.testing.expectEqual(@as(u8, 0), px[11]);
    try std.testing.expectEqual(@as(u8, 90), px[8]);
    try std.testing.expectEqual(@as(u8, 255), px[3]);
    // The tint moved the orange pixel towards purple (blue up, red down).
    try std.testing.expect(px[2] > 40);
    // The near-black outline stays near-black.
    try std.testing.expect(px[4] < 40 and px[5] < 40 and px[6] < 40);
    var untouched = [_]u8{ 1, 2, 3, 255 };
    applyTint(&untouched, .none);
    try std.testing.expectEqual(@as(u8, 1), untouched[0]);
}

fn testLevel(levels: []const u32, slug: []const u8) u32 {
    return if (std.mem.eql(u8, slug, "squirtle")) levels[0] else if (std.mem.eql(u8, slug, "wartortle")) levels[1] else 1;
}

test "a later species stays locked until the earlier one reaches the step level" {
    const levels = [_]u32{ traditional[0].level - 1, 1 };
    try std.testing.expect(isLocked("wartortle", @as([]const u32, &levels), testLevel));
    try std.testing.expect(isLocked("blastoise", @as([]const u32, &levels), testLevel));
    try std.testing.expect(!isLocked("squirtle", @as([]const u32, &levels), testLevel));
    try std.testing.expect(!isLocked("anything", @as([]const u32, &levels), testLevel));
    const evolved = [_]u32{ traditional[0].level, traditional[1].level };
    try std.testing.expect(!isLocked("wartortle", @as([]const u32, &evolved), testLevel));
    try std.testing.expect(!isLocked("blastoise", @as([]const u32, &evolved), testLevel));
}

test "traditional pets keep their own sprite and the default tree is unaffected" {
    try std.testing.expectEqual(@as(u8, 0), stageOf("squirtle", 99));
    try std.testing.expectEqual(@as(u8, 2), stageOf("anything", 99));
}
