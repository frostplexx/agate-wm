//! Window-management actions: the verbs the Lua API and string commands drive —
//! setting a layout, applying gaps, sending a window to another Space or monitor,
//! and toggling zoom-fullscreen. These take an `AppState` and mutate the tree;
//! the Lua marshalling that calls them lives in `api.zig` / `keybind.zig`.
const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const focus = @import("../wm/focus/focus.zig");
const tree = @import("../wm/tree.zig");
const data = @import("../wm/data.zig");
const window = @import("../wm/window.zig");
const parse = @import("parse.zig");

/// Rewrite every workspace and nested split container's gaps to the configured
/// values, leaving leaf cons untouched (they don't carry the gaps the layout reads).
pub fn applyGapsToTree(con: *data.Con, gaps: f64, outer_gaps: f64, accordion: f64) void {
    if (con.con_type == .Workspace or (con.con_type == .Container and con.window == null)) {
        con.gaps = .{
            .inner = @intFromFloat(@max(0, gaps)),
            .outer = @intFromFloat(@max(0, outer_gaps)),
            .top = 0, .bottom = 0, .left = 0, .right = 0,
            .accordion = @intFromFloat(@max(0, accordion)),
        };
    }
    for (con.children.items) |child| applyGapsToTree(child, gaps, outer_gaps, accordion);
}

/// Set a layout by name and re-tile. Targets the *focused container* (the
/// focused leaf's parent) so a nested sub-container can be restyled on its own —
/// e.g. flip just the left stack to a split — falling back to the workspace when
/// focus can't be resolved. "toggle" flips the split orientation (H_SPLIT ↔
/// V_SPLIT); anything else maps via `parse.layoutFromName`.
pub fn setActiveLayout(app: *state.AppState, name: []const u8) void {
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(app.tree orelse return, sid) orelse return;
    const target = if (focus.currentFocusedLeaf(app)) |leaf| (leaf.parent orelse ws) else ws;
    if (std.mem.eql(u8, name, "toggle")) {
        target.layout = switch (target.layout) {
            .H_SPLIT => .V_SPLIT,
            .V_SPLIT => .H_SPLIT,
            else => .H_SPLIT, // from a stack/float, toggle returns to horizontal tiling
        };
    } else {
        target.layout = parse.layoutFromName(name) orelse return;
    }
    target.auto_small = false; // an explicit choice — Small Screen Mode keeps off it
    tree.flushActive(app);
}

/// Toggle "zoom fullscreen" for the focused window: flip its `fake_full_screen`
/// flag and re-tile. Layout (`place`) hands a flagged leaf the whole workspace
/// area instead of its tiled slot, so the window overlays the others until it's
/// toggled off; the tiling underneath is preserved. Direct port of yabai's
/// `window --toggle zoom-fullscreen` (not native macOS fullscreen — no separate
/// Space, no transition animation).
pub fn toggleZoomFullscreen(app: *state.AppState) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    if (leaf.window == null) return;
    const win = &leaf.window.?;
    win.fake_full_screen = !win.fake_full_screen;
    tree.flushActive(app);
    // While zoomed the window overlaps its siblings — keep it raised on top.
    if (win.fake_full_screen) _ = focus.focusLeaf(leaf);
}

/// Toggle "floating" for the focused window (yabai's `window --toggle float`):
/// flip its `floating` flag and re-tile. Layout skips a floating leaf, so the
/// remaining tiles reflow to fill the space while the window keeps its current
/// frame on top — free to be moved and resized without disturbing the tiling.
/// Toggling off drops it back into its slot and re-tiles. Raised when floated so
/// it sits above the tiles it now overlaps.
pub fn toggleFloat(app: *state.AppState) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    if (leaf.window == null) return;
    const win = &leaf.window.?;
    win.floating = !win.floating;
    tree.flushActive(app);
    if (win.floating) _ = focus.focusLeaf(leaf); // keep it raised above the tiles
}

/// Move the focused window to the Nth user space on the focused display.
pub fn moveFocusedToSpace(app: *state.AppState, n: usize) void {
    const target_sid = (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, n) catch return) orelse return;
    moveFocusedToSpaceId(app, target_sid);
}

/// Move the focused window to user space `n` on the display at `monitor`
/// (1-based, display order). Lets the window land on another monitor's Space.
pub fn moveFocusedToSpaceOnMonitor(app: *state.AppState, monitor: usize, n: usize) void {
    if (monitor < 1) return;
    const target_sid = (macos.spaces.userSpaceIdOnDisplay(app.gpa, app.skylight_cid, monitor - 1, n) catch return) orelse return;
    moveFocusedToSpaceId(app, target_sid);
}

