const macos = @import("macos");
const data = @import("../data.zig");
const window = @import("../window.zig");
const tree = @import("../tree.zig");
const state = @import("../../state.zig");

/// A focus direction for `focusDirection`. With today's flat horizontal layout
/// left/up map to the previous tile and right/down to the next.
pub const Direction = enum { left, right, up, down };

/// How to pick a target monitor in `focusMonitor` / move-to-monitor: cycle
/// through displays in window-server order (`next`/`prev`), or step to the
/// physically adjacent display in a direction (`left`/`right`/`up`/`down`).
pub const MonitorDir = enum { next, prev, left, right, up, down };

/// Warp the mouse cursor to a point (global top-left CG coordinates, the same
/// space the tree's frames live in). Used to land focus on an *empty* display
/// where there's no window to raise.
extern fn CGWarpMouseCursorPosition(point: macos.c.CGPoint) c_int;

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

/// Record `leaf` as the focused window *without* touching the OS — the window is
/// already focused (e.g. the user clicked it), we just need the tree to remember
/// which column to keep in view. Calling `focusLeaf` here would re-assert AX focus
/// and risk a focus-change feedback loop; this only updates the breadcrumb path.
pub fn markFocused(leaf: *data.Con) void {
    recordFocusPath(leaf);
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

/// Whether `pid` owns any window leaf under `con`. Used to decide whether focus
/// is already on the right space (so the WM shouldn't override it).
pub fn pidHasWindowUnder(con: *data.Con, pid: i32) bool {
    return firstLeafForPid(con, pid) != null;
}

/// Focus the most-recently-used window under workspace `ws` (descending through
/// each container's `last_focused_child`), falling back to the first tile that
/// accepts focus. Unlike focusing `children[0]` blindly, this restores the
/// window the user last had here rather than forcing a fixed tile to the front.
/// Returns false only if nothing under `ws` accepts focus.
pub fn focusMostRecent(ws: *data.Con) bool {
    if (ws.children.items.len == 0) return false;
    const start = validLastFocused(ws) orelse ws.children.items[0];
    if (focusLeaf(descendToLeaf(start, true))) return true;
    for (ws.children.items) |child| {
        if (focusLeaf(descendToLeaf(child, true))) return true;
    }
    return false;
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
        // A Flow strip (SCROLL) is a horizontal axis: left/right step between
        // columns; up/down fall through to the column's internal vertical split.
        const axis_matches = if (horizontal)
            (parent.layout == .H_SPLIT or parent.layout == .H_STACK or parent.layout == .SCROLL)
        else
            (parent.layout == .V_SPLIT or parent.layout == .V_STACK);
        if (!axis_matches) continue; // perpendicular split — keep climbing
        if (tree.adjacentSibling(node, forward)) |sib| {
            const ok = focusLeaf(descendToLeaf(sib, forward));
            if (ok) scrollFlushIfNeeded(appState);
            return ok;
        }
        // Axis matches but `node` is at the edge — climb and try a higher level.
    }
    return false;
}

/// Focus the first (`last=false`) or last column of the focused window's Flow
/// strip, descending into the column to its edge leaf. Returns false when there
/// is nothing to focus. The follow-up flush scrolls the strip into view.
pub fn focusColumnEdge(appState: *state.AppState, last: bool) bool {
    const root = appState.tree orelse return false;
    const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return false;
    const ws = tree.findWorkspace(root, sid) orelse return false;
    if (ws.children.items.len == 0) return false;
    const idx = if (last) ws.children.items.len - 1 else 0;
    const ok = focusLeaf(descendToLeaf(ws.children.items[idx], !last));
    if (ok) scrollFlushIfNeeded(appState);
    return ok;
}

