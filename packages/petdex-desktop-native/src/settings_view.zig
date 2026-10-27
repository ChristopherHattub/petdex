//! The Settings window's view tree: the pet picker, the Agents rows,
//! the install banner, and every Appearance control.
//!
//! Extracted from main.zig (#613). Six of the last seven PRs to touch
//! main.zig added a row here, so this was the busiest contended region
//! in the file. It reads the model and returns nodes; it owns no state
//! and runs no effects, which is what makes it separable at all.
//!
//! The agent-icon atlas is the one exception: those globals live in
//! main.zig beside the registration that fills them, so they arrive as
//! `IconAtlas` rather than being reached across the module boundary.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const app = @import("main.zig");
const Model = app.Model;
const Msg = app.Msg;
const AppUi = app.AppUi;
const custom_font_active = &app.custom_font_active;
const bubble_text_min_px = app.bubble_text_min_px;
const bubble_text_max_px = app.bubble_text_max_px;
const bubble_columns_min = app.bubble_columns_min;
const bubble_columns_max = app.bubble_columns_max;
const bubble_answer_lines_min = app.bubble_answer_lines_min;
const bubble_answer_lines_max = app.bubble_answer_lines_max;
const catalog_mod = @import("catalog.zig");
const catalog = &catalog_mod.catalog;
const catalog_len = &catalog_mod.catalog_len;
const max_catalog = catalog_mod.max_catalog;
const agent_hooks = @import("agent_hooks.zig");
const agent_rail = @import("agent_rail.zig");
const xp_mod = @import("xp.zig");
const levelup = @import("levelup.zig");
const installer = @import("installer.zig");
const remote_runtime = @import("remote_runtime.zig");
const settingsBackground = app.settingsBackground;
const companion_header_h = app.companion_header_h;

/// Where the agent logos are, handed in so this file does not reach into
/// main.zig's registration state.
pub const IconAtlas = struct {
    ready: bool,
    image: u64,
    rect: *const fn (usize) geometry.RectF,
};

/// The pet thumbnail atlas, same reasoning as IconAtlas: the pixels and
/// the per-pet ready flags are filled incrementally by main.zig's poll
/// timer, so the view reads them rather than owning them.
pub const ThumbAtlas = struct {
    image: u64,
    ready: []const bool,
    cell_w: f32,
    cell_h: f32,
    anim_image: u64 = 0,
    anim_ready: []const bool = &.{},
};

pub const CloudImages = struct {
    avatar_ready: bool,
    avatar_image: u64,
    preview_image: u64,
    preview_ready: []const bool,
    preview_cell: f32,
    preview_columns: usize,
};

/// Secondary copy in a settings row. A plain `ui.text` leaf is always
/// single-line and elides when the trailing control narrows its column.
/// Span paragraphs word-wrap and make the row reserve the resulting
/// height, so the default window width remains fully readable.
fn mutedParagraph(ui: *AppUi, content: []const u8) AppUi.Node {
    return ui.paragraph(.{
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, &.{.{ .text = content }});
}

fn agentStatusCaption(info: agent_hooks.AgentInfo, codex_note: bool, dsh_busy: bool, dsh_error: bool) []const u8 {
    if (info.kind == .dsh) {
        if (dsh_busy) return "Running the DSH plugin command";
        if (dsh_error) return "Plugin command failed - check npx and network";
        return switch (info.status) {
            .absent => "Not detected",
            .none => "Plugin not installed",
            .node => "Restart DSH Web, then start a task",
            .current => "Connected",
        };
    }
    if (info.kind == .codex and codex_note) return "Installed - restart Codex and approve its hooks once";
    if (info.kind == .opencode) {
        return switch (info.status) {
            .absent => "Not detected",
            .none => "Plugin not installed",
            .node => "Plugin outdated",
            .current => "Connected",
        };
    }
    return switch (info.status) {
        .absent => "Not detected",
        .none => "Hooks not installed",
        .node => "Hooks outdated (CLI runner)",
        .current => "Connected",
    };
}

var more_label_buf: [48]u8 = undefined;

var install_label_buf: [128]u8 = undefined;

fn petMatchesFilter(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (name.len < filter.len) return false;
    var i: usize = 0;
    while (i + filter.len <= name.len) : (i += 1) {
        var match = true;
        for (filter, 0..) |c, j| {
            if (std.ascii.toLower(name[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn moreLabel(total: usize) []const u8 {
    return std.fmt.bufPrint(&more_label_buf, "Show all ({d})", .{total}) catch "Show all";
}

/// Download progress and the last failure, in the Settings page the app
/// already has. A deep-link install is otherwise invisible: the pet just
/// appears seconds later with no indication anything was happening.
fn installBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.install.busy()) {
        const slug = model.install.currentSlug();
        const label = switch (model.install.phase) {
            .manifest => std.fmt.bufPrint(&install_label_buf, "Looking up pets\u{2026}", .{}) catch "Looking up pets",
            // The pet.json leg is a few hundred bytes and flashes past,
            // so both download legs read as one "Downloading" step
            // rather than flickering between two labels.
            .pet_json, .spritesheet => std.fmt.bufPrint(&install_label_buf, "Downloading {s}\u{2026}", .{slug}) catch "Downloading pet",
            .idle => unreachable,
        };
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.el(.spinner, .{ .width = 16, .height = 16, .semantics = .{ .label = "Installing" } }, .{}),
                ui.text(.{ .size = .sm }, label),
            }),
        });
    }
    if (model.install.error_len > 0) {
        var message = ui.text(.{ .size = .sm }, model.install.errorSlice());
        message.widget.style.foreground = canvas.Color.rgb8(250, 105, 94);
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.column(.{ .grow = 1 }, .{message}),
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .dismiss_install_error }, "Dismiss"),
            }),
        });
    }
    return ui.el(.stack, .{}, .{});
}

fn agentsSection(ui: *AppUi, model: *const Model, icons: IconAtlas) AppUi.Node {
    var rows: [agent_hooks.agent_count]AppUi.Node = undefined;
    var count: usize = 0;
    for (model.agents, 0..) |info, i| {
        if (info.status == .absent) continue;
        const trailing = if (info.kind == .dsh and model.dsh_busy)
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, "Working")
        else if (info.kind == .dsh and info.status == .node)
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, "Restart DSH")
        else if (info.status == .current)
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = Msg{ .uninstall_agent = @intCast(i) },
            }, "Disconnect")
        else
            ui.button(.{
                .size = .sm,
                .variant = .primary,
                .on_press = Msg{ .install_agent = @intCast(i) },
            }, if (info.status == .node) "Update" else "Install");
        var logo = ui.image(.{
            .width = 24,
            .height = 24,
            .image = if (icons.ready) icons.image else 0,
            .semantics = .{ .label = info.kind.displayName() },
        });
        logo.widget.image_src = icons.rect(@intFromEnum(info.kind));
        logo.widget.image_fit = .contain;
        rows[count] = ui.el(.panel, .{
            .padding = 12,
            .gap = 12,
            .cross = .center,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = info.kind.displayName() },
        }, .{
            ui.column(.{ .gap = 10 }, .{
                ui.row(.{ .gap = 12, .cross = .center }, .{
                    logo,
                    ui.column(.{ .grow = 1, .main = .center }, .{
                        ui.text(.{}, info.kind.displayName()),
                        mutedParagraph(ui, agentStatusCaption(info, model.codex_trust_note, model.dsh_busy, model.dsh_error)),
                    }),
                    trailing,
                }),
                if (info.status == .current)
                    agent_rail.statusStrip(ui, &model.rail, info.kind.hookAgentName(), i, .{
                        .ready = icons.ready,
                        .image = icons.image,
                        .rect = icons.rect,
                        .index = &app.agentIconIndex,
                    })
                else
                    ui.el(.stack, .{}, .{}),
            }),
        });
        count += 1;
    }
    if (count == 0) {
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "No coding agents detected on this machine"),
        });
    }
    return ui.column(.{ .gap = 12 }, @as([]const AppUi.Node, rows[0..count]));
}

