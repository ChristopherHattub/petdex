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
//! The tab is always on screen: it keeps a row for Claude Code,
//! Gemini/Antigravity and Codex even when none of them is running (a grey
//! idle ring), and adds a row for any other agent while it has a session.
//! The row's ring shows the most urgent state among its sessions. When an
//! agent has two or more live sessions the tab grows to the right at that
//! row with a small ringed icon per session.
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
    /// Agent-Pets: the three default rows show a mini pet instead of the
    /// agent logo. Filled by main.zig from the settings each frame.
    pets_on: bool = false,
    pet_px: [pet_slots]f32 = @splat(default_pet_px),
    /// Thumbnail-atlas index of the pet each default row shows.
    pet_thumb: [pet_slots]?usize = @splat(null),

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
        copyInto(&entry.agent, &entry.agent_len, bubble.agent[0..bubble.agent_len]);
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
        if (!entry.identity().matches(identity)) continue;
        // `matches` treats an empty conversation key as a wildcard for any
        // agent (the legacy shared slot). Rows are per agent, so two
        // sessionless agents must stay two entries.
        if (identity.conversation_key.len == 0 and !std.ascii.eqlIgnoreCase(entry.agentSlice(), identity.agent)) continue;
        return index;
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

// -------------------------------------------------------------- grouping

pub const Group = struct {
    /// Hook name that stands for the row. Points at a literal or at an
    /// entry of the model the groups were computed from.
    name: []const u8,
    count: usize = 0,
    /// Most urgent member status: waiting, then working, then done. Idle
    /// for a row with no live session.
    status: Status = .idle,
    members: [max_entries]u8 = @splat(0),
};

/// Rows that are always shown, in this order.
const default_rows = [_][]const u8{ "claude-code", "gemini", "codex" };
pub const max_groups = max_entries + default_rows.len;

pub const Groups = struct {
    items: [max_groups]Group = undefined,
    len: usize = 0,

    pub fn slice(self: *const Groups) []const Group {
        return self.items[0..self.len];
    }
};

fn urgency(status: Status) u8 {
    return switch (status) {
        .waiting => 3,
        .working => 2,
        .done => 1,
        .idle => 0,
    };
}

