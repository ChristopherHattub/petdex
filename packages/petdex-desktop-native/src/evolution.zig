//! Pet evolution: every pet belongs to an evolution tree.
//!
//! Traditional trees (a species turning into a later one at a level) are
//! listed in `traditional`; it starts empty and grows as real evolution
//! lines are added to the collection. A pet that is in no traditional tree
//! follows the default tree: its own sprite, tinted purple at its first
//! evolution and gold at its second.

const std = @import("std");

/// Levels at which the default tree evolves.
pub const first_evolution_level: u32 = 5;
pub const second_evolution_level: u32 = 12;

pub const Tint = enum(u8) { none, purple, gold };

/// One step of a traditional line: `from` becomes `to` at `level`.
pub const Step = struct {
    from: []const u8,
    to: []const u8,
    level: u32,
};

/// Pokémon-style lines, by pet slug. Add entries as those pets are added to
/// the collection, e.g. `.{ .from = "charmander", .to = "charmeleon", .level = 16 }`.
pub const traditional = [_]Step{};

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

/// The species a pet has become at `level`, following its traditional line
/// as far as the level allows. Null when it has not evolved (or is not in
/// a traditional tree).
pub fn traditionalForm(slug: []const u8, level: u32) ?[]const u8 {
    var current = slug;
    var moved = false;
    var hops: usize = 0;
    while (hops < traditional.len) : (hops += 1) {
        var advanced = false;
        for (traditional) |step| {
            if (std.mem.eql(u8, step.from, current) and level >= step.level) {
                current = step.to;
                moved = true;
                advanced = true;
                break;
            }
        }
        if (!advanced) break;
    }
    return if (moved) current else null;
}

/// How far a pet has evolved, in whichever tree it belongs to.
pub fn stageOf(slug: []const u8, level: u32) u8 {
    if (inTraditionalTree(slug)) {
        const form = traditionalForm(slug, level) orelse return 0;
        return if (std.mem.eql(u8, form, slug)) 0 else 1;
    }
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

test "traditional lines follow the level" {
    try std.testing.expect(traditionalForm("anything", 99) == null);
    try std.testing.expect(!inTraditionalTree("anything"));
}