fn herdrSection(ui: *AppUi, model: *const Model, icons: IconAtlas) AppUi.Node {
    if (model.herdr_status == .absent) return ui.el(.stack, .{}, .{});
    var logo = ui.image(.{
        .width = 24,
        .height = 24,
        .image = if (icons.ready) icons.image else 0,
        .semantics = .{ .label = "Herdr" },
    });
    logo.widget.image_src = icons.rect(app.herdr_icon_index);
    logo.widget.image_fit = .contain;
    return ui.el(.panel, .{
        .padding = 12,
        .gap = 12,
        .cross = .center,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = "Herdr" },
    }, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            logo,
            ui.column(.{ .grow = 1, .main = .center }, .{
                ui.text(.{}, "Herdr"),
                mutedParagraph(ui, model.herdr_status.caption()),
            }),
        }),
    });
}

/// SSH remotes running agents whose hooks ride the reverse tunnel.
/// Read-only by design: remotes are declared in
/// ~/.petdex/remote-agents.json and the section only reports what the
/// runtime is doing with them. Hidden entirely when nothing is
/// configured. A user without the feature gets no noise.
fn remoteSection(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.remote_count == 0) return ui.el(.stack, .{}, .{});
    var rows: [remote_runtime.max_remotes]AppUi.Node = undefined;
    var count: usize = 0;
    for (model.remotes[0..model.remote_count]) |*slot| {
        if (!slot.active) continue;
        rows[count] = ui.el(.panel, .{
            .padding = 12,
            .gap = 12,
            .cross = .center,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = slot.nameSlice() },
        }, .{
            ui.row(.{ .gap = 12, .cross = .center }, .{
                ui.column(.{ .grow = 1, .main = .center }, .{
                    ui.text(.{}, slot.nameSlice()),
                    mutedParagraph(ui, remote_runtime.statusCaption(slot)),
                }),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, slot.host[0..slot.host_len]),
            }),
        });
        count += 1;
    }
    if (count == 0) return ui.el(.stack, .{}, .{});
    const heading = ui.text(.{ .size = .lg }, "Remote Agents");
    const hint = mutedParagraph(ui, "Declared in ~/.petdex/remote-agents.json; sync runs at launch");
    const list = ui.column(.{ .gap = 12 }, @as([]const AppUi.Node, rows[0..count]));
    return ui.column(.{ .gap = 12 }, .{ heading, hint, list });
}

var update_status_buf: [96]u8 = undefined;

fn updatesSection(ui: *AppUi, model: *const Model) AppUi.Node {
    const latest = model.latest_version[0..model.latest_version_len];
    const version_status = switch (model.update_phase) {
        .idle => std.fmt.bufPrint(&update_status_buf, "{s} · Not checked yet", .{app.updates.current_version}) catch app.updates.current_version,
        .checking => std.fmt.bufPrint(&update_status_buf, "{s} · Checking…", .{app.updates.current_version}) catch app.updates.current_version,
        .current => std.fmt.bufPrint(&update_status_buf, "{s} · Up to date", .{app.updates.current_version}) catch app.updates.current_version,
        .available => std.fmt.bufPrint(&update_status_buf, "{s} installed · {s} available", .{ app.updates.current_version, latest }) catch app.updates.current_version,
        .failed => std.fmt.bufPrint(&update_status_buf, "{s} · Check failed", .{app.updates.current_version}) catch app.updates.current_version,
    };
    const version_action = if (model.update_phase == .available)
        if (model.install_source == .homebrew)
            ui.button(.{ .variant = .primary, .on_press = .copy_brew_command }, if (model.brew_command_copied) "Copied" else "Copy brew upgrade command")
        else
            ui.button(.{ .variant = .primary, .on_press = .download_update }, "Download update")
    else
        ui.button(.{ .variant = .secondary, .on_press = .check_updates, .disabled = model.update_phase == .checking or model.update_cancel_pending }, "Check now");
    const warning_title = if (builtin.os.tag == .macos and model.install_source == .homebrew)
        "Homebrew manages updates"
    else
        "Updates stay manual";
    const warning_copy = if (builtin.os.tag == .macos)
        if (model.install_source == .homebrew)
            "Petdex never runs Brew for you. Update with brew upgrade --cask petdex."
        else
            "Petdex never replaces itself. Homebrew users should install the petdex cask first."
    else
        "Petdex can download a release, but never replaces itself automatically.";
    var warning = ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .radius = .md } }, .{
        ui.column(.{ .gap = 4 }, .{
            ui.text(.{}, warning_title),
            mutedParagraph(ui, warning_copy),
        }),
    });
    warning.widget.style.background = if (model.dark) canvas.Color.rgb8(48, 38, 22) else canvas.Color.rgb8(255, 246, 214);
    return ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .lg }, "Original Petdex updates"),
        mutedParagraph(ui, "Checks the original Petdex project's releases, not your fork. Don't install an upstream update over your fork."),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Current version"),
                    mutedParagraph(ui, version_status),
                }),
                version_action,
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Check automatically"),
                    mutedParagraph(ui, "Quietly checks once per day"),
                }),
                ui.el(.switch_control, .{
                    .selected = model.update_checks_enabled,
                    .on_toggle = .toggle_update_checks,
                    .semantics = .{ .label = "Check for updates automatically" },
                }, .{}),
            }),
        }),
        warning,
        forkSection(ui, model),
    });
}

/// The fork's own updater: pulls ChristopherHattub/petdex, rebuilds, and
/// reinstalls, in a Terminal window so progress and errors are visible.
fn forkSection(ui: *AppUi, model: *const Model) AppUi.Node {
    const supported = builtin.os.tag == .macos;
    const note = if (!supported)
        "The fork updater runs on macOS only."
    else if (model.fork_update_failed)
        "Couldn't start the updater. It expects the fork in ~/src/petdex; run scripts/install-fork-macos.sh there once."
    else
        "Pulls your fork, rebuilds, reinstalls and relaunches Petdex in a Terminal window. Your pets and settings are kept.";
    return ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .lg }, "My fork updates"),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, "Update my fork"),
                    mutedParagraph(ui, note),
                }),
                ui.button(.{ .variant = .primary, .on_press = .update_fork, .disabled = !supported }, "Update my fork"),
            }),
        }),
    });
}

