//! Agent rail: a translucent tab beside the pet with one logo per live
//! agent session, ringed by what that session is doing right now.
//!
//!   red    working (the agent is running a turn)
//!   yellow waiting (a permission prompt or question is open)
//!   green  done    (the turn ended, successfully or not)
//!   grey   idle    (session known, no turn yet)
//!
//! The mailbox already keeps one bubble per conversation with a reconciled
//! `SessionStatus`, so the rail is a read of that set, not a new feed. It
//! keeps its own copy because bubbles can be hidden (bubbles off, focus
//! mode) or expired by the bubble lifetime, and a finished agent should
//! still show green for a while after its card is gone.
//!
//! Kept in its own file, like settings_view.zig, so main.zig only gains a
//! few call sites and rebases onto upstream stay small.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const hook_server = @import("hook_server.zig");

const app = @import("main.zig");
const AppUi = app.AppUi;

pub const window_label = "agent-rail";
pub const canvas_label = "agent-rail-canvas";

pub const max_entries = hook_server.max_bubbles;

/// How long a finished or idle agent keeps its ring before it drops off.
pub const done_linger_ms: i64 = 10 * 60 * 1000;

/// Linux places companion windows as compositor popups (see the bubble's
/// `popup_parent` path); the rail has no popup anchor yet, so it stays off
/// there rather than floating at an arbitrary origin.
pub const platform_supported = builtin.target.os.tag != .linux;

pub const Status = enum(u8) {
    idle,
    working,
    waiting,
    done,

    pub fn fromSession(status: hook_server.SessionStatus, busy: bool) Status {
        return switch (status) {
            .running => .working,
            .needs_input => .waiting,
            .completed, .failed => .done,
            .idle => if (busy) .working else .idle,
        };
    }

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .waiting => "waiting for you",
            .done => "done",
        };
    }

    /// Settled states age out; active ones stay until they change.
    fn settles(self: Status) bool {
        return self == .done or self == .idle;
    }
};

pub const Entry = struct {
    session: [hook_server.bubble_session_capacity]u8 = @splat(0),
    session_len: usize = 0,
    agent: [24]u8 = @splat(0),
    agent_len: usize = 0,
    hostname: [64]u8 = @splat(0),
    hostname_len: usize = 0,
    remote: bool = false,
    status: Status = .idle,
    /// When `status` last changed. Drives the linger for settled entries.
    since_ms: i64 = 0,

    pub fn agentSlice(self: *const Entry) []const u8 {
        return self.agent[0..self.agent_len];
    }
    pub fn sessionSlice(self: *const Entry) []const u8 {
        return self.session[0..self.session_len];
    }
    pub fn identity(self: *const Entry) hook_server.BubbleIdentity {
        return .{
            .conversation_key = self.sessionSlice(),
            .agent = self.agentSlice(),
            .hostname = self.hostname[0..self.hostname_len],
            .remote = self.remote,
        };
    }
};

/// One status change, reported by `reconcile` so a notifier can react to
/// exactly the edges the rail shows instead of re-deriving them.
pub const Transition = struct {
    index: usize,
    from: ?Status,
    to: Status,
};

pub const Model = struct {
    entries: [max_entries]Entry = @splat(.{}),
    len: usize = 0,
    /// The rail sits left of the pet once the right side ran into the
    /// screen edge. `flip_x` is where that happened, for hysteresis.
    on_left: bool = false,
    flip_x: f64 = 0,
    window_w: f32 = 0,
    window_h: f32 = 0,

    pub fn slice(self: *const Model) []const Entry {
        return self.entries[0..self.len];
    }
};

fn copyInto(dest: []u8, dest_len: *usize, source: []const u8) void {
    const n = @min(dest.len, source.len);
    @memcpy(dest[0..n], source[0..n]);
    @memset(dest[n..], 0);
    dest_len.* = n;
}

