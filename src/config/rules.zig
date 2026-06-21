//! Window assignment rules (`agate.rule{...}`, yabai's `rule --add`): match a
//! freshly tracked window by app name / title regex and send it to a Space (and
//! optionally a monitor). Registration lives in `api.agateRule`; this file owns
//! the matching and the effect.
const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const focus = @import("../wm/focus/focus.zig");
const tree = @import("../wm/tree.zig");
const window = @import("../wm/window.zig");
const data = @import("../wm/data.zig");
const regexp = @import("../lib/regexp.zig");
const types = @import("types.zig");
const ctx = @import("context.zig");

pub fn freeRule(alloc: std.mem.Allocator, rule: types.Rule) void {
    if (rule.app) |re| re.deinit();
    if (rule.title) |re| re.deinit();
    if (rule.space_name) |n| alloc.free(n);
}

/// Match `re` against a non-sentinel slice by copying it into a stack buffer
/// with a NUL (regexec wants a C string). Over-long input is truncated, which
/// can only affect `$`-anchored patterns on pathological titles.
fn regexMatches(re: regexp.Regex, s: []const u8) bool {
    var buf: [512]u8 = undefined;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return re.matches(buf[0..len :0]);
}

/// The combined effect of every rule matching this window, or null if none
/// does. Later rules override earlier ones, like yabai's effect combining.
fn matchRules(app_name: []const u8, title: []const u8) ?struct { space: usize, monitor: usize, follow: bool, floating: bool } {
    const cfg = ctx.config orelse return null;
    var space: usize = 0;
    var monitor: usize = 0;
    var follow = false;
    var floating = false;
    for (cfg.rules.items) |r| {
        if (r.app) |re| {
            if (!regexMatches(re, app_name)) continue;
        }
        if (r.title) |re| {
            if (!regexMatches(re, title)) continue;
        }
        // A named space resolves here, at match time, so the rule tracks a name
        // remapped on docking; an unknown name voids only this rule's Space effect.
        if (r.space_name) |name| {
            if (ctx.lookupNamedSpace(name)) |ns| {
                space = ns.space;
                monitor = ns.monitor;
            } else {
                space = 0;
                monitor = 0;
            }
        } else {
            space = r.space;
            monitor = r.monitor;
        }
        follow = r.follow;
        floating = r.floating;
    }
    // Nothing actionable matched: no Space assignment and no float request.
    if (space == 0 and !floating) return null;
    return .{ .space = space, .monitor = monitor, .follow = follow, .floating = floating };
}

/// Apply assignment rules to a freshly tracked window: if a rule matches, send
/// the window to the rule's Space (same SPI path as `actions.moveFocusedToSpace`)
/// and relocate its leaf into the destination workspace. The caller is expected
/// to re-flush the source workspace afterwards (the observer's create paths
/// always do). `title` is the window's AX title at detection time.
pub fn applyRulesToLeaf(app: *state.AppState, leaf: *data.Con, title: []const u8) void {
    applyRulesToLeafFollow(app, leaf, title, true);
}