fn cloudStatus(status: app.desktop_auth.PetStatus) []const u8 {
    return switch (status) {
        .pending => "Pending review",
        .approved => "Yours",
        .rejected => "Needs changes",
        .caught => "Caught",
    };
}

fn cloudPetRow(ui: *AppUi, pet: *const app.desktop_auth.Pet, cloud_id: u32, preview_cell: ?usize, images: CloudImages) AppUi.Node {
    const installed = catalog_mod.catalogIndexOf(pet.slugSlice()) != null;
    const usable = pet.status == .approved or pet.status == .caught;
    const action = if (!usable)
        ui.button(.{ .size = .sm, .width = 64, .variant = .secondary, .disabled = true }, "Review")
    else if (installed)
        ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .on_press = Msg{ .auth_install_pet = cloud_id } }, "Select")
    else
        ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .on_press = Msg{ .auth_install_pet = cloud_id } }, "Install");
    const cell = preview_cell orelse images.preview_ready.len;
    var thumb = ui.image(.{
        .width = 40,
        .height = 44,
        .image = if (cell < images.preview_ready.len and images.preview_ready[cell]) images.preview_image else 0,
        .semantics = .{ .label = pet.displayName() },
    });
    if (cell < images.preview_ready.len) {
        thumb.widget.image_src = geometry.RectF.init(
            @as(f32, @floatFromInt(cell % images.preview_columns)) * images.preview_cell,
            @as(f32, @floatFromInt(cell / images.preview_columns)) * images.preview_cell,
            images.preview_cell,
            images.preview_cell,
        );
    }
    thumb.widget.image_fit = .contain;
    thumb.widget.image_sampling = .nearest;
    return ui.el(.list_item, .{
        .height = 56,
        .padding = 8,
        .gap = 12,
        .cross = .center,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = pet.displayName() },
    }, .{
        thumb,
        ui.column(.{ .width = 150, .main = .center }, .{
            ui.text(.{}, pet.displayName()),
            mutedParagraph(ui, cloudStatus(pet.status)),
        }),
        action,
        ui.button(.{ .size = .sm, .width = 54, .variant = .secondary, .on_press = Msg{ .auth_open_pet = cloud_id } }, "Open"),
    });
}

fn cloudLibrarySection(ui: *AppUi, model: *const Model, images: CloudImages) AppUi.Node {
    const auth = &model.auth;
    const action = switch (auth.phase) {
        .signed_out, .failed => ui.button(.{ .size = .sm, .variant = .primary, .on_press = .auth_sign_in }, if (auth.phase == .failed) "Try again" else "Sign in"),
        .signed_in => ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_refresh }, "Sync"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_sign_out }, "Sign out"),
        }),
        .loading, .authorizing, .exchanging, .syncing => ui.el(.spinner, .{ .width = 18, .height = 18, .semantics = .{ .label = "Working" } }, .{}),
        .unavailable => ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, "macOS only"),
    };
    const title = if (auth.phase == .signed_in and auth.name_len > 0) auth.nameSlice() else "My Petdex";
    const caption = switch (auth.phase) {
        .signed_out => "See pets you created and caught",
        .loading => "Checking for a saved Petdex session",
        .authorizing => "Finish signing in in your browser",
        .exchanging => "Completing secure sign-in",
        .syncing => "Syncing your Petdex library",
        .signed_in => if (auth.email_len > 0) auth.emailSlice() else "Your cloud pet library",
        .failed => if (auth.error_len > 0) auth.errorSlice() else "Petdex sign-in failed",
        .unavailable => "Account sync currently uses macOS Keychain",
    };
    var avatar = ui.image(.{
        .width = 36,
        .height = 36,
        .image = if (auth.phase == .signed_in and images.avatar_ready) images.avatar_image else 0,
        .semantics = .{ .label = "Profile photo" },
    });
    avatar.widget.image_fit = .cover;
    avatar.widget.style.radius = 18;
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            if (auth.phase == .signed_in) avatar else ui.el(.stack, .{}, .{}),
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, title),
                mutedParagraph(ui, caption),
            }),
            action,
        }),
    });
}

fn thumbImage(ui: *AppUi, thumbs: ThumbAtlas, i: usize, label: []const u8, w: f32, h: f32) AppUi.Node {
    var thumb = ui.image(.{
        .width = w,
        .height = h,
        .image = if (thumbs.ready[i]) thumbs.image else 0,
        .semantics = .{ .label = label },
    });
    thumb.widget.image_src = geometry.RectF.init(
        @as(f32, @floatFromInt(i)) * thumbs.cell_w,
        0,
        thumbs.cell_w,
        thumbs.cell_h,
    );
    thumb.widget.image_fit = .contain;
    thumb.widget.image_sampling = .nearest;
    return thumb;
}

var delete_label_buf: [128]u8 = undefined;
var portrait_no_buf: [12]u8 = undefined;

/// One big framed portrait of the active pet. Pressing the frame opens
/// the picker; there is no list on the main page any more.
fn petPortrait(ui: *AppUi, model: *const Model, thumbs: ThumbAtlas) AppUi.Node {
    const have = model.active_pet < catalog_mod.catalog_len;
    const name: []const u8 = if (have) catalog[model.active_pet].slice() else "No pet selected";
    const portrait = if (have)
        thumbImage(ui, thumbs, model.active_pet, name, 168, 182)
    else
        ui.el(.stack, .{ .width = 168, .height = 182 }, .{});
    const frame = ui.el(.list_item, .{
        .height = 232,
        .padding = 16,
        .cross = .center,
        .on_press = .toggle_pet_picker,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = "Change pet" },
    }, .{
        ui.column(.{ .grow = 1, .gap = 8, .cross = .center }, .{
            portrait,
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, if (have) (std.fmt.bufPrint(&portrait_no_buf, "No. {d:0>3}", .{model.active_pet + 1}) catch "No.") else ""),
            ui.text(.{ .size = .lg }, name),
        }),
    });
    return ui.column(.{ .gap = 8 }, .{
        frame,
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.column(.{ .grow = 1 }, .{mutedParagraph(ui, "Click the portrait to switch pets")}),
            if (have)
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .open_active_pet_page }, "Open on Petdex")
            else
                ui.el(.stack, .{}, .{}),
        }),
    });
}

/// Confirmation strip for a pending delete; empty when none is pending.
fn deleteConfirm(ui: *AppUi, model: *const Model) AppUi.Node {
    const i: usize = model.pet_delete_pending;
    if (i >= catalog_mod.catalog_len) return ui.el(.stack, .{}, .{});
    const label = std.fmt.bufPrint(&delete_label_buf, "Delete {s}? Its files are removed from ~/.petdex/pets.", .{catalog[i].slice()}) catch "Delete this pet?";
    return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.column(.{ .gap = 8 }, .{
            mutedParagraph(ui, label),
            ui.row(.{ .gap = 8 }, .{
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .cancel_delete_pet }, "Cancel"),
                ui.button(.{ .size = .sm, .variant = .primary, .on_press = .confirm_delete_pet }, "Delete"),
            }),
        }),
    });
}

