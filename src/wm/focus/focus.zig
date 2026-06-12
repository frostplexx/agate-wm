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
/// Records the focus path so each ancestor remembers `leaf` as its active branch.
pub fn focusLeaf(leaf: *data.Con) bool {
    const win = if (leaf.window) |*w| w else return false;
    if (!focusWindow(win)) return false;
    recordFocusPath(leaf);
    return true;
}

/// Walk up from `leaf`, marking each ancestor's `last_focused_child` to the child
/// on the path, so re-entering a container later restores this window.
fn recordFocusPath(leaf: *data.Con) void {
    var node: *data.Con = leaf;
    while (node.parent) |parent| : (node = parent) {
        parent.last_focused_child = node;
    }
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
/// frontmost app's focused window, matched back to a tree leaf. Null if it can't
/// be determined or the app owns no tracked window.
///
/// Resolution is layered because `AXFocusedWindow` is unreliable for some apps —
/// notably Ghostty, which can hand back an auxiliary window that isn't a tree
/// leaf (the same quirk the dialog heuristic special-cases). When that wid isn't
/// in the tree, fall back to `AXMainWindow`, then to *any* tree leaf owned by the
/// frontmost pid. Without these fallbacks every window op (move/swap, resize,
/// layout) silently no-ops whenever such an app is frontmost.
pub fn currentFocusedLeaf(appState: *state.AppState) ?*data.Con {
    const root = appState.tree orelse return null;
    const pid = macos.workspace.frontmostAppPid() orelse return null;
    const app = macos.Element.createApplication(pid) orelse return null;
    defer app.release();

    if (leafFromWindowAttr(root, app, "AXFocusedWindow")) |leaf| return leaf;
    if (leafFromWindowAttr(root, app, "AXMainWindow")) |leaf| return leaf;
    return firstLeafForPid(root, pid);
}

/// The tree leaf for the window held by the app's `attr` (e.g. "AXFocusedWindow"),
/// or null if the attribute is absent or its window isn't tracked.
fn leafFromWindowAttr(root: *data.Con, app: *macos.Element, attr: []const u8) ?*data.Con {
    const win = app.copyElement(attr) orelse return null;
    defer win.release();
    const wid = win.windowId() orelse return null;
    return tree.findLeaf(root, wid);
}

/// The first leaf anywhere under `con` whose window is owned by `pid`, or null.
fn firstLeafForPid(con: *data.Con, pid: i32) ?*data.Con {
    if (con.window) |w| if (w.pid == pid) return con;
    for (con.children.items) |child| {
        if (firstLeafForPid(child, pid)) |leaf| return leaf;
    }
    return null;
}

/// Move focus to the nearest window in `dir`, descending into and ascending out
/// of nested containers (i3-style directional focus). Left/right traverse
/// horizontal splits/stacks; up/down traverse vertical ones. From the focused
/// leaf we walk up until an ancestor has a neighbour along the requested axis,
/// then descend into that neighbour to the leaf nearest the edge we enter from.
/// Returns true if focus moved (no wrap-around at the edges).
pub fn focusDirection(appState: *state.AppState, dir: Direction) bool {
    const cur = currentFocusedLeaf(appState) orelse return false;
    const horizontal = dir == .left or dir == .right;
    const forward = dir == .right or dir == .down;

    var node = cur;
    while (node.parent) |parent| : (node = parent) {
        const axis_matches = if (horizontal)
            (parent.layout == .H_SPLIT or parent.layout == .H_STACK)
        else
            (parent.layout == .V_SPLIT or parent.layout == .V_STACK);
        if (!axis_matches) continue; // perpendicular split — keep climbing
        if (tree.adjacentSibling(node, forward)) |sib| {
            return focusLeaf(descendToLeaf(sib, forward));
        }
        // Axis matches but `node` is at the edge — climb and try a higher level.
    }
    return false;
}

/// Cycle focus to the next (`forward`) or previous sibling of the focused
/// window, wrapping at the edges — the Small-Screen-Mode motion: in an
/// accordion every window is one swipe step away, and unlike `focusDirection`
/// it never dead-ends at the edge. Cycles within the focused leaf's parent
/// (the workspace for a flat layout, the sub-container for a nested stack).
/// With nothing focused, falls back to the first leaf of the active workspace.
pub fn cycleFocus(appState: *state.AppState, forward: bool) bool {
    const cur = currentFocusedLeaf(appState) orelse {
        const root = appState.tree orelse return false;
        const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return false;
        const ws = tree.findWorkspace(root, sid) orelse return false;
        if (ws.children.items.len == 0) return false;
        return focusLeaf(descendToLeaf(ws.children.items[0], true));
    };
    const parent = cur.parent orelse return false;
    const n = parent.children.items.len;
    if (n < 2) return false;
    const i = tree.childIndexOf(parent, cur) orelse return false;
    const next = if (forward) (i + 1) % n else (i + n - 1) % n;
    return focusLeaf(descendToLeaf(parent.children.items[next], forward));
}

/// Descend `con` to a leaf. At each level prefer the container's last-focused
/// child (so re-entering restores the most-recently-active window); otherwise,
/// when we reached it moving `forward`, take the first child (else the last).
/// Returns `con` unchanged if it's already a leaf.
fn descendToLeaf(con: *data.Con, forward: bool) *data.Con {
    var node = con;
    while (node.window == null and node.children.items.len > 0) {
        node = if (validLastFocused(node)) |lf|
            lf
        else if (forward)
            node.children.items[0]
        else
            node.children.items[node.children.items.len - 1];
    }
    return node;
}

/// `con`'s `last_focused_child` if it's still one of `con`'s children, else null
/// (the remembered window may have been closed or moved out).
fn validLastFocused(con: *data.Con) ?*data.Con {
    const lf = con.last_focused_child orelse return null;
    for (con.children.items) |c| if (c == lf) return lf;
    return null;
}
