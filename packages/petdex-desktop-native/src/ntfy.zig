//! Optional phone/watch push through a self-hosted ntfy server.
//!
//! Fires on the same edges the agent rail draws: an agent starts waiting
//! on the human, or a working agent finishes. Off unless the user opts in.
//!
//! Security properties, all enforced here rather than left to docs:
//! - Config is read once at boot from `~/.petdex-ntfy/env`, never from the
//!   repo, the settings JSON, or the environment. It is parsed as plain
//!   KEY=VALUE text and never executed.
//! - The file must be a regular file with no group/other permission bits
//!   (chmod 600), or it is ignored. The token is never logged.
//! - `NTFY_FROM_APP=1` must be set, so an existing hook-based setup does
//!   not suddenly double-notify.
//! - The URL must be https, or plain http only to loopback. The token goes
//!   in the Authorization header and nowhere else; it is meant to be a
//!   write-only ntfy token for this one topic.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const hook_server = @import("hook_server.zig");
const agent_hooks = @import("agent_hooks.zig");
const agent_rail = @import("agent_rail.zig");
const plat = @import("plat.zig");

pub const env_relative_path = ".petdex-ntfy/env";
const max_env_bytes = 4096;
const max_message_bytes = 300;
/// Effect keys for in-flight publishes. Each send takes the next one, so a
/// burst of agents finishing together does not collide on one key.
const fetch_key_base: u64 = 0x6e74_6679_0000;
const fetch_key_slots: u64 = 4;
/// Hard ceiling on sends per minute, in case a misbehaving integration
/// flaps a session between states.
const max_per_minute: u32 = 20;

pub const Config = struct {
    url: [256]u8 = @splat(0),
    url_len: usize = 0,
    topic: [64]u8 = @splat(0),
    topic_len: usize = 0,
    token: [128]u8 = @splat(0),
    token_len: usize = 0,
    from_app: bool = false,

    pub fn urlSlice(self: *const Config) []const u8 {
        return self.url[0..self.url_len];
    }
    pub fn topicSlice(self: *const Config) []const u8 {
        return self.topic[0..self.topic_len];
    }
    pub fn tokenSlice(self: *const Config) []const u8 {
        return self.token[0..self.token_len];
    }
    pub fn usable(self: *const Config) bool {
        return self.from_app and self.url_len > 0 and self.topic_len > 0 and self.token_len > 0;
    }
};

pub const Notifier = struct {
    config: ?Config = null,
    next_key: u64 = 0,
    window_start_ms: i64 = 0,
    window_count: u32 = 0,
};

fn setField(dest: []u8, dest_len: *usize, value: []const u8) bool {
    if (value.len == 0 or value.len > dest.len) return false;
    @memcpy(dest[0..value.len], value);
    dest_len.* = value.len;
    return true;
}

fn unquote(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

/// Topic and token are restricted to the characters ntfy itself issues,
/// which also rules out anything that could break a URL or header.
fn safeToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]");
}

pub fn urlAllowed(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null) return false;
    if (uri.query != null or uri.fragment != null) return false;
    const host = uri.host orelse return false;
    var host_buf: [256]u8 = undefined;
    const host_raw = host.toRaw(&host_buf) catch return false;
    if (host_raw.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    return std.ascii.eqlIgnoreCase(uri.scheme, "http") and isLoopbackHost(host_raw);
}

/// Parse the env file the setup script writes. Unknown keys are ignored;
/// any invalid value for a known key disables the notifier outright.
pub fn parseEnv(bytes: []const u8) ?Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(line[eq + 1 ..]);
        if (std.mem.eql(u8, key, "NTFY_URL")) {
            const trimmed = std.mem.trimEnd(u8, value, "/");
            if (!urlAllowed(trimmed)) return null;
            if (!setField(&config.url, &config.url_len, trimmed)) return null;
        } else if (std.mem.eql(u8, key, "NTFY_TOPIC")) {
            if (!safeToken(value)) return null;
            if (!setField(&config.topic, &config.topic_len, value)) return null;
        } else if (std.mem.eql(u8, key, "NTFY_TOKEN")) {
            if (!safeToken(value)) return null;
            if (!setField(&config.token, &config.token_len, value)) return null;
        } else if (std.mem.eql(u8, key, "NTFY_FROM_APP")) {
            config.from_app = std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
        }
    }
    return if (config.usable()) config else null;
}