fn petsTop(ui: *AppUi, model: *const Model, filter: []const u8) AppUi.Node {
    const heading = ui.row(.{ .gap = 6, .cross = .center }, .{
        ui.column(.{ .grow = 1 }, .{ui.text(.{ .size = .lg }, "Choose a pet")}),
        ui.button(.{ .size = .sm, .variant = .primary, .on_press = .open_pets_folder }, "Add new pet"),
        if (model.pet_source == .installed)
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = model.install.busy(), .on_press = .refresh_pets }, "Refresh")
        else
            ui.el(.stack, .{}, .{}),
        ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .toggle_pet_picker }, "Back"),
    });
    const search = ui.el(.search_field, .{
        .height = 34,
        .text = filter,
        .on_input = AppUi.inputMsg(.pet_filter),
        .placeholder = "Search pets",
        .semantics = .{ .label = "Search pets" },
    }, .{});
    const filters = ui.row(.{ .gap = 6 }, .{
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .installed) .primary else .secondary, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.installed) } }, "Installed"),
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .yours) .primary else .secondary, .disabled = model.auth.phase != .signed_in, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.yours) } }, "Yours"),
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .caught) .primary else .secondary, .disabled = model.auth.phase != .signed_in, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.caught) } }, "Caught"),
        ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_open_community }, "Community"),
    });
    if (model.install.busy() or model.install.error_len > 0) {
        return ui.column(.{ .gap = 8 }, .{
            heading,
            filters,
            installBanner(ui, model),
            search,
        });
    }
    return ui.column(.{ .gap = 8 }, .{
        heading,
        filters,
        search,
    });
}

// ------------------------------------------------------------- Pokedex look
//
// The settings window is a handheld dex: a red shell top and bottom with
// the blue lens and LEDs, and a holographic blue screen in between where
// every panel is a translucent cyan card. `dexify` restyles the finished
// tree instead of every call site.

const Color = canvas.Color;
const dex_text = Color.rgb8(236, 249, 255);
const dex_muted = Color.rgb8(150, 204, 240);
const dex_lcd_edge = Color.rgb8(6, 22, 48);
const dex_cyan = Color.rgb8(112, 224, 255);
const dex_lens = Color.rgb8(48, 138, 238);
const dex_selected = Color.rgba8(120, 230, 255, 96);
const dex_gold = Color.rgb8(255, 214, 64);

pub fn dexShell(model: *const Model) Color {
    return if (model.dark) Color.rgb8(104, 14, 26) else Color.rgb8(192, 28, 46);
}

fn dexShellDark(model: *const Model) Color {
    return if (model.dark) Color.rgb8(70, 8, 18) else Color.rgb8(140, 18, 34);
}

/// The translucent holographic screen between the red halves.
fn dexHolo(model: *const Model) Color {
    return if (model.dark) Color.rgb8(9, 42, 90) else Color.rgb8(22, 84, 164);
}

fn dexCard(model: *const Model) Color {
    return if (model.dark) Color.rgba8(120, 220, 255, 30) else Color.rgba8(150, 230, 255, 40);
}

fn dexify(model: *const Model, node: *AppUi.Node) void {
    switch (node.widget.kind) {
        .panel, .list_item => if (node.style_tokens.background) |ref| {
            if (ref == .surface) {
                node.widget.style.background = dexCard(model);
                node.widget.style.border = dex_cyan;
                node.widget.style.stroke_width = 1.5;
            }
        },
        .text => {
            if (node.style_tokens.foreground) |ref| {
                node.widget.style.foreground = if (ref == .text_muted) dex_muted else dex_text;
            } else if (node.widget.style.foreground == null) {
                node.widget.style.foreground = dex_text;
            }
        },
        else => {},
    }
    // The tree is arena-built and still ours; Node only exposes children
    // as const.
    for (@constCast(node.nodes)) |*child| dexify(model, child);
}

fn dexLed(ui: *AppUi, color: Color) AppUi.Node {
    var led = ui.el(.panel, .{ .width = 12, .height = 12 }, .{});
    led.widget.style.radius = 6;
    led.widget.style.background = color;
    led.widget.style.border = dex_lcd_edge;
    led.widget.style.stroke_width = 1.5;
    return led;
}

/// The dex's blue lens with its glint, and the three indicator LEDs.
fn dexTopBar(ui: *AppUi, model: *const Model) AppUi.Node {
    var glint = ui.el(.panel, .{ .width = 9, .height = 9 }, .{});
    glint.widget.style.radius = 4.5;
    glint.widget.style.background = Color.rgba8(255, 255, 255, 170);
    glint.widget.frame.x = 5;
    glint.widget.frame.y = 4;
    var inner = ui.el(.panel, .{ .width = 30, .height = 30 }, .{glint});
    inner.widget.style.radius = 15;
    inner.widget.style.background = dex_lens;
    var lens = ui.el(.panel, .{ .width = 44, .height = 44, .padding = 7 }, .{inner});
    lens.widget.style.radius = 22;
    lens.widget.style.background = Color.rgb8(240, 244, 248);
    lens.widget.style.border = dex_lcd_edge;
    lens.widget.style.stroke_width = 2;
    var title = ui.text(.{ .size = .lg }, "PETDEX");
    title.widget.style.foreground = Color.rgb8(255, 255, 255);
    var bar = ui.row(.{ .padding = 12, .gap = 10, .cross = .center }, .{
        lens,
        dexLed(ui, Color.rgb8(239, 68, 68)),
        dexLed(ui, Color.rgb8(250, 204, 21)),
        dexLed(ui, Color.rgb8(34, 197, 94)),
        ui.el(.stack, .{ .grow = 1 }, .{}),
        title,
    });
    bar.widget.style.background = dexShellDark(model);
    return bar;
}

/// The dex's lower half: a round button, two pill buttons, the speaker
/// slits and a one-line legend for the levels.
fn dexBottomBar(ui: *AppUi, model: *const Model) AppUi.Node {
    var round = ui.el(.panel, .{ .width = 26, .height = 26 }, .{});
    round.widget.style.radius = 13;
    round.widget.style.background = Color.rgb8(34, 38, 48);
    round.widget.style.border = dex_lcd_edge;
    round.widget.style.stroke_width = 2;
    var pill_a = ui.el(.panel, .{ .width = 30, .height = 9 }, .{});
    pill_a.widget.style.radius = 4.5;
    pill_a.widget.style.background = Color.rgb8(250, 204, 21);
    pill_a.widget.style.border = dex_lcd_edge;
    pill_a.widget.style.stroke_width = 1.5;
    var pill_b = ui.el(.panel, .{ .width = 30, .height = 9 }, .{});
    pill_b.widget.style.radius = 4.5;
    pill_b.widget.style.background = dex_lens;
    pill_b.widget.style.border = dex_lcd_edge;
    pill_b.widget.style.stroke_width = 1.5;
    var slits: [3]AppUi.Node = undefined;
    for (&slits) |*slit| {
        slit.* = ui.el(.panel, .{ .width = 3, .height = 20 }, .{});
        slit.widget.style.radius = 1.5;
        slit.widget.style.background = dexShellDark(model);
    }
    var legend = ui.text(.{ .size = .sm }, "Lv rises with every finished cycle");
    legend.widget.style.foreground = Color.rgb8(255, 214, 220);
    var bar = ui.row(.{ .height = 46, .padding = 10, .gap = 10, .cross = .center }, .{
        round,
        ui.column(.{ .gap = 5 }, .{ pill_a, pill_b }),
        ui.el(.stack, .{ .grow = 1 }, .{}),
        legend,
        ui.row(.{ .gap = 4, .cross = .center }, @as([]const AppUi.Node, &slits)),
    });
    bar.widget.style.background = dexShellDark(model);
    return bar;
}