/// After a focus move, re-tile the focused window's workspace if it's a Flow
/// strip so `layoutScroll` scrolls the now-focused column into view. A no-op for
/// classic layouts (their flush wouldn't move anything, so we skip the AX churn).
fn scrollFlushIfNeeded(appState: *state.AppState) void {
    const leaf = currentFocusedLeaf(appState) orelse return;
    const ws = tree.workspaceOf(leaf) orelse return;
    if (ws.layout == .SCROLL) tree.flushWorkspace(appState, ws);
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
    const ok = focusLeaf(descendToLeaf(parent.children.items[next], forward));
    if (ok) scrollFlushIfNeeded(appState);
    return ok;
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

/// The Monitor Con the focus currently lives on: the focused window's monitor,
/// falling back to the focused display's visible workspace's monitor.
pub fn currentMonitor(appState: *state.AppState) ?*data.Con {
    if (currentFocusedLeaf(appState)) |leaf| {
        if (tree.monitorOf(leaf)) |m| return m;
    }
    const root = appState.tree orelse return null;
    const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return null;
    const ws = tree.findWorkspace(root, sid) orelse return null;
    return tree.monitorOf(ws);
}

/// The maximum number of displays `focusMonitor` / monitor moves consider.
pub const max_monitors = 16;

/// Move keyboard focus to another monitor selected by `dir` (cycle order, or
/// the physically adjacent display). Focuses the most-recently-used window on
/// that display's visible Space; if it has none, warps the cursor to its centre
/// so the display still becomes active. Returns false with fewer than two
/// displays or when no display lies in the requested direction.
pub fn focusMonitor(appState: *state.AppState, dir: MonitorDir) bool {
    var buf: [max_monitors]tree.MonitorInfo = undefined;
    const n = tree.collectMonitors(appState, &buf);
    if (n < 2) return false;
    const mons = buf[0..n];

    const cur = currentMonitor(appState);
    var ci: usize = 0;
    if (cur) |c| {
        for (mons, 0..) |m, i| if (m.con == c) {
            ci = i;
            break;
        };
    }

    const target = monitorTarget(mons, ci, dir) orelse return false;
    if (target == ci) return false;
    return focusMonitorInfo(appState, mons[target]);
}

/// Resolve the index of the monitor `dir` selects from `mons`, relative to the
/// monitor at `ci`. Null when nothing lies in a directional request.
pub fn monitorTarget(mons: []const tree.MonitorInfo, ci: usize, dir: MonitorDir) ?usize {
    const n = mons.len;
    return switch (dir) {
        .next => (ci + 1) % n,
        .prev => (ci + n - 1) % n,
        .left, .right, .up, .down => spatialTarget(mons, ci, dir),
    };
}

/// The nearest monitor whose centre lies in `dir` from `mons[ci]`'s centre
/// (top-left coordinates: up = smaller y). Null if none does.
fn spatialTarget(mons: []const tree.MonitorInfo, ci: usize, dir: MonitorDir) ?usize {
    const cur = mons[ci].frame;
    const cx = cur.origin.x + cur.size.width / 2;
    const cy = cur.origin.y + cur.size.height / 2;

    var best: ?usize = null;
    var best_dist: f64 = 0;
    for (mons, 0..) |m, i| {
        if (i == ci) continue;
        const mx = m.frame.origin.x + m.frame.size.width / 2;
        const my = m.frame.origin.y + m.frame.size.height / 2;
        const dx = mx - cx;
        const dy = my - cy;
        const ok = switch (dir) {
            .left => dx < -1,
            .right => dx > 1,
            .up => dy < -1,
            .down => dy > 1,
            else => false,
        };
        if (!ok) continue;
        const dist = dx * dx + dy * dy;
        if (best == null or dist < best_dist) {
            best = i;
            best_dist = dist;
        }
    }
    return best;
}

/// Focus the most-recently-used window on `mi`'s visible Space, or warp the
/// cursor to the display's centre when it has no window to focus.
fn focusMonitorInfo(appState: *state.AppState, mi: tree.MonitorInfo) bool {
    const root = appState.tree orelse return warpToFrame(mi.frame);
    const ws = tree.findWorkspace(root, mi.current_space) orelse return warpToFrame(mi.frame);
    if (ws.children.items.len == 0) return warpToFrame(mi.frame);

    const start = validLastFocused(ws) orelse ws.children.items[0];
    if (focusLeaf(descendToLeaf(start, true))) return true;
    for (ws.children.items) |child| {
        if (focusLeaf(descendToLeaf(child, true))) return true;
    }
    return warpToFrame(mi.frame);
}

fn warpToFrame(frame: macos.window_list.Rect) bool {
    _ = CGWarpMouseCursorPosition(.{
        .x = frame.origin.x + frame.size.width / 2,
        .y = frame.origin.y + frame.size.height / 2,
    });
    return true;
}