/// As `applyRulesToLeaf`, but `do_follow` gates whether a matched rule switches
/// the user to the destination Space. The create paths pass true (opening an app
/// takes you to it). Startup placement (`applyRulesToTree`) passes false: it
/// re-homes every already-open window to its assigned Space without yanking the
/// view through each one.
pub fn applyRulesToLeafFollow(app: *state.AppState, leaf: *data.Con, title: []const u8, do_follow: bool) void {
    const win = if (leaf.window) |w| w else return;
    const eff = matchRules(win.owner, title) orelse return;

    // Float lifts the window out of the tiling; set it first so the flag travels
    // with the leaf if the rule also reassigns its Space below. With no Space
    // assignment this is the rule's whole effect — the caller's re-flush of the
    // active Space reflows the remaining tiles around the now-floating window.
    if (eff.floating) {
        leaf.window.?.floating = true;
        std.debug.print("[rule] {s} #{d} -> floating\n", .{ win.owner, win.id });
        if (eff.space == 0) return;
    }

    const cur_ws = leaf.parent orelse return; // new leaves sit directly under their Workspace
    // A `monitor` makes `space` count on that display (1-based); else the
    // focused display, the original behaviour.
    const target_sid = blk: {
        if (eff.monitor >= 1) {
            // `monitor` is 1-based spatial arrangement; map to the window-server
            // display_index the Space query wants.
            const di = macos.monitor.displayIndexForArrangement(app.skylight_cid, eff.monitor) orelse return;
            break :blk (macos.spaces.userSpaceIdOnDisplay(app.gpa, app.skylight_cid, di, eff.space) catch return) orelse return;
        }
        break :blk (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, eff.space) catch return) orelse return;
    };
    if (target_sid == cur_ws.id) return; // already on the assigned space
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws); // arena: see actions.moveFocusedToSpace
    tree.flushWorkspace(app, dst_ws);
    std.debug.print("[rule] {s} #{d} -> space {d} (monitor {d})\n", .{ win.owner, win.id, eff.space, eff.monitor });
    // Mute activation-follow for this window either way: the app activates
    // around its own launch, and the follow chasing the window we just routed
    // would switch the user a second time (racing the gesture below and able to
    // overshoot) — or, for a follow-less rule, switch them against its intent.
    app.rule_moved = .{ .wid = win.id, .at = macos.c.CFAbsoluteTimeGetCurrent() };
    if (do_follow and eff.follow) {
        // The window is already moved and tiled (flushed above), so the user
        // lands on a settled Space. Keep the window selected once it's shown.
        app.pending_focus = .{ .wid = win.id, .sid = target_sid };
        if (eff.monitor >= 1) {
            // `switchToSpaceId` only drives the *focused* display. For a
            // monitor-targeted rule, focus the window directly — when that
            // display already shows the target Space it's on-screen, so focus
            // (and the menu bar) move there; otherwise `pending_focus` keeps it
            // selected for when the Space is next shown.
            _ = focus.focusLeaf(leaf);
        } else {
            macos.spaces.switchToSpaceId(app.gpa, app.skylight_cid, target_sid) catch {};
        }
    }
}

/// Apply the assignment rules to every window already tracked in the tree, e.g.
/// at startup — so an app that was already open when agate launched (or when the
/// daemon was restarted) is re-homed to its assigned Space/monitor, not just one
/// opened afterwards (which the create path handles). Follow is suppressed: this
/// silently relocates windows without switching the user through each Space.
///
/// Leaves are collected first because `applyRulesToLeafFollow` re-parents them
/// (moves them between Workspace cons), which would invalidate a live tree walk.
pub fn applyRulesToTree(app: *state.AppState) void {
    const root = app.tree orelse return;
    var leaves: std.ArrayList(*data.Con) = .empty;
    defer leaves.deinit(app.gpa);
    collectLeaves(root, &leaves, app.gpa);

    for (leaves.items) |leaf| {
        // Resolve the window's current title (best effort) so title-matched rules
        // work at startup too; app-only rules don't need it.
        var tbuf: [256]u8 = undefined;
        var title: []const u8 = "";
        if (leaf.window) |*w| {
            if (window.resolveElement(w)) |el| {
                if (el.copyString("AXTitle")) |t| {
                    defer t.release();
                    if (t.cstring(&tbuf)) |s| title = s;
                }
            }
        }
        applyRulesToLeafFollow(app, leaf, title, false);
    }
}

/// Append every leaf (real-window Con) under `con` to `out`.
fn collectLeaves(con: *data.Con, out: *std.ArrayList(*data.Con), gpa: std.mem.Allocator) void {
    if (con.window != null) {
        out.append(gpa, con) catch {};
        return;
    }
    for (con.children.items) |child| collectLeaves(child, out, gpa);
}