var level_labels: [max_catalog + 4][24]u8 = undefined;
var xp_labels: [4][32]u8 = undefined;

/// "Lv 7" for a pet, formatted into the buffer owned by `key`.
fn levelLabel(model: *const Model, name: []const u8, key: usize) []const u8 {
    const p = model.xp.progressOf(name);
    return std.fmt.bufPrint(&level_labels[key], "Lv {d}", .{p.level}) catch "Lv";
}

/// A thin XP bar: dark track, gold fill proportional to the way to the
/// next level.
fn xpBar(ui: *AppUi, model: *const Model, name: []const u8, w: f32) AppUi.Node {
    const fraction = std.math.clamp(model.xp.progressOf(name).fraction(), 0, 1);
    var fill = ui.el(.panel, .{ .width = @max(3, w * fraction), .height = 6, .padding = 0 }, .{});
    fill.widget.style.radius = 3;
    fill.widget.style.background = dex_gold;
    var track = ui.el(.panel, .{ .width = w, .height = 6, .padding = 0 }, .{fill});
    track.widget.style.radius = 3;
    track.widget.style.background = Color.rgba8(0, 12, 30, 150);
    track.widget.style.border = Color.rgba8(112, 224, 255, 120);
    track.widget.style.stroke_width = 1;
    return track;
}

const dex_cols: usize = 3;
const dex_max_rows: usize = max_catalog / dex_cols + 1;
const dex_visible: usize = 9;
var dex_labels: [max_catalog][12]u8 = undefined;

const DexGrid = struct {
    rows: [dex_max_rows]AppUi.Node = undefined,
    row_count: usize = 0,
    matches: usize = 0,
    shown: usize = 0,
};

/// The collection as a dex page: numbered cards, three to a row, the
/// current pick lit. With `slot` set it picks that agent's pet instead of
/// the main one, and the delete buttons stay out of the way.
fn dexGrid(ui: *AppUi, model: *const Model, thumbs: ThumbAtlas, filter: []const u8, slot: ?usize) DexGrid {
    var grid: DexGrid = .{};
    var cards: [max_catalog]AppUi.Node = undefined;
    const max_visible: usize = if (model.pets_expanded) max_catalog else dex_visible;
    const current: ?usize = if (slot) |sl| app.agentPetCatalogIndex(model, sl) else if (model.active_pet < catalog_mod.catalog_len) model.active_pet else null;
    for (catalog[0..@min(catalog_mod.catalog_len, max_catalog)], 0..) |*entry, i| {
        if (!petMatchesFilter(entry.slice(), filter)) continue;
        grid.matches += 1;
        if (grid.shown >= max_visible) continue;
        const deletable = slot == null and std.mem.eql(u8, entry.rootSlice(), installer.install_roots[0]);
        const press: Msg = if (slot) |sl|
            Msg{ .set_agent_pet = @intCast((sl << 16) | i) }
        else
            Msg{ .select_pet = @intCast(i) };
        const number = std.fmt.bufPrint(&dex_labels[i], "No. {d:0>3}", .{i + 1}) catch "No.";
        var card = ui.el(.list_item, .{
            .grow = 1,
            .height = if (deletable) 176 else 150,
            .padding = 8,
            .main = .center,
            .cross = .center,
            .on_press = press,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = entry.slice() },
        }, .{
            ui.column(.{ .gap = 4, .cross = .center }, .{
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, number),
                thumbImage(ui, thumbs, i, entry.slice(), 64, 70),
                ui.text(.{ .size = .sm }, entry.slice()),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, levelLabel(model, entry.slice(), i)),
                xpBar(ui, model, entry.slice(), 64),
                if (deletable)
                    ui.button(.{ .size = .sm, .width = 32, .variant = .secondary, .on_press = Msg{ .ask_delete_pet = @intCast(i) } }, "X")
                else
                    ui.el(.stack, .{}, .{}),
            }),
        });
        if (current != null and current.? == i) {
            card.style_tokens.background = null;
            card.widget.style.background = dex_selected;
            card.widget.style.border = dex_gold;
            card.widget.style.stroke_width = 2.5;
        }
        cards[grid.shown] = card;
        grid.shown += 1;
    }
    var at: usize = 0;
    while (at < grid.shown) : (at += dex_cols) {
        const end = @min(at + dex_cols, grid.shown);
        var row_cards: [dex_cols]AppUi.Node = undefined;
        for (0..dex_cols) |k| {
            row_cards[k] = if (at + k < end) cards[at + k] else ui.el(.stack, .{ .grow = 1 }, .{});
        }
        grid.rows[grid.row_count] = ui.row(.{ .gap = 8 }, @as([]const AppUi.Node, &row_cards));
        grid.row_count += 1;
    }
    return grid;
}

/// "Show all" / "Show less" under a grid, when it truncates.
fn dexMore(ui: *AppUi, grid: *const DexGrid) AppUi.Node {
    if (grid.matches > grid.shown) return ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .toggle_pets_expanded }, moreLabel(grid.matches));
    if (grid.shown > dex_visible) return ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .toggle_pets_expanded }, "Show less");
    if (grid.matches == 0) return ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "No installed pets match");
    return ui.el(.stack, .{}, .{});
}

/// A section header that folds its body away. The body is built either
/// way; only an open section lays it out.
fn collapsible(ui: *AppUi, model: *const Model, section: app.Section, title: []const u8, body: AppUi.Node) AppUi.Node {
    const open = app.sectionOpen(model, section);
    var name = ui.text(.{ .size = .lg }, title);
    name.widget.style.foreground = Color.rgb8(255, 255, 255);
    var state = ui.text(.{ .size = .sm }, if (open) "Hide" else "Show");
    state.widget.style.foreground = Color.rgb8(255, 214, 220);
    var header = ui.el(.list_item, .{
        .height = 40,
        .padding = 10,
        .gap = 8,
        .cross = .center,
        .on_press = Msg{ .toggle_section = @intFromEnum(section) },
        .style_tokens = .{ .radius = .md },
        .semantics = .{ .label = title },
    }, .{
        ui.column(.{ .grow = 1 }, .{name}),
        state,
    });
    header.widget.style.background = dexShellDark(model);
    header.widget.style.border = dex_lcd_edge;
    header.widget.style.stroke_width = 2;
    return ui.column(.{ .gap = 8 }, .{
        header,
        if (open) body else ui.el(.stack, .{}, .{}),
    });
}

const agent_pet_labels = [_][]const u8{ "Claude Code", "Antigravity", "Codex" };
const agent_pet_hooks = [_][]const u8{ "claude-code", "gemini", "codex" };

fn railIcons(icons: IconAtlas) agent_rail.IconAtlas {
    return .{ .ready = icons.ready, .image = icons.image, .rect = icons.rect, .index = &app.agentIconIndex };
}