/// Reassign the focused window to space `target_sid` via the SkyLight SPI, then
/// sync our tree by relocating the leaf into the destination workspace and
/// relaying out both the (now-shrunk) source and the destination — within each
/// one's own display frame. No-op when the window is already there.
pub fn moveFocusedToSpaceId(app: *state.AppState, target_sid: u64) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    const win = if (leaf.window) |w| w else return;
    const cur_ws = leaf.parent orelse return; // Workspace Con; .id == SkyLight sid
    if (target_sid == cur_ws.id) return; // already there — don't issue the SPI
    // A native-fullscreen window can't be sent to a regular Space while it's
    // fullscreen — exit fullscreen first, then finish the move once it lands on
    // a user Space (see `runPendingMove`).
    if (deferIfFullscreen(app, leaf, win.id, target_sid)) return;
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    // The tree's children lists are arena-allocated — growing them with any
    // other allocator would free arena memory through it (undefined behavior).
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
    tree.flushActive(app); // re-tile the source we just shrank
    tree.flushWorkspace(app, dst_ws); // and slot the moved window into the destination's row

    // Keep the moved window selected once its Space is shown (yabai-style): the
    // space-change handler blanket-focuses a tile to pull the menu bar over, so
    // arm a pending focus on this window for the destination Space instead.
    app.pending_focus = .{ .wid = win.id, .sid = target_sid };
}

/// Move the focused window to the visible Space of the display `dir` selects,
/// re-tile both displays, and follow focus to the window on its new monitor.
/// Because the destination Space is already on-screen there, the window appears
/// and can be focused immediately (no deferred `pending_focus`).
pub fn moveFocusedToMonitor(app: *state.AppState, dir: focus.MonitorDir) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    const win = if (leaf.window) |w| w else return;

    var buf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const count = tree.collectMonitors(app, &buf);
    if (count < 2) return;
    const mons = buf[0..count];

    const cur_mon = tree.monitorOf(leaf) orelse (focus.currentMonitor(app) orelse return);
    var ci: usize = 0;
    for (mons, 0..) |m, i| if (m.con == cur_mon) {
        ci = i;
        break;
    };
    const ti = focus.monitorTarget(mons, ci, dir) orelse return;
    if (ti == ci) return;

    const target_sid = mons[ti].current_space;
    if (target_sid == 0) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    if (dst_ws == leaf.parent) return;
    // Native fullscreen: exit it first, then finish the move (see runPendingMove).
    if (deferIfFullscreen(app, leaf, win.id, target_sid)) return;
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;

    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
    tree.flushActive(app); // re-tile the source we shrank
    tree.flushWorkspace(app, dst_ws); // tile the destination
    _ = focus.focusLeaf(leaf); // the window is visible there now — follow it
}

/// If `leaf`'s window is on a native-fullscreen Space, leave fullscreen and
/// record the move to finish once it returns to a user Space. Returns true when
/// it deferred (the caller must not proceed with the move this turn).
fn deferIfFullscreen(app: *state.AppState, leaf: *data.Con, wid: u32, target_sid: u64) bool {
    const ws = tree.workspaceOf(leaf) orelse return false;
    if (ws.space_type == 0) return false; // a normal window — move it directly
    const win = if (leaf.window) |*w| w else return false;
    const el = window.resolveElement(win) orelse return false;
    if (!el.setBool("AXFullScreen", false)) return false; // couldn't exit — let caller try
    app.pending_move = .{ .wid = wid, .target_sid = target_sid };
    std.debug.print("[move] #{d} leaving fullscreen; move to {d} deferred\n", .{ wid, target_sid });
    return true;
}

/// Carry out a move deferred by `deferIfFullscreen`, once the window has left
/// the fullscreen Space and is back on a user Space. Called from the
/// space-change handler. No-op while the window is still transitioning.
pub fn runPendingMove(app: *state.AppState) void {
    const pm = app.pending_move orelse return;
    const root = app.tree orelse return;
    const leaf = tree.findLeaf(root, pm.wid) orelse {
        app.pending_move = null; // window gone
        return;
    };
    const src_ws = tree.workspaceOf(leaf) orelse return;
    if (src_ws.space_type != 0) return; // still on a fullscreen/transition Space — wait
    app.pending_move = null;
    if (src_ws.id == pm.target_sid) return; // already landed on the target
    if (!macos.spaces.moveWindowToSpace(pm.wid, pm.target_sid)) return;
    const dst = tree.findWorkspace(root, pm.target_sid) orelse return;
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst);
    tree.flushWorkspace(app, src_ws); // re-tile the Space it returned to
    tree.flushWorkspace(app, dst); // tile the destination
    app.pending_focus = .{ .wid = pm.wid, .sid = pm.target_sid };
    std.debug.print("[move] fullscreen exited; #{d} -> space {d}\n", .{ pm.wid, pm.target_sid });
}