fn sameAgent(a: []const u8, b: []const u8) bool {
    const ka = app.agentKindForName(a);
    const kb = app.agentKindForName(b);
    if (ka != null and kb != null) return ka.? == kb.?;
    if (ka != null or kb != null) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn groupsOf(model: *const Model) Groups {
    var groups: Groups = .{};
    for (default_rows) |name| {
        groups.items[groups.len] = .{ .name = name };
        groups.len += 1;
    }
    for (model.entries[0..model.len], 0..) |*entry, index| {
        const found = for (groups.items[0..groups.len]) |*group| {
            if (sameAgent(group.name, entry.agentSlice())) break group;
        } else null;
        const group = found orelse blk: {
            groups.items[groups.len] = .{ .name = entry.agentSlice() };
            groups.len += 1;
            break :blk &groups.items[groups.len - 1];
        };
        group.members[group.count] = @intCast(index);
        group.count += 1;
        if (urgency(entry.status) > urgency(group.status)) group.status = entry.status;
    }
    return groups;
}

// ------------------------------------------------------------- geometry

const icon_px: f32 = 26;
const ring_px: f32 = 2.5;
const ring_gap: f32 = 2;
const cell_px: f32 = icon_px + (ring_px + ring_gap) * 2;
/// Agent-Pets: one size per default row (Claude Code, Gemini, Codex).
pub const pet_slots: usize = 3;
pub const default_pet_px: f32 = 34;
pub const min_pet_px: f32 = 20;
pub const max_pet_px: f32 = 64;
/// Corner logo on a pet, as a fraction of the pet's size.
const badge_fraction: f32 = 0.42;
const tab_padding: f32 = 7;
const tab_gap: f32 = 6;
const tab_radius: f32 = 12;
/// Per-session icons in an extended row.
const mini_icon_px: f32 = 14;
const mini_ring_px: f32 = 1.5;
const mini_ring_gap: f32 = 1;
const mini_cell_px: f32 = mini_icon_px + (mini_ring_px + mini_ring_gap) * 2;
const mini_gap: f32 = 4;
const ext_pad: f32 = 6;
/// The extension is a little taller than the main ring so it reads as
/// part of the tab rather than a chip beside it.
const ext_overhang: f32 = 2;
const ext_radius: f32 = 10;
/// Space between the pet's edge and the tab.
pub const pet_gap: f64 = 4;
/// How far the pet must travel back from the edge before the rail
/// returns to its right side.
const flip_hysteresis: f64 = 48;

pub fn baseWidth() f32 {
    return cell_px + tab_padding * 2;
}

/// Which Agent-Pets slot a hook name belongs to, if any.
pub fn petSlot(name: []const u8) ?usize {
    for (default_rows, 0..) |row, slot| {
        if (sameAgent(row, name)) return slot;
    }
    return null;
}

fn cellOf(icon: f32, ring: f32, gap: f32) f32 {
    return icon + (ring + gap) * 2;
}

/// Pet diameter for a row, or null while Agent-Pets is off or the row
/// has no pet (other agents keep their logo).
fn petPxFor(model: *const Model, name: []const u8) ?f32 {
    if (!model.pets_on) return null;
    const slot = petSlot(name) orelse return null;
    if (model.pet_thumb[slot] == null) return null;
    return std.math.clamp(model.pet_px[slot], min_pet_px, max_pet_px);
}

fn rowCell(model: *const Model, name: []const u8) f32 {
    return cellOf(petPxFor(model, name) orelse icon_px, ring_px, ring_gap);
}

fn widestCell(model: *const Model, groups: *const Groups) f32 {
    var widest = cell_px;
    for (groups.slice()) |group| widest = @max(widest, rowCell(model, group.name));
    return widest;
}

/// Width of the extension for a row with `sessions` live sessions; zero
/// until there is more than one to tell apart.
pub fn extWidth(sessions: usize) f32 {
    if (sessions < 2) return 0;
    const n: f32 = @floatFromInt(sessions);
    return n * mini_cell_px + (n - 1) * mini_gap + ext_pad * 2;
}

fn maxExtWidth(groups: *const Groups) f32 {
    var widest: f32 = 0;
    for (groups.slice()) |group| widest = @max(widest, extWidth(group.count));
    return widest;
}

pub fn windowWidth(model: *const Model) f32 {
    const groups = groupsOf(model);
    return widestCell(model, &groups) + tab_padding * 2 + maxExtWidth(&groups);
}

pub fn windowHeight(model: *const Model) f32 {
    const groups = groupsOf(model);
    const n: f32 = @floatFromInt(@max(groups.len, 1));
    var total: f32 = 0;
    for (groups.slice()) |group| total += rowCell(model, group.name);
    return total + (n - 1) * tab_gap + tab_padding * 2;
}

pub fn active(model: *const Model) bool {
    _ = model;
    return platform_supported;
}

/// Vertically centered on the pet, on whichever side currently fits. On
/// the left the whole window moves out by the extension width so the base
/// column stays next to the pet.
pub fn wantOrigin(model: *const Model, pet_x: f64, pet_y: f64, pet_w: f64, pet_h: f64) struct { x: f64, y: f64 } {
    const w: f64 = windowWidth(model);
    const h: f64 = windowHeight(model);
    const x = if (model.on_left) pet_x - w - pet_gap else pet_x + pet_w + pet_gap;
    return .{ .x = x, .y = pet_y + (pet_h - h) / 2.0 };
}

/// Keep the rail glued beside the pet. Same pattern as the bubble: read
/// the origin, close the gap, then let a clamped probe say whether the
/// right side ran off the display.
pub fn sync(model: *Model, fx: *app.Effects, pet_x: f64, pet_y: f64, pet_w: f64, pet_h: f64) void {
    if (!active(model)) return;
    const w = windowWidth(model);
    const h = windowHeight(model);
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

fn agentLabel(name: []const u8) []const u8 {
    if (app.agentKindForName(name)) |kind| return kind.displayName();
    return if (name.len > 0) name else "Agent";
}

var group_labels: [max_groups][96]u8 = undefined;
var member_labels: [max_entries][96]u8 = undefined;

fn groupLabel(model: *const Model, group: *const Group, slot: usize) []const u8 {
    _ = model;
    const name = agentLabel(group.name);
    if (group.count > 1) {
        return std.fmt.bufPrint(&group_labels[slot], "{s}: {d} sessions, {s}", .{ name, group.count, group.status.label() }) catch name;
    }
    return std.fmt.bufPrint(&group_labels[slot], "{s}: {s}", .{ name, group.status.label() }) catch name;
}

fn memberLabel(entry: *const Entry, slot: usize) []const u8 {
    const name = agentLabel(entry.agentSlice());
    return std.fmt.bufPrint(&member_labels[slot], "{s}: {s}", .{ name, entry.status.label() }) catch name;
}

/// The pet thumbnail atlas main.zig fills while pets are visible; one
/// idle frame per catalog entry, side by side.
pub const ThumbAtlas = struct {
    image: u64,
    ready: []const bool,
    cell_w: f32,
    cell_h: f32,
};

const RingSizes = struct { icon: f32, ring: f32, gap: f32 };

const main_sizes: RingSizes = .{ .icon = icon_px, .ring = ring_px, .gap = ring_gap };
const mini_sizes: RingSizes = .{ .icon = mini_icon_px, .ring = mini_ring_px, .gap = mini_ring_gap };

fn ringedIcon(ui: *AppUi, agent: []const u8, status: Status, label: []const u8, sizes: RingSizes, icons: IconAtlas) AppUi.Node {
    const cell = sizes.icon + (sizes.ring + sizes.gap) * 2;
    const glyph = if (icons.ready) blk: {
        var image = ui.image(.{ .width = sizes.icon, .height = sizes.icon, .image = icons.image });
        image.widget.image_src = icons.rect(icons.index(agent));
        image.widget.image_fit = .contain;
        break :blk image;
    } else blk: {
        // Before the strip decodes, an initial keeps the slot readable.
        var text = ui.text(.{ .size = .sm, .text_alignment = .center }, if (agent.len > 0) agent[0..1] else "?");
        text.widget.style.foreground = canvas.Color.rgb8(237, 237, 238);
        break :blk text;
    };
    var ring = ui.el(.panel, .{
        .width = cell,
        .height = cell,
        .padding = sizes.ring + sizes.gap,
        .main = .center,
        .cross = .center,
        .semantics = .{ .label = label },
    }, .{glyph});
    ring.widget.style.radius = cell / 2;
    ring.widget.style.background = canvas.Color.rgba8(255, 255, 255, 18);
    ring.widget.style.border = ringColor(status);
    ring.widget.style.stroke_width = sizes.ring;
    return ring;
}

/// Agent-Pets row: the pet's thumbnail inside the status ring, with the
/// agent's logo on a dark chip in the top-right corner.
pub fn ringedPet(ui: *AppUi, agent: []const u8, status: Status, label: []const u8, px: f32, thumb: usize, icons: IconAtlas, thumbs: ThumbAtlas) AppUi.Node {
    const cell = cellOf(px, ring_px, ring_gap);
    const pad = ring_px + ring_gap;
    const ready = thumb < thumbs.ready.len and thumbs.ready[thumb];
    var pet = ui.image(.{
        .width = px,
        .height = px,
        .image = if (ready) thumbs.image else 0,
    });
    pet.widget.image_src = geometry.RectF.init(@as(f32, @floatFromInt(thumb)) * thumbs.cell_w, 0, thumbs.cell_w, thumbs.cell_h);
    pet.widget.image_fit = .contain;
    pet.widget.image_sampling = .linear;

    const badge = px * badge_fraction;
    const logo = badge - 3;
    var glyph = ui.image(.{ .width = logo, .height = logo, .image = if (icons.ready) icons.image else 0 });
    if (icons.ready) {
        glyph.widget.image_src = icons.rect(icons.index(agent));
        glyph.widget.image_fit = .contain;
    }
    var chip = ui.el(.panel, .{ .width = badge, .height = badge, .padding = 1.5 }, .{glyph});
    chip.widget.style.radius = badge / 2;
    chip.widget.style.background = canvas.Color.rgba8(0, 0, 0, 215);
    chip.widget.style.border = canvas.Color.rgba8(255, 255, 255, 60);
    chip.widget.style.stroke_width = 1;
    // Children of a panel are placed at their own frame offset inside the
    // padded content box; pull the chip over the ring's top-right corner.
    chip.widget.frame.x = px - badge + pad;
    chip.widget.frame.y = -pad;

    var ring = ui.el(.panel, .{
        .width = cell,
        .height = cell,
        .padding = pad,
        .semantics = .{ .label = label },
    }, .{ pet, chip });
    ring.widget.style.radius = cell / 2;
    ring.widget.style.background = canvas.Color.rgba8(255, 255, 255, 18);
    ring.widget.style.border = ringColor(status);
    ring.widget.style.stroke_width = ring_px;
    return ring;
}

fn styleTab(node: *AppUi.Node, radius: f32) void {
    node.widget.style.radius = radius;
    node.widget.style.background = canvas.Color.rgba8(0, 0, 0, 150);
    node.widget.style.border = canvas.Color.rgba8(255, 255, 255, 22);
    node.widget.style.stroke_width = 1;
}

/// The extension for one row: a small ring per session, same translucent
/// black as the tab it grows out of.
fn extensionFor(ui: *AppUi, model: *const Model, group: *const Group, icons: IconAtlas) AppUi.Node {
    const ext_h = rowCell(model, group.name) + ext_overhang * 2;
    var minis: [max_entries]AppUi.Node = undefined;
    for (group.members[0..group.count], 0..) |member, i| {
        const entry = &model.entries[member];
        minis[i] = ringedIcon(ui, entry.agentSlice(), entry.status, memberLabel(entry, member), mini_sizes, icons);
    }
    var panel = ui.el(.panel, .{
        .width = extWidth(group.count),
        .height = ext_h,
        .padding = 0,
        .main = .center,
        .cross = .center,
    }, .{ui.row(.{ .gap = mini_gap, .cross = .center }, @as([]const AppUi.Node, minis[0..group.count]))});
    styleTab(&panel, ext_radius);
    return panel;
}

pub fn railView(ui: *AppUi, model: *const Model, icons: IconAtlas, thumbs: ThumbAtlas) AppUi.Node {
    const groups = groupsOf(model);
    const ext_w = maxExtWidth(&groups);
    var cells: [max_groups]AppUi.Node = undefined;
    var slots: [max_groups]AppUi.Node = undefined;
    for (groups.slice(), 0..) |*group, slot| {
        const ext_h = rowCell(model, group.name) + ext_overhang * 2;
        cells[slot] = if (petPxFor(model, group.name)) |px|
            ringedPet(ui, group.name, group.status, groupLabel(model, group, slot), px, model.pet_thumb[petSlot(group.name).?].?, icons, thumbs)
        else
            ringedIcon(ui, group.name, group.status, groupLabel(model, group, slot), main_sizes, icons);
        // Each slot is a little taller than the ring and the gaps shrink to
        // match, so the extension overhangs the row without moving it.
        const body = if (group.count > 1)
            extensionFor(ui, model, group, icons)
        else
            ui.el(.stack, .{ .width = 1, .height = 1 }, .{});
        slots[slot] = ui.row(.{
            .width = ext_w,
            .height = ext_h,
            .main = if (model.on_left) .end else .start,
            .cross = .center,
        }, .{body});
    }
    var base = ui.el(.panel, .{
        .padding = tab_padding,
        .width = widestCell(model, &groups) + tab_padding * 2,
        .height = windowHeight(model),
        .semantics = .{ .label = "Agent status" },
    }, .{ui.column(.{ .gap = tab_gap, .cross = .center }, @as([]const AppUi.Node, cells[0..groups.len]))});
    styleTab(&base, tab_radius);

    const slot_gap = tab_gap - ext_overhang * 2;
    const extras = ui.column(.{ .gap = slot_gap }, @as([]const AppUi.Node, slots[0..groups.len]));
    const column_pad = ui.el(.stack, .{ .width = 1, .height = tab_padding - ext_overhang }, .{});
    const extension_column = ui.column(.{}, .{ column_pad, extras });
    if (model.on_left) return ui.row(.{ .cross = .start }, .{ extension_column, base });
    return ui.row(.{ .cross = .start }, .{ base, extension_column });
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
    model.entries[0].agent_len = 6;
    @memcpy(model.entries[0].agent[0..6], "claude");
    const origin = wantOrigin(&model, 100, 200, 192, 208);
    try std.testing.expectEqual(@as(f64, 100 + 192 + pet_gap), origin.x);
    try std.testing.expectEqual(@as(f64, 200 + (208 - @as(f64, windowHeight(&model))) / 2), origin.y);
    model.on_left = true;
    try std.testing.expectEqual(@as(f64, 100 - @as(f64, windowWidth(&model)) - pet_gap), wantOrigin(&model, 100, 200, 192, 208).x);
}

const test_thumb_ready = [_]bool{ true, true, true };
const test_thumbs: ThumbAtlas = .{ .image = 12, .ready = &test_thumb_ready, .cell_w = 48, .cell_h = 52 };

fn testIconRect(index: usize) geometry.RectF {
    return geometry.RectF.init(@floatFromInt(index * 40), 0, 40, 40);
}
fn testIconIndex(_: []const u8) usize {
    return 0;
}

const test_icons: IconAtlas = .{ .ready = true, .image = 9, .rect = &testIconRect, .index = &testIconIndex };

fn testModel(live: []const hook_server.Bubble) Model {
    var model: Model = .{};
    var out: [max_entries]Transition = undefined;
    _ = reconcile(&model, live, 0, &out);
    return model;
}

test "one row per agent type in the fixed order, one session each" {
    const model = testModel(&.{
        testBubble("a", "codex", .running),
        testBubble("b", "gemini", .needs_input),
        testBubble("c", "claude-code", .completed),
    });
    const groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expectEqualStrings("claude-code", groups.items[0].name);
    try std.testing.expectEqualStrings("gemini", groups.items[1].name);
    try std.testing.expectEqualStrings("codex", groups.items[2].name);
    try std.testing.expectEqual(Status.done, groups.items[0].status);
    try std.testing.expectEqual(Status.waiting, groups.items[1].status);
    try std.testing.expectEqual(Status.working, groups.items[2].status);
    try std.testing.expectEqual(@as(f32, 0), maxExtWidth(&groups));
}

test "the tab is always there: three idle rows with no sessions" {
    const model: Model = .{};
    try std.testing.expectEqual(platform_supported, active(&model));
    const groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    for (groups.slice()) |group| {
        try std.testing.expectEqual(@as(usize, 0), group.count);
        try std.testing.expectEqual(Status.idle, group.status);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = AppUi.init(arena.allocator());
    const root = railView(&ui, &model, test_icons, test_thumbs);
    const column = root.nodes[0].nodes[0];
    try std.testing.expectEqual(@as(usize, 3), column.nodes.len);
    try std.testing.expectEqual(ringColor(.idle), column.nodes[0].widget.style.border);
    try std.testing.expectEqualStrings("Codex: idle", column.nodes[2].widget.semantics.label);
}

test "other agents get a row after the three defaults only while live" {
    var model = testModel(&.{testBubble("a", "opencode", .running)});
    var groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 4), groups.len);
    try std.testing.expectEqualStrings("opencode", groups.items[3].name);
    try std.testing.expectEqual(Status.working, groups.items[3].status);
    var out: [max_entries]Transition = undefined;
    _ = reconcile(&model, &.{}, 10, &out);
    _ = expire(&model, 10 + done_linger_ms);
    groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
}

test "several sessions of one agent share a row and the strongest status wins" {
    const model = testModel(&.{
        testBubble("a", "claude-code", .completed),
        testBubble("b", "claude", .running),
        testBubble("c", "claude-code", .needs_input),
        testBubble("d", "codex", .running),
    });
    const groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expectEqual(@as(usize, 3), groups.items[0].count);
    try std.testing.expectEqual(Status.waiting, groups.items[0].status);
    try std.testing.expectEqual(@as(usize, 0), groups.items[1].count);
    try std.testing.expectEqual(@as(usize, 1), groups.items[2].count);
    try std.testing.expect(extWidth(3) > extWidth(2));
    try std.testing.expectEqual(@as(f32, 0), extWidth(1));
    try std.testing.expectEqual(baseWidth() + extWidth(3), windowWidth(&model));
}

test "antigravity and gemini are the same row" {
    const model = testModel(&.{
        testBubble("a", "gemini", .running),
        testBubble("b", "antigravity", .running),
    });
    const groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups.items[1].count);
}