fn railThumbs(thumbs: ThumbAtlas) agent_rail.ThumbAtlas {
    return .{ .image = thumbs.image, .ready = thumbs.ready, .cell_w = thumbs.cell_w, .cell_h = thumbs.cell_h, .anim_image = thumbs.anim_image, .anim_ready = thumbs.anim_ready };
}

const party_row_h: f32 = 68;
const party_gap: f32 = 8;
var party_no_buf: [16]u8 = undefined;

/// The big left slot of the party screen: the main pet, with its number,
/// level and XP bar. Pressing it opens the collection.
fn partyMain(ui: *AppUi, model: *const Model, thumbs: ThumbAtlas, h: f32) AppUi.Node {
    const have = model.active_pet < catalog_mod.catalog_len;
    const name: []const u8 = if (have) catalog[model.active_pet].slice() else "No pet selected";
    const portrait = if (have)
        thumbImage(ui, thumbs, model.active_pet, name, 104, 112)
    else
        ui.el(.stack, .{ .width = 104, .height = 112 }, .{});
    var card = ui.el(.list_item, .{
        .grow = 1,
        .height = h,
        .padding = 10,
        .main = .center,
        .cross = .center,
        .on_press = .toggle_pet_picker,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = "Change main pet" },
    }, .{
        ui.column(.{ .gap = 4, .cross = .center }, .{
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "MAIN PET"),
            portrait,
            ui.text(.{}, name),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, if (have) (std.fmt.bufPrint(&party_no_buf, "No. {d:0>3}", .{model.active_pet + 1}) catch "No.") else ""),
            if (have) ui.text(.{ .size = .sm }, levelLabel(model, name, max_catalog + 3)) else ui.el(.stack, .{}, .{}),
            if (have) xpBar(ui, model, name, 120) else ui.el(.stack, .{}, .{}),
        }),
    });
    card.widget.style.border = dex_gold;
    return card;
}

/// One stacked blue row of the party screen: an agent's pet in its ring,
/// the agent, the pet's name and level, and its XP bar.
fn partyRow(ui: *AppUi, model: *const Model, icons: IconAtlas, thumbs: ThumbAtlas, slot: usize) AppUi.Node {
    const px: f32 = 40;
    const index = app.agentPetCatalogIndex(model, slot);
    const name: []const u8 = if (index) |i| catalog[i].slice() else "No pet";
    const flourish = levelup.progress(model.rail.now_ms, model.levelup_at_ms[slot]);
    const portrait: AppUi.Node = if (index) |i|
        agent_rail.ringedPet(ui, agent_pet_hooks[slot], .idle, agent_pet_labels[slot], px, slot, i, model.rail.anim_ms, railIcons(icons), railThumbs(thumbs), null, flourish)
    else
        ui.el(.stack, .{ .width = px, .height = px }, .{});
    return ui.el(.list_item, .{
        .height = party_row_h,
        .padding = 8,
        .gap = 10,
        .cross = .center,
        .on_press = Msg{ .open_agent_pet_picker = @intCast(slot) },
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = agent_pet_labels[slot] },
    }, .{
        portrait,
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, agent_pet_labels[slot]),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.column(.{ .grow = 1 }, .{ui.text(.{ .size = .sm }, name)}),
                ui.text(.{ .size = .sm }, if (index != null) levelLabel(model, name, max_catalog + slot) else ""),
            }),
            xpBar(ui, model, name, 150),
        }),
    });
}

/// "Choose a team": the main pet on the left, each agent's pet stacked on
/// the right.
fn partyScreen(ui: *AppUi, model: *const Model, icons: IconAtlas, thumbs: ThumbAtlas) AppUi.Node {
    const total_h = party_row_h * 3 + party_gap * 2;
    if (!model.agent_pets) {
        return ui.column(.{ .gap = 8 }, .{
            partyMain(ui, model, thumbs, 200),
            mutedParagraph(ui, "Press the pet to switch it. Turn on Agent-Pets in Appearance to give each agent its own"),
        });
    }
    return ui.column(.{ .gap = 8 }, .{
        ui.row(.{ .gap = party_gap }, .{
            partyMain(ui, model, thumbs, total_h),
            ui.column(.{ .grow = 1, .gap = party_gap }, .{
                partyRow(ui, model, icons, thumbs, 0),
                partyRow(ui, model, icons, thumbs, 1),
                partyRow(ui, model, icons, thumbs, 2),
            }),
        }),
        mutedParagraph(ui, "Pick a slot to choose its pet. Pets earn XP while their agent works and finishes threads; the main pet earns from all of them"),
    });
}

fn cancelRow(ui: *AppUi, on_press: Msg) AppUi.Node {
    return ui.row(.{ .gap = 8 }, .{
        ui.el(.stack, .{ .grow = 1 }, .{}),
        ui.button(.{ .size = .sm, .variant = .secondary, .on_press = on_press }, "Cancel"),
    });
}

fn agentPetPicker(ui: *AppUi, model: *const Model, thumbs: ThumbAtlas, slot: usize) AppUi.Node {
    const grid = dexGrid(ui, model, thumbs, model.pet_filter[0..model.pet_filter_len], slot);
    var heading_buf: [48]u8 = undefined;
    const heading = std.fmt.bufPrint(&heading_buf, "Choose a pet for {s}", .{agent_pet_labels[slot]}) catch agent_pet_labels[slot];
    return ui.column(.{ .gap = 8 }, .{
        ui.row(.{ .gap = 6, .cross = .center }, .{
            ui.column(.{ .grow = 1 }, .{ui.text(.{ .size = .lg }, heading)}),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = Msg{ .reset_agent_pet = @intCast(slot) } }, "Same as main pet"),
        }),
        ui.el(.search_field, .{
            .height = 34,
            .text = model.pet_filter[0..model.pet_filter_len],
            .on_input = AppUi.inputMsg(.pet_filter),
            .placeholder = "Search pets",
            .semantics = .{ .label = "Search pets" },
        }, .{}),
        ui.column(.{ .gap = 8 }, @as([]const AppUi.Node, grid.rows[0..grid.row_count])),
        dexMore(ui, &grid),
        cancelRow(ui, .close_agent_pet_picker),
    });
}

fn sizeRow(ui: *AppUi, model: *const Model, slot: usize, on_size: @TypeOf(AppUi.valueMsg(.set_scale))) AppUi.Node {
    const px = std.math.clamp(model.agent_pet_px[slot], agent_rail.min_pet_px, agent_rail.max_pet_px);
    const fraction: f32 = (px - agent_rail.min_pet_px) / (agent_rail.max_pet_px - agent_rail.min_pet_px);
    return ui.row(.{ .gap = 12, .cross = .center }, .{
        ui.column(.{ .grow = 1 }, .{ui.text(.{ .size = .sm }, agent_pet_labels[slot])}),
        ui.el(.slider, .{ .width = 170, .value = fraction, .on_value = on_size, .semantics = .{ .label = agent_pet_labels[slot] } }, .{}),
    });
}