/// Fold a freshly drained bubble set into the rail. Entries keep their
/// order across drains so icons do not reshuffle. A session the mailbox
/// dropped while active is treated as finished: it lingers green and then
/// ages out, rather than spinning red forever.
///
/// Returns the transitions in `out`, newest state per entry.
pub fn reconcile(model: *Model, bubbles: []const hook_server.Bubble, now_ms: i64, out: *[max_entries]Transition) usize {
    var seen: [max_entries]bool = @splat(false);
    var transitions: usize = 0;

    for (bubbles) |*bubble| {
        // The anonymous compatibility slot has no stable identity to ring.
        if (bubble.agent_len == 0) continue;
        const next = Status.fromSession(bubble.status, bubble.busy);
        const index = indexOf(model, bubble.identity()) orelse blk: {
            if (model.len == max_entries) {
                if (!evictOldestSettled(model, &seen)) continue;
            }
            var entry: Entry = .{};
            copyInto(&entry.session, &entry.session_len, bubble.sessionSlice());
            copyInto(&entry.agent, &entry.agent_len, bubble.agent[0..bubble.agent_len]);
            copyInto(&entry.hostname, &entry.hostname_len, bubble.hostnameSlice());
            entry.remote = bubble.remote;
            entry.status = next;
            entry.since_ms = now_ms;
            model.entries[model.len] = entry;
            model.len += 1;
            if (transitions < max_entries) {
                out[transitions] = .{ .index = model.len - 1, .from = null, .to = next };
                transitions += 1;
            }
            break :blk model.len - 1;
        };
        seen[index] = true;
        const entry = &model.entries[index];
        if (entry.status != next) {
            if (transitions < max_entries) {
                out[transitions] = .{ .index = index, .from = entry.status, .to = next };
                transitions += 1;
            }
            entry.status = next;
            entry.since_ms = now_ms;
        }
    }

    for (model.entries[0..model.len], 0..) |*entry, index| {
        if (seen[index] or entry.status.settles()) continue;
        if (transitions < max_entries) {
            out[transitions] = .{ .index = index, .from = entry.status, .to = .done };
            transitions += 1;
        }
        entry.status = .done;
        entry.since_ms = now_ms;
    }
    return transitions;
}

fn indexOf(model: *const Model, identity: hook_server.BubbleIdentity) ?usize {
    for (model.entries[0..model.len], 0..) |*entry, index| {
        if (entry.identity().matches(identity)) return index;
    }
    return null;
}

fn removeAt(model: *Model, index: usize, seen: ?*[max_entries]bool) void {
    var i = index;
    while (i + 1 < model.len) : (i += 1) {
        model.entries[i] = model.entries[i + 1];
        if (seen) |s| s[i] = s[i + 1];
    }
    model.len -= 1;
    model.entries[model.len] = .{};
    if (seen) |s| s[model.len] = false;
}

fn evictOldestSettled(model: *Model, seen: *[max_entries]bool) bool {
    var oldest: ?usize = null;
    for (model.entries[0..model.len], 0..) |*entry, index| {
        if (seen[index] or !entry.status.settles()) continue;
        if (oldest == null or entry.since_ms < model.entries[oldest.?].since_ms) oldest = index;
    }
    const index = oldest orelse return false;
    removeAt(model, index, seen);
    return true;
}

/// Drop settled entries past their linger. Returns true when the set
/// changed, so the caller knows the window size may have too.
pub fn expire(model: *Model, now_ms: i64) bool {
    var changed = false;
    var index: usize = 0;
    while (index < model.len) {
        const entry = &model.entries[index];
        if (entry.status.settles() and now_ms - entry.since_ms >= done_linger_ms) {
            removeAt(model, index, null);
            changed = true;
            continue;
        }
        index += 1;
    }
    return changed;
}

// ------------------------------------------------------------- geometry