/// Load and validate the env file. Null means "notifier off", with a
/// one-line reason printed for anything other than a missing file.
pub fn load(home: []const u8) ?Config {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, env_relative_path }) catch return null;
    var scope = plat.Scope.init();
    defer scope.deinit();
    const io = scope.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.kind != .file) {
        std.debug.print("petdex: ntfy off: {s} is not a regular file\n", .{env_relative_path});
        return null;
    }
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) {
            std.debug.print("petdex: ntfy off: ~/{s} must be chmod 600\n", .{env_relative_path});
            return null;
        }
    }
    if (stat.size == 0 or stat.size > max_env_bytes) return null;
    var buf: [max_env_bytes]u8 = undefined;
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const n = reader.interface.readSliceShort(&buf) catch return null;
    const config = parseEnv(buf[0..n]);
    // Silent for the common hook-only setup, which simply lacks the flag.
    if (config == null and std.mem.indexOf(u8, buf[0..n], "NTFY_FROM_APP") != null)
        std.debug.print("petdex: ntfy off: ~/{s} has an invalid NTFY_URL, NTFY_TOPIC or NTFY_TOKEN\n", .{env_relative_path});
    return config;
}

pub const Kind = enum { waiting, finished, failed };

/// Which rail edges are worth a buzz on the wrist. A session first seen
/// already finished is history (app restart, recovery scan), not news.
pub fn kindFor(edge: agent_rail.Transition, status: hook_server.SessionStatus) ?Kind {
    if (edge.to == .waiting) return .waiting;
    if (edge.to != .done) return null;
    const from = edge.from orelse return null;
    if (from != .working and from != .waiting) return null;
    return if (status == .failed) .failed else .finished;
}

pub fn displayName(agent: []const u8) []const u8 {
    for (std.enums.values(agent_hooks.AgentKind)) |kind| {
        if (std.mem.eql(u8, kind.hookAgentName(), agent)) return kind.displayName();
    }
    if (std.mem.eql(u8, agent, "claude")) return agent_hooks.AgentKind.claude_code.displayName();
    return if (agent.len > 0) agent else "Agent";
}

fn project(cwd: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, cwd, "/\\");
    const base = std.fs.path.basename(trimmed);
    return if (base.len == 0) "" else base;
}

/// Header values can only carry what the fetch effect accepts: no CR/LF,
/// and plain ASCII keeps every ntfy client happy.
fn headerSafe(out: []u8, value: []const u8) []const u8 {
    var len: usize = 0;
    for (value) |c| {
        if (len == out.len) break;
        out[len] = if (c < 0x20 or c >= 0x7f) ' ' else c;
        len += 1;
    }
    return out[0..len];
}

pub const Request = struct {
    url_buf: [512]u8 = undefined,
    url_len: usize = 0,
    auth_buf: [160]u8 = undefined,
    auth_len: usize = 0,
    title_buf: [160]u8 = undefined,
    title_len: usize = 0,
    body_buf: [max_message_bytes]u8 = undefined,
    body_len: usize = 0,
    priority: []const u8 = "3",
    tags: []const u8 = "",

    pub fn url(self: *const Request) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    pub fn title(self: *const Request) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn body(self: *const Request) []const u8 {
        return self.body_buf[0..self.body_len];
    }
    pub fn auth(self: *const Request) []const u8 {
        return self.auth_buf[0..self.auth_len];
    }
};