fn agentPetsSection(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.column(.{ .padding = 12, .gap = 10 }, .{
            mutedParagraph(ui, "Size of each agent's mini pet in the tab"),
            sizeRow(ui, model, 0, AppUi.valueMsg(.set_agent_pet_size_claude)),
            sizeRow(ui, model, 1, AppUi.valueMsg(.set_agent_pet_size_gemini)),
            sizeRow(ui, model, 2, AppUi.valueMsg(.set_agent_pet_size_codex)),
        }),
    });
}

pub fn settingsView(ui: *AppUi, model: *const Model, icons: IconAtlas, thumbs: ThumbAtlas, cloud_images: CloudImages) AppUi.Node {
    var rows: [max_catalog]AppUi.Node = undefined;
    var shown: usize = 0;
    var matches: usize = 0;
    const max_visible: usize = if (model.pets_expanded) max_catalog else 6;
    const filter = model.pet_filter[0..model.pet_filter_len];
    var grid: DexGrid = .{};
    if (model.pet_source == .installed) {
        if (model.pet_picker_open) grid = dexGrid(ui, model, thumbs, filter, null);
    } else {
        const pets = if (model.pet_source == .yours) model.auth.owned[0..model.auth.owned_len] else model.auth.caught[0..model.auth.caught_len];
        for (pets, 0..) |*pet, i| {
            if (!petMatchesFilter(pet.displayName(), filter) and !petMatchesFilter(pet.slugSlice(), filter)) continue;
            matches += 1;
            if (shown >= max_visible) continue;
            const caught_offset: usize = if (model.pet_source == .caught) app.desktop_auth.max_pets else 0;
            const preview_offset: usize = if (model.pet_source == .caught) 6 else 0;
            rows[shown] = cloudPetRow(
                ui,
                pet,
                @intCast(caught_offset + i),
                if (i < 6) preview_offset + i else null,
                cloud_images,
            );
            shown += 1;
        }
    }
    const scale_fraction: f32 = (model.scale - 0.4) / 0.8;
    const bubble_text_fraction: f32 = (model.bubble_text_px - bubble_text_min_px) / (bubble_text_max_px - bubble_text_min_px);
    const agent_pets_row = ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, "Agent-Pets"),
                mutedParagraph(ui, "Show a mini pet with a status ring for each agent in the tab"),
            }),
            ui.el(.switch_control, .{
                .selected = model.agent_pets,
                .on_toggle = .toggle_agent_pets,
                .semantics = .{ .label = "Agent-Pets" },
            }, .{}),
        }),
    });
    // One scrollable page of collapsible sections: the root scroll takes
    // the window frame and every group folds down to its header.
    var page = ui.scroll(.{ .grow = 1, .value = model.settings_scroll, .on_scroll = AppUi.scrollMsg(.settings_scrolled) }, .{ui.column(.{ .padding = 12, .gap = 10 }, .{
        collapsible(ui, model, .pet, "Pet", ui.column(.{ .gap = 10 }, .{
            cloudLibrarySection(ui, model, cloud_images),
            if (model.agent_pet_picker != 0)
                agentPetPicker(ui, model, thumbs, model.agent_pet_picker - 1)
            else if (model.pet_picker_open)
                petsTop(ui, model, filter)
            else
                partyScreen(ui, model, icons, thumbs),
            if (model.pet_picker_open and model.agent_pet_picker == 0) deleteConfirm(ui, model) else ui.el(.stack, .{}, .{}),
            if (!model.pet_picker_open or model.agent_pet_picker != 0)
                ui.el(.stack, .{}, .{})
            else if (model.pet_source == .installed)
                ui.column(.{ .gap = 8 }, @as([]const AppUi.Node, grid.rows[0..grid.row_count]))
            else
                ui.column(.{ .gap = 6 }, @as([]const AppUi.Node, rows[0..shown])),
            if (!model.pet_picker_open or model.agent_pet_picker != 0)
                ui.el(.stack, .{}, .{})
            else if (model.pet_source == .installed)
                dexMore(ui, &grid)
            else if (matches > shown)
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_open_library }, "Open all on Petdex")
            else if (matches == 0)
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "No pets match your search")
            else
                ui.el(.stack, .{}, .{}),
            if (model.pet_picker_open and model.agent_pet_picker == 0) cancelRow(ui, .toggle_pet_picker) else ui.el(.stack, .{}, .{}),
        })),
        if (model.agent_pets)
            collapsible(ui, model, .agent_pets, "Agent-Pet size", agentPetsSection(ui, model))
        else
            ui.el(.stack, .{}, .{}),
        collapsible(ui, model, .agents, "Agents", ui.column(.{ .gap = 10 }, .{
            agentsSection(ui, model, icons),
            herdrSection(ui, model, icons),
            remoteSection(ui, model),
        })),
        collapsible(ui, model, .appearance, "Appearance", ui.column(.{ .gap = 10 }, .{
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Pet size"),
                        mutedParagraph(ui, "Adjust the size of your pet"),
                    }),
                    ui.el(.slider, .{ .width = 150, .value = scale_fraction, .on_value = AppUi.valueMsg(.set_scale), .semantics = .{ .label = "Pet size" } }, .{}),
                }),
            }),
            agent_pets_row,
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.column(.{ .padding = 12, .gap = 8 }, .{
                    ui.text(.{}, "Custom font file"),
                    mutedParagraph(ui, if (model.font_load_failed)
                        "Could not load this TrueType font; the default font is active"
                    else if (model.font_path_dirty)
                        "Saved; restart Petdex to apply"
                    else if (custom_font_active.*)
                        "Applied to all app text; restart after changing the path"
                    else
                        "Optional local .ttf path; leave empty for the default font"),
                    ui.el(.input, .{
                        .height = 34,
                        .text = model.font_path[0..model.font_path_len],
                        .on_input = AppUi.inputMsg(.font_path_input),
                        .placeholder = "/path/to/font.ttf",
                        .semantics = .{ .label = "Custom font file path" },
                    }, .{}),
                }),
            }),
        })),
        collapsible(ui, model, .messages, "Messages and sounds", ui.column(.{ .gap = 10 }, .{
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Show messages"),
                        mutedParagraph(ui, "Agent activity bubbles over the pet"),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.bubbles_enabled,
                        .on_toggle = .toggle_bubbles,
                        .semantics = .{ .label = "Show messages" },
                    }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "One bubble per conversation"),
                        mutedParagraph(ui, "Stack a card per agent; off shows one bubble at a time"),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.bubbles_per_conversation,
                        .on_toggle = .toggle_bubbles_per_conversation,
                        .semantics = .{ .label = "One bubble per conversation" },
                    }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Bubble lifetime"),
                        mutedParagraph(ui, "0 keeps bubbles visible; 1–60 seconds enables expiry"),
                    }),
                    ui.el(.input, .{
                        .width = 72,
                        .height = 34,
                        .text = model.bubble_lifetime_text[0..model.bubble_lifetime_text_len],
                        .on_input = AppUi.inputMsg(.bubble_lifetime_input),
                        .semantics = .{ .label = "Bubble lifetime in seconds" },
                    }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Bubble text size"),
                        mutedParagraph(ui, "Size of the bubble text"),
                    }),
                    ui.el(.slider, .{ .width = 150, .value = bubble_text_fraction, .on_value = AppUi.valueMsg(.set_bubble_text_size), .semantics = .{ .label = "Bubble text size" } }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Characters per line"),
                        mutedParagraph(ui, "8–120; maximum characters before wrapping"),
                    }),
                    ui.el(.input, .{
                        .width = 72,
                        .height = 34,
                        .text = model.bubble_columns_text[0..model.bubble_columns_text_len],
                        .on_input = AppUi.inputMsg(.bubble_columns_input),
                        .semantics = .{ .label = "Characters per line" },
                    }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Answer lines"),
                        mutedParagraph(ui, "1–8 answer rows; title uses one additional row"),
                    }),
                    ui.el(.input, .{
                        .width = 72,
                        .height = 34,
                        .text = model.bubble_answer_lines_text[0..model.bubble_answer_lines_text_len],
                        .on_input = AppUi.inputMsg(.bubble_answer_lines_input),
                        .semantics = .{ .label = "Answer lines" },
                    }, .{}),
                }),
            }),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Waiting sound"),
                        mutedParagraph(ui, "Play a chime when your agent is waiting for your input"),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.waiting_sound,
                        .on_toggle = .toggle_waiting_sound,
                        .semantics = .{ .label = "Waiting sound" },
                    }, .{}),
                }),
            }),
        })),
        collapsible(ui, model, .general, "General", ui.column(.{ .gap = 10 }, .{
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Rotate pet daily"),
                        mutedParagraph(ui, "Wake up to a different pet each day"),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.rotate_pets,
                        .on_toggle = .toggle_rotate_pets,
                        .semantics = .{ .label = "Rotate pet daily" },
                    }, .{}),
                }),
            }),
            // Login items ride SMAppService, so like the Dock row this one
            // only exists on macOS.
            if (builtin.os.tag == .macos)
                ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                    ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                        ui.column(.{ .grow = 1 }, .{
                            ui.text(.{}, "Launch at login"),
                            mutedParagraph(ui, "Start Petdex when you log in"),
                        }),
                        ui.el(.switch_control, .{
                            .selected = model.launch_at_login,
                            .on_toggle = .toggle_launch_at_login,
                            .semantics = .{ .label = "Launch at login" },
                        }, .{}),
                    }),
                })
            else
                ui.el(.stack, .{}, .{}),
            // Dock presence is an AppKit concept; other platforms have no
            // equivalent toggle to offer, so the row only exists on macOS.
            if (builtin.os.tag == .macos)
                ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                    ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                        ui.column(.{ .grow = 1 }, .{
                            ui.text(.{}, "Hide Dock icon"),
                            mutedParagraph(ui, "Petdex lives in the menu bar only"),
                        }),
                        ui.el(.switch_control, .{
                            .selected = model.hide_dock,
                            .on_toggle = .toggle_hide_dock,
                            .semantics = .{ .label = "Hide Dock icon" },
                        }, .{}),
                    }),
                })
            else
                ui.el(.stack, .{}, .{}),
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, "Custom pets"),
                        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "~/.petdex/pets"),
                    }),
                    ui.button(.{ .on_press = .open_pets_folder }, "Open folder"),
                }),
            }),
        })),
        collapsible(ui, model, .updates, "Updates", updatesSection(ui, model)),
        // Trailing spacer: the column's own bottom padding is not part
        // of the scroll extent, so the last card needs explicit air.
        ui.el(.stack, .{ .height = 8 }, .{}),
    })});
    dexify(model, &page);
    var screen = ui.el(.panel, .{ .grow = 1, .padding = 0 }, .{page});
    screen.widget.style.background = dexHolo(model);
    screen.widget.style.border = dex_cyan;
    screen.widget.style.stroke_width = 2;
    screen.widget.style.radius = 10;
    const content = ui.column(.{ .grow = 1, .gap = 0 }, .{
        ui.el(.stack, .{ .height = companion_header_h, .window_drag = true }, .{}),
        dexTopBar(ui, model),
        ui.column(.{ .grow = 1, .padding = 8 }, .{screen}),
        dexBottomBar(ui, model),
    });
    var root = ui.panel(.{ .grow = 1 }, .{content});
    root.widget.style.background = dexShell(model);
    root.widget.style.radius = 0;
    root.widget.style.stroke_width = 0;
    return root;
}