const icon_px: f32 = 26;
const ring_px: f32 = 2.5;
const ring_gap: f32 = 2;
const cell_px: f32 = icon_px + (ring_px + ring_gap) * 2;
const tab_padding: f32 = 7;
const tab_gap: f32 = 6;
const tab_radius: f32 = 12;
/// Space between the pet's edge and the tab.
pub const pet_gap: f64 = 4;
/// How far the pet must travel back from the edge before the rail
/// returns to its right side.
const flip_hysteresis: f64 = 48;

pub fn windowWidth() f32 {
    return cell_px + tab_padding * 2;
}

pub fn windowHeight(count: usize) f32 {
    const n: f32 = @floatFromInt(@max(count, 1));
    return n * cell_px + (n - 1) * tab_gap + tab_padding * 2;
}

pub fn active(model: *const Model) bool {
    return platform_supported and model.len > 0;
}

/// Vertically centered on the pet, on whichever side currently fits.
pub fn wantOrigin(model: *const Model, pet_x: f64, pet_y: f64, pet_w: f64, pet_h: f64) struct { x: f64, y: f64 } {
    const w: f64 = windowWidth();
    const h: f64 = windowHeight(model.len);
    const x = if (model.on_left) pet_x - w - pet_gap else pet_x + pet_w + pet_gap;
    return .{ .x = x, .y = pet_y + (pet_h - h) / 2.0 };
}

/// Keep the rail glued beside the pet. Same pattern as the bubble: read
/// the origin, close the gap, then let a clamped probe say whether the
/// right side ran off the display.
pub fn sync(model: *Model, fx: *app.Effects, pet_x: f64, pet_y: f64, pet_w: f64, pet_h: f64) void {
    if (!active(model)) return;
    const w = windowWidth();
    const h = windowHeight(model.len);
    if (@abs(w - model.window_w) > 0.5 or @abs(h - model.window_h) > 0.5) {
        _ = fx.resizeWindow(window_label, w, h, .top_left);
        model.window_w = w;
        model.window_h = h;
    }
    if (model.on_left and pet_x < model.flip_x - flip_hysteresis) model.on_left = false;
    var want = wantOrigin(model, pet_x, pet_y, pet_w, pet_h);
    const cur = fx.moveWindow(window_label, 0, 0, false) orelse return;
    if (@abs(want.x - cur.x) > 0.5 or @abs(want.y - cur.y) > 0.5) {
        _ = fx.moveWindow(window_label, want.x - cur.x, want.y - cur.y, false) orelse return;
    }
    if (model.on_left) return;
    const settled = fx.moveWindow(window_label, 0, 0, true) orelse return;
    if (!settled.hit_x) return;
    model.on_left = true;
    model.flip_x = pet_x;
    want = wantOrigin(model, pet_x, pet_y, pet_w, pet_h);
    _ = fx.moveWindow(window_label, want.x - settled.x, want.y - settled.y, false);
}

// ----------------------------------------------------------------- view

/// Agent logos live in main.zig's packed strip; handed in for the same
/// reason settings_view takes them.
pub const IconAtlas = struct {
    ready: bool,
    image: u64,
    rect: *const fn (usize) geometry.RectF,
    index: *const fn ([]const u8) usize,
};

pub fn ringColor(status: Status) canvas.Color {
    return switch (status) {
        .working => canvas.Color.rgb8(239, 68, 68),
        .waiting => canvas.Color.rgb8(250, 204, 21),
        .done => canvas.Color.rgb8(34, 197, 94),
        .idle => canvas.Color.rgba8(255, 255, 255, 70),
    };
}

var label_scratch: [max_entries][64]u8 = undefined;

fn semanticLabel(entry: *const Entry, slot: usize) []const u8 {
    return std.fmt.bufPrint(&label_scratch[slot], "{s}: {s}", .{ entry.agentSlice(), entry.status.label() }) catch entry.agentSlice();
}