pub fn buildRequest(config: *const Config, kind: Kind, bubble: *const hook_server.Bubble, out: *Request) bool {
    const name = displayName(bubble.agent[0..bubble.agent_len]);
    const where = project(bubble.cwdSlice());
    const verb = switch (kind) {
        .waiting => "needs you",
        .finished => "finished",
        .failed => "hit an error",
    };
    var raw_title: [160]u8 = undefined;
    const title = if (where.len > 0)
        std.fmt.bufPrint(&raw_title, "{s} {s} in {s}", .{ name, verb, where }) catch return false
    else
        std.fmt.bufPrint(&raw_title, "{s} {s}", .{ name, verb }) catch return false;
    out.title_len = headerSafe(&out.title_buf, title).len;

    const url = std.fmt.bufPrint(&out.url_buf, "{s}/{s}", .{ config.urlSlice(), config.topicSlice() }) catch return false;
    out.url_len = url.len;
    const auth = std.fmt.bufPrint(&out.auth_buf, "Bearer {s}", .{config.tokenSlice()}) catch return false;
    out.auth_len = auth.len;

    const text = std.mem.trim(u8, bubble.text[0..bubble.text_len], " \t\r\n");
    const fallback = switch (kind) {
        .waiting => "Waiting for your approval or input.",
        .finished => "Turn complete.",
        .failed => "Something failed.",
    };
    const message = if (text.len > 0) text else fallback;
    // Cut on a UTF-8 boundary so the phone never shows a broken glyph.
    var cut = @min(message.len, out.body_buf.len);
    while (cut > 0 and cut < message.len and (message[cut] & 0xc0) == 0x80) cut -= 1;
    @memcpy(out.body_buf[0..cut], message[0..cut]);
    out.body_len = cut;

    out.priority = if (kind == .finished) "3" else "4";
    out.tags = switch (kind) {
        .waiting => "raised_hand",
        .finished => "white_check_mark",
        .failed => "warning",
    };
    return true;
}

fn allowSend(notifier: *Notifier, now_ms: i64) bool {
    if (now_ms - notifier.window_start_ms >= 60_000) {
        notifier.window_start_ms = now_ms;
        notifier.window_count = 0;
    }
    if (notifier.window_count >= max_per_minute) return false;
    notifier.window_count += 1;
    return true;
}

fn findBubble(bubbles: []const hook_server.Bubble, entry: *const agent_rail.Entry) ?*const hook_server.Bubble {
    for (bubbles) |*bubble| {
        if (entry.identity().matches(bubble.identity())) return bubble;
    }
    return null;
}

/// Publish one notification per qualifying rail edge. Fire-and-forget:
/// a failed send costs one notification, never the app's responsiveness.
pub fn onTransitions(
    notifier: *Notifier,
    fx: anytype,
    rail: *const agent_rail.Model,
    edges: []const agent_rail.Transition,
    bubbles: []const hook_server.Bubble,
    now_ms: i64,
) void {
    const config = if (notifier.config) |*c| c else return;
    for (edges) |edge| {
        if (edge.index >= rail.len) continue;
        const entry = &rail.entries[edge.index];
        // A session the mailbox dropped has no bubble left; its silent
        // settle to done is bookkeeping, not a finished turn.
        const bubble = findBubble(bubbles, entry) orelse continue;
        const kind = kindFor(edge, bubble.status) orelse continue;
        if (!allowSend(notifier, now_ms)) return;
        var request: Request = .{};
        if (!buildRequest(config, kind, bubble, &request)) continue;
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = request.auth() },
            .{ .name = "Title", .value = request.title() },
            .{ .name = "Priority", .value = request.priority },
            .{ .name = "Tags", .value = request.tags },
        };
        const key = fetch_key_base + (notifier.next_key % fetch_key_slots);
        notifier.next_key +%= 1;
        fx.fetch(.{
            .key = key,
            .method = .POST,
            .url = request.url(),
            .headers = &headers,
            .body = request.body(),
            .timeout_ms = 10_000,
        });
    }
}

// ---------------------------------------------------------------- tests

const sample_env =
    \\# written by setup-server.sh
    \\NTFY_URL="https://mac.tail1234.ts.net/"
    \\NTFY_TOPIC=pd_3f9a0c1b2d
    \\export NTFY_TOKEN='tk_abc123XYZ'
    \\NTFY_FROM_APP=1
;

test "env file parses the setup script format" {
    const config = parseEnv(sample_env).?;
    try std.testing.expectEqualStrings("https://mac.tail1234.ts.net", config.urlSlice());
    try std.testing.expectEqualStrings("pd_3f9a0c1b2d", config.topicSlice());
    try std.testing.expectEqualStrings("tk_abc123XYZ", config.tokenSlice());
}

test "notifier stays off without the opt-in flag" {
    const hook_only =
        \\NTFY_URL=https://mac.tail1234.ts.net
        \\NTFY_TOPIC=pd_x
        \\NTFY_TOKEN=tk_y
    ;
    try std.testing.expect(parseEnv(hook_only) == null);
}