test "settings descriptions use wrapped paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());

    const copy = "A description long enough to wrap beside a control";
    const node = mutedParagraph(&ui, copy);
    try std.testing.expectEqual(@as(usize, 1), node.widget.spans.len);
    try std.testing.expectEqualStrings(copy, node.widget.text);
    try std.testing.expect(!node.widget.text_no_wrap);
}

test "DSH command errors do not ask for a global pnpm install" {
    const info = agent_hooks.AgentInfo{ .kind = .dsh, .status = .none };
    try std.testing.expectEqualStrings(
        "Plugin command failed - check npx and network",
        agentStatusCaption(info, false, false, true),
    );
}

test "settings keeps the upstream check and adds a separately labelled fork updater" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    var model: Model = .{};

    const section = updatesSection(&ui, &model);
    // heading, upstream hint, version row, auto-check row, warning, fork section
    try std.testing.expectEqual(@as(usize, 6), section.nodes.len);
    try std.testing.expectEqualStrings("Original Petdex updates", section.nodes[0].widget.text);

    const fork = section.nodes[5];
    try std.testing.expectEqualStrings("My fork updates", fork.nodes[0].widget.text);
    const row = fork.nodes[1].nodes[0];
    const button = row.nodes[1];
    try std.testing.expectEqualStrings("Update my fork", button.widget.text);
    model.fork_update_failed = true;
    const failed = forkSection(&ui, &model);
    const note = failed.nodes[1].nodes[0].nodes[0].nodes[1].widget.text;
    if (builtin.os.tag == .macos) {
        try std.testing.expect(std.mem.indexOf(u8, note, "~/src/petdex") != null);
    } else {
        try std.testing.expectEqualStrings("The fork updater runs on macOS only.", note);
    }
}

test "settings sections fold away until their header is pressed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    var model: Model = .{};
    const body = ui.text(.{}, "body");

    try std.testing.expect(app.sectionOpen(&model, .pet));
    try std.testing.expect(!app.sectionOpen(&model, .appearance));
    const closed = collapsible(&ui, &model, .appearance, "Appearance", body);
    try std.testing.expectEqual(@as(usize, 2), closed.nodes.len);
    try std.testing.expectEqual(canvas.WidgetKind.stack, closed.nodes[1].widget.kind);

    model.sections_open |= 1 << @intFromEnum(app.Section.appearance);
    const opened = collapsible(&ui, &model, .appearance, "Appearance", body);
    try std.testing.expectEqualStrings("body", opened.nodes[1].widget.text);
}

test "party screen shows a level and an XP bar for every slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    var model: Model = .{};
    _ = model.xp.add("boba", 100);
    const bar = xpBar(&ui, &model, "boba", 100);
    // Level 2 needs 80; 40 into it is half-way.
    try std.testing.expectEqual(@as(f32, 50), bar.nodes[0].widget.layout.min_size.width);
    try std.testing.expectEqualStrings("Lv 2", levelLabel(&model, "boba", 0));
    try std.testing.expectEqualStrings("Lv 1", levelLabel(&model, "ghost-ai", 1));
}