fn railIcon(ui: *AppUi, entry: *const Entry, slot: usize, icons: IconAtlas) AppUi.Node {
    const name = entry.agentSlice();
    const glyph = if (icons.ready) blk: {
        var image = ui.image(.{ .width = icon_px, .height = icon_px, .image = icons.image });
        image.widget.image_src = icons.rect(icons.index(name));
        image.widget.image_fit = .contain;
        break :blk image;
    } else blk: {
        // Before the strip decodes, an initial keeps the slot readable.
        var text = ui.text(.{ .size = .sm, .text_alignment = .center }, if (name.len > 0) name[0..1] else "?");
        text.widget.style.foreground = canvas.Color.rgb8(237, 237, 238);
        break :blk text;
    };
    var ring = ui.el(.panel, .{
        .width = cell_px,
        .height = cell_px,
        .padding = ring_px + ring_gap,
        .main = .center,
        .cross = .center,
        .semantics = .{ .label = semanticLabel(entry, slot) },
    }, .{glyph});
    ring.widget.style.radius = cell_px / 2;
    ring.widget.style.background = canvas.Color.rgba8(255, 255, 255, 18);
    ring.widget.style.border = ringColor(entry.status);
    ring.widget.style.stroke_width = ring_px;
    return ring;
}

pub fn railView(ui: *AppUi, model: *const Model, icons: IconAtlas) AppUi.Node {
    var icons_nodes: [max_entries]AppUi.Node = undefined;
    for (model.entries[0..model.len], 0..) |*entry, slot| icons_nodes[slot] = railIcon(ui, entry, slot, icons);
    var tab = ui.el(.panel, .{
        .padding = tab_padding,
        .width = windowWidth(),
        .height = windowHeight(model.len),
        .semantics = .{ .label = "Agent status" },
    }, .{ui.column(.{ .gap = tab_gap, .cross = .center }, @as([]const AppUi.Node, icons_nodes[0..model.len]))});
    tab.widget.style.radius = tab_radius;
    tab.widget.style.background = canvas.Color.rgba8(0, 0, 0, 150);
    tab.widget.style.border = canvas.Color.rgba8(255, 255, 255, 22);
    tab.widget.style.stroke_width = 1;
    return tab;
}

// ---------------------------------------------------------------- tests

fn testBubble(session: []const u8, agent: []const u8, status: hook_server.SessionStatus) hook_server.Bubble {
    var bubble: hook_server.Bubble = .{};
    copyInto(&bubble.session, &bubble.session_len, session);
    copyInto(&bubble.agent, &bubble.agent_len, agent);
    bubble.status = status;
    bubble.busy = status == .running;
    return bubble;
}

test "session status maps onto the three ring colours" {
    try std.testing.expectEqual(Status.working, Status.fromSession(.running, true));
    try std.testing.expectEqual(Status.waiting, Status.fromSession(.needs_input, false));
    try std.testing.expectEqual(Status.done, Status.fromSession(.completed, false));
    try std.testing.expectEqual(Status.done, Status.fromSession(.failed, false));
    try std.testing.expectEqual(Status.idle, Status.fromSession(.idle, false));
    try std.testing.expectEqual(Status.working, Status.fromSession(.idle, true));
}

test "reconcile keeps order and reports edges" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    const first = [_]hook_server.Bubble{
        testBubble("a", "claude", .running),
        testBubble("b", "codex", .needs_input),
    };
    try std.testing.expectEqual(@as(usize, 2), reconcile(&model, &first, 1000, &out));
    try std.testing.expectEqual(@as(?Status, null), out[0].from);
    try std.testing.expectEqual(@as(usize, 2), model.len);

    // Reversed drain order must not reshuffle the rail.
    const second = [_]hook_server.Bubble{
        testBubble("b", "codex", .running),
        testBubble("a", "claude", .completed),
    };
    try std.testing.expectEqual(@as(usize, 2), reconcile(&model, &second, 2000, &out));
    try std.testing.expectEqualStrings("claude", model.entries[0].agentSlice());
    try std.testing.expectEqual(Status.done, model.entries[0].status);
    try std.testing.expectEqual(Status.working, model.entries[1].status);

    // Unchanged drain: no edges.
    try std.testing.expectEqual(@as(usize, 0), reconcile(&model, &second, 3000, &out));
}

