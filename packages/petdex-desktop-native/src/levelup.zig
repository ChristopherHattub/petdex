//! The level-up flourish: a hop, a gold flash and a ring of sparkles.
//!
//! Pure functions of how long ago the level-up happened, so views stay
//! stateless. Sparkles are tiny panels placed around a pet's centre.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

const app = @import("main.zig");
const AppUi = app.AppUi;

pub const duration_ms: i64 = 1800;
pub const sparkle_count = 8;

/// 0..1 progress of the flourish, or null once it is over (or never ran).
pub fn progress(now_ms: i64, started_ms: i64) ?f32 {
    const age = now_ms - started_ms;
    if (age < 0 or age >= duration_ms) return null;
    return @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(duration_ms));
}

/// True while `started_ms` still has a flourish to draw.
pub fn active(now_ms: i64, started_ms: i64) bool {
    return progress(now_ms, started_ms) != null;
}

/// Two quick hops over the first 60% of the flourish, as a lift in pixels.
pub fn hop(t: f32, size: f32) f32 {
    if (t >= 0.6) return 0;
    const phase = t / 0.6 * 2.0 * std.math.pi * 1.0;
    return -@abs(@sin(phase)) * size * 0.16;
}

/// Gold that fades with the flourish; pulses twice.
pub fn gold(t: f32) canvas.Color {
    const pulse = 0.5 + 0.5 * @cos(t * 4.0 * std.math.pi);
    const fade = 1.0 - t * 0.35;
    const alpha: u8 = @intFromFloat(std.math.clamp(120.0 + 135.0 * pulse * fade, 0.0, 255.0));
    return canvas.Color.rgba8(255, 214, 64, alpha);
}

/// Sparkles flying outward from the centre of a `size` pet. `pad` is the
/// ring's inset, which bounds how far they may travel.
pub fn sparkles(ui: *AppUi, size: f32, pad: f32, t: f32, out: *[sparkle_count]AppUi.Node) []AppUi.Node {
    const reach = size / 2 + pad - 2;
    const dot = @max(3.0, size * 0.1);
    const spread = std.math.sqrt(t);
    for (out, 0..) |*slot, i| {
        const angle = (@as(f32, @floatFromInt(i)) / sparkle_count) * 2.0 * std.math.pi + t * 1.6;
        const r = reach * (0.35 + 0.65 * spread);
        const alpha: u8 = @intFromFloat(std.math.clamp(255.0 * (1.0 - t), 0.0, 255.0));
        var star = ui.el(.panel, .{ .width = dot, .height = dot, .padding = 0 }, .{});
        star.widget.style.radius = dot / 2;
        star.widget.style.background = if (i % 2 == 0)
            canvas.Color.rgba8(255, 226, 96, alpha)
        else
            canvas.Color.rgba8(255, 255, 255, alpha);
        star.widget.frame.x = size / 2 + @cos(angle) * r - dot / 2;
        star.widget.frame.y = size / 2 + @sin(angle) * r - dot / 2;
        slot.* = star;
    }
    return out[0..];
}

test "the flourish is bounded in time and the hop never sinks below the pet" {
    try std.testing.expect(progress(0, 0) != null);
    try std.testing.expect(progress(duration_ms, 0) == null);
    try std.testing.expect(progress(-1, 0) == null);
    try std.testing.expect(progress(100, 500) == null);
    var t: f32 = 0;
    while (t <= 1.0) : (t += 0.01) try std.testing.expect(hop(t, 40) <= 0);
    try std.testing.expectEqual(@as(f32, 0), hop(0.9, 40));
}
