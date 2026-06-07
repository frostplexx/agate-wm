//! Focus engine — which window is "active", and the primitives that change it.
//!
//! Scope so far:
//!   1. `focusAfterClose` — when a window closes and it was the *last* window of
//!      its app on the active workspace, move focus to the tile on its left
//!      (the previous slot). This is the yabai behaviour: focus never falls onto
//!      a random app just because an app's last window went away.
//!   2. `focusWindow` / `focusLeaf` / `focusDirection` — the reusable primitives
//!      for *changing* focus between windows (and therefore between apps). These
//!      are the hooks a keybinding layer will drive later; nothing binds keys to
//!      them yet.
//!
//! Focusing is AX-driven: make the owning app frontmost (`AXFrontmost`) and the
//! window key (`AXMain` + `AXFocused`), then raise it (`AXRaise`). yabai does the
//! equivalent through the private `_SLPSSetFrontProcessWithOptions` +
//! `SLPSPostEventRecordTo` SkyLight path (both verified present on macOS 26); if
//! AX focus proves flaky for stubborn apps, that's the documented hardening path
//! — it needs a Carbon `ProcessSerialNumber` (via `GetProcessForPID`) for the
//! target pid, which is why we start with the simpler self-contained AX route.
const std = @import("std");
const macos = @import("macos");
const data = @import("../data.zig");
const window = @import("../window.zig");
const tree = @import("../tree.zig");
const state = @import("../../state.zig");

/// A focus direction for `focusDirection`. With today's flat horizontal layout
/// left/up map to the previous tile and right/down to the next.
pub const Direction = enum { left, right, up, down };

/// Raise `win` and make its application frontmost so it becomes the focused
/// window. Returns true if either the app or the window accepted focus.
pub fn focusWindow(win: *data.Window) bool {
    const el = window.resolveElement(win) orelse return false;

    // Bring the owning app to the front first; raising the window while another
    // app is key would not actually move focus.
    var app_ok = false;
    if (macos.Element.createApplication(win.pid)) |app| {
        defer app.release();
        app_ok = app.setBool("AXFrontmost", true);
    }

    _ = el.setBool("AXMain", true);
    const focused = el.setBool("AXFocused", true);
    _ = el.performAction("AXRaise");
    return app_ok or focused;
}

/// Focus the window held by `leaf` (a Container Con). No-op for non-leaf Cons.
pub fn focusLeaf(leaf: *data.Con) bool {
    const win = if (leaf.window) |*w| w else return false;
    return focusWindow(win);
}

/// A window owned by `closed_pid` was just removed from workspace `ws`, where it
/// had occupied slot `closed_index`. If that app has no windows left on `ws`,
/// move focus to the tile on its left (the previous slot), falling back to the
/// new leftmost tile. No-op if the app still owns a window here (macOS keeps
/// focus within the app) or the workspace is now empty.
pub fn focusAfterClose(ws: *data.Con, closed_pid: i32, closed_index: usize) void {
    // App still has a window on this space → leave focus to the OS (it stays
    // within the app, which is what the user expects).
    for (ws.children.items) |child| {
        if (child.window) |w| if (w.pid == closed_pid) return;
    }
    if (ws.children.items.len == 0) return; // nothing left to focus

    // The slot to the left of the one that closed, clamped into range.
    const target = if (closed_index > 0) closed_index - 1 else 0;
    const idx = @min(target, ws.children.items.len - 1);
    _ = focusLeaf(ws.children.items[idx]);
}

/// The leaf holding the currently focused window, resolved live from the OS: the
/// frontmost app's `AXFocusedWindow`, matched back to a tree leaf. Null if it
/// can't be determined or the window isn't tracked.
pub fn currentFocusedLeaf(appState: *state.AppState) ?*data.Con {
    const root = appState.tree orelse return null;
    const pid = macos.workspace.frontmostAppPid() orelse return null;
    const app = macos.Element.createApplication(pid) orelse return null;
    defer app.release();
    const focused = app.copyElement("AXFocusedWindow") orelse return null;
    defer focused.release();
    const wid = focused.windowId() orelse return null;
    return tree.findLeaf(root, wid);
}

/// Move focus to the tile adjacent to the focused one in the active workspace.
/// This is the building block for "focus the app to my left/right" once
/// keybindings exist. With the current flat layout, left/up step to the previous
/// sibling and right/down to the next. Returns true if focus moved.
pub fn focusDirection(appState: *state.AppState, dir: Direction) bool {
    const cur = currentFocusedLeaf(appState) orelse return false;
    const parent = cur.parent orelse return false;

    var idx: ?usize = null;
    for (parent.children.items, 0..) |child, i| {
        if (child == cur) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return false;

    const forward = dir == .right or dir == .down;
    const target = if (forward) i + 1 else (if (i > 0) i - 1 else return false);
    if (target >= parent.children.items.len) return false;
    return focusLeaf(parent.children.items[target]);
}