test "a session dropped while working settles to done and ages out" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    const live = [_]hook_server.Bubble{testBubble("a", "claude", .running)};
    _ = reconcile(&model, &live, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), reconcile(&model, &.{}, 500, &out));
    try std.testing.expectEqual(Status.done, model.entries[0].status);
    try std.testing.expect(!expire(&model, 500 + done_linger_ms - 1));
    try std.testing.expect(expire(&model, 500 + done_linger_ms));
    try std.testing.expectEqual(@as(usize, 0), model.len);
}

test "active entries never age out" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    const live = [_]hook_server.Bubble{
        testBubble("a", "claude", .running),
        testBubble("b", "claude", .needs_input),
    };
    _ = reconcile(&model, &live, 0, &out);
    try std.testing.expect(!expire(&model, done_linger_ms * 10));
    try std.testing.expectEqual(@as(usize, 2), model.len);
}

test "a full rail evicts the oldest settled entry for a new session" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    var bubbles: [max_entries]hook_server.Bubble = undefined;
    var names: [max_entries][2]u8 = undefined;
    for (0..max_entries) |i| {
        names[i] = .{ 's', @intCast('a' + i) };
        bubbles[i] = testBubble(&names[i], "claude", if (i == 0) .completed else .running);
    }
    _ = reconcile(&model, &bubbles, 0, &out);
    try std.testing.expectEqual(max_entries, model.len);
    bubbles[0] = testBubble("new", "codex", .running);
    _ = reconcile(&model, &bubbles, 10, &out);
    try std.testing.expectEqual(max_entries, model.len);
    try std.testing.expect(indexOf(&model, bubbles[0].identity()) != null);
}

test "anonymous bubbles are not ringed" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    const anon = [_]hook_server.Bubble{testBubble("", "", .running)};
    try std.testing.expectEqual(@as(usize, 0), reconcile(&model, &anon, 0, &out));
    try std.testing.expectEqual(@as(usize, 0), model.len);
}

test "rail origin sits right of the pet and centers vertically" {
    var model: Model = .{};
    model.len = 1;
    const origin = wantOrigin(&model, 100, 200, 192, 208);
    try std.testing.expectEqual(@as(f64, 100 + 192 + pet_gap), origin.x);
    try std.testing.expectEqual(@as(f64, 200 + (208 - @as(f64, windowHeight(1))) / 2), origin.y);
    model.on_left = true;
    try std.testing.expectEqual(@as(f64, 100 - @as(f64, windowWidth()) - pet_gap), wantOrigin(&model, 100, 200, 192, 208).x);
}

fn testIconRect(index: usize) geometry.RectF {
    return geometry.RectF.init(@floatFromInt(index * 40), 0, 40, 40);
}
fn testIconIndex(_: []const u8) usize {
    return 0;
}

test "rail view draws one ring per entry in its status colour" {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    const live = [_]hook_server.Bubble{
        testBubble("a", "claude", .running),
        testBubble("b", "codex", .needs_input),
        testBubble("c", "gemini", .completed),
    };
    _ = reconcile(&model, &live, 0, &out);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = AppUi.init(arena.allocator());
    const tab = railView(&ui, &model, .{ .ready = true, .image = 9, .rect = &testIconRect, .index = &testIconIndex });
    const column = tab.nodes[0];
    try std.testing.expectEqual(@as(usize, 3), column.nodes.len);
    try std.testing.expectEqual(ringColor(.working), column.nodes[0].widget.style.border);
    try std.testing.expectEqual(ringColor(.waiting), column.nodes[1].widget.style.border);
    try std.testing.expectEqual(ringColor(.done), column.nodes[2].widget.style.border);
    try std.testing.expectEqualStrings("codex: waiting for you", column.nodes[1].widget.semantics.label);
}