test "insecure or malformed values disable the notifier" {
    const cases = [_][]const u8{
        "NTFY_URL=http://mac.tail1234.ts.net\nNTFY_TOPIC=t\nNTFY_TOKEN=k\nNTFY_FROM_APP=1",
        "NTFY_URL=https://user:pw@mac.ts.net\nNTFY_TOPIC=t\nNTFY_TOKEN=k\nNTFY_FROM_APP=1",
        "NTFY_URL=https://mac.ts.net\nNTFY_TOPIC=a/b\nNTFY_TOKEN=k\nNTFY_FROM_APP=1",
        "NTFY_URL=https://mac.ts.net\nNTFY_TOPIC=t\nNTFY_TOKEN=k y\nNTFY_FROM_APP=1",
        "NTFY_URL=https://mac.ts.net\nNTFY_TOPIC=t\nNTFY_TOKEN=$(id)\nNTFY_FROM_APP=1",
        "NTFY_URL=ftp://mac.ts.net\nNTFY_TOPIC=t\nNTFY_TOKEN=k\nNTFY_FROM_APP=1",
    };
    for (cases) |case| try std.testing.expect(parseEnv(case) == null);
}

test "plain http is allowed only to loopback" {
    try std.testing.expect(urlAllowed("http://127.0.0.1:8080"));
    try std.testing.expect(urlAllowed("http://localhost:8080"));
    try std.testing.expect(!urlAllowed("http://192.168.1.4:8080"));
    try std.testing.expect(urlAllowed("https://mac.tail1234.ts.net"));
}

test "only attention and finish edges notify" {
    try std.testing.expectEqual(@as(?Kind, .waiting), kindFor(.{ .index = 0, .from = .working, .to = .waiting }, .needs_input));
    try std.testing.expectEqual(@as(?Kind, .finished), kindFor(.{ .index = 0, .from = .working, .to = .done }, .completed));
    try std.testing.expectEqual(@as(?Kind, .failed), kindFor(.{ .index = 0, .from = .working, .to = .done }, .failed));
    try std.testing.expectEqual(@as(?Kind, null), kindFor(.{ .index = 0, .from = null, .to = .done }, .completed));
    try std.testing.expectEqual(@as(?Kind, null), kindFor(.{ .index = 0, .from = .idle, .to = .working }, .running));
    try std.testing.expectEqual(@as(?Kind, null), kindFor(.{ .index = 0, .from = .idle, .to = .done }, .completed));
}

test "request carries the token only in Authorization and strips header breaks" {
    const config = parseEnv(sample_env).?;
    var bubble: hook_server.Bubble = .{};
    const agent = "claude";
    @memcpy(bubble.agent[0..agent.len], agent);
    bubble.agent_len = agent.len;
    const cwd = "/Users/me/my\r\nproj";
    @memcpy(bubble.source_cwd[0..cwd.len], cwd);
    bubble.source_cwd_len = cwd.len;
    const text = "All tests pass.";
    @memcpy(bubble.text[0..text.len], text);
    bubble.text_len = text.len;

    var request: Request = .{};
    try std.testing.expect(buildRequest(&config, .finished, &bubble, &request));
    try std.testing.expectEqualStrings("https://mac.tail1234.ts.net/pd_3f9a0c1b2d", request.url());
    try std.testing.expectEqualStrings("Bearer tk_abc123XYZ", request.auth());
    try std.testing.expect(std.mem.indexOf(u8, request.title(), "\r") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.title(), "\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.title(), "finished") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.title(), "tk_") == null);
    try std.testing.expectEqualStrings(text, request.body());
}

test "send ceiling resets each minute" {
    var notifier: Notifier = .{};
    for (0..max_per_minute) |_| try std.testing.expect(allowSend(&notifier, 1000));
    try std.testing.expect(!allowSend(&notifier, 1000));
    try std.testing.expect(allowSend(&notifier, 61_000));
}

test "env file readable by others is refused" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const home = ".zig-cache/petdex-ntfy-home";
    var scope = plat.Scope.init();
    defer scope.deinit();
    const io = scope.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};
    try cwd.createDirPath(io, home ++ "/.petdex-ntfy");
    const path = home ++ "/" ++ env_relative_path;
    try cwd.writeFile(io, .{ .sub_path = path, .data = sample_env });
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expect(load(home) == null);
    try file.setPermissions(io, .fromMode(0o600));
    const config = load(home) orelse return error.TestExpectedConfig;
    try std.testing.expectEqualStrings("pd_3f9a0c1b2d", config.topicSlice());
}