test "sessionless agents stay separate entries" {
    const model = testModel(&.{
        testBubble("", "claude-code", .running),
        testBubble("", "codex", .running),
    });
    // An empty conversation key matches any agent in `BubbleIdentity`;
    // the rail must not fold codex into the claude entry.
    try std.testing.expectEqual(@as(usize, 2), model.len);
    const groups = groupsOf(&model);
    try std.testing.expectEqual(@as(usize, 1), groups.items[0].count);
    try std.testing.expectEqual(@as(usize, 1), groups.items[2].count);
}

test "rail view draws a ring per row and an extension for a busy agent" {
    const model = testModel(&.{
        testBubble("a", "claude-code", .running),
        testBubble("b", "claude-code", .completed),
        testBubble("c", "codex", .needs_input),
        testBubble("d", "gemini", .completed),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = AppUi.init(arena.allocator());
    const root = railView(&ui, &model, test_icons, test_thumbs);
    const column = root.nodes[0].nodes[0];
    try std.testing.expectEqual(@as(usize, 3), column.nodes.len);
    // Claude: running beats done. Gemini row second, Codex third.
    try std.testing.expectEqual(ringColor(.working), column.nodes[0].widget.style.border);
    try std.testing.expectEqual(ringColor(.done), column.nodes[1].widget.style.border);
    try std.testing.expectEqual(ringColor(.waiting), column.nodes[2].widget.style.border);
    try std.testing.expectEqualStrings("Claude Code: 2 sessions, working", column.nodes[0].widget.semantics.label);
    // Only the Claude row grew: its slot holds a panel of two small rings.
    const slots = root.nodes[1].nodes[1];
    try std.testing.expectEqual(@as(usize, 3), slots.nodes.len);
    const extension = slots.nodes[0].nodes[0];
    const minis = extension.nodes[0];
    try std.testing.expectEqual(@as(usize, 2), minis.nodes.len);
    try std.testing.expectEqual(ringColor(.working), minis.nodes[0].widget.style.border);
    try std.testing.expectEqual(ringColor(.done), minis.nodes[1].widget.style.border);
}

test "rail view mirrors when the pet is at the right edge" {
    var model = testModel(&.{
        testBubble("a", "codex", .running),
        testBubble("b", "codex", .running),
    });
    model.on_left = true;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = AppUi.init(arena.allocator());
    const root = railView(&ui, &model, test_icons, test_thumbs);
    // Extension column first, base tab last (next to the pet).
    try std.testing.expectEqual(@as(usize, 2), root.nodes.len);
    try std.testing.expectEqualStrings("Agent status", root.nodes[1].widget.semantics.label);
}

test "Agent-Pets sizes rows by the pet and leaves other agents on the logo" {
    var model = testModel(&.{});
    const logo_height = windowHeight(&model);
    model.pets_on = true;
    model.pet_px = .{ 50, 40, 30 };
    model.pet_thumb = .{ 0, 1, null };
    // Codex has no pet to draw, so it keeps the logo cell.
    try std.testing.expectEqual(@as(?f32, 50), petPxFor(&model, "claude-code"));
    try std.testing.expectEqual(@as(?f32, 40), petPxFor(&model, "antigravity"));
    try std.testing.expectEqual(@as(?f32, null), petPxFor(&model, "codex"));
    try std.testing.expect(windowHeight(&model) > logo_height);
    try std.testing.expectEqual(widestCell(&model, &groupsOf(&model)) + tab_padding * 2, windowWidth(&model));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    const root = railView(&ui, &model, test_icons, test_thumbs);
    const column = root.nodes[0].nodes[0];
    try std.testing.expectEqual(@as(usize, 3), column.nodes.len);
    // A pet row carries the thumbnail and the corner logo chip.
    try std.testing.expectEqual(@as(usize, 2), column.nodes[0].nodes.len);
    try std.testing.expectEqual(ringColor(.idle), column.nodes[0].widget.style.border);
}
