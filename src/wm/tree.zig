const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");
const window = @import("window.zig");
const layout = @import("layout.zig");
const state = @import("../state.zig");

const Allocator = std.mem.Allocator;

/// Default gaps applied to each workspace until config exists.
const default_gaps: data.Gaps = .{ .inner = 10, .outer = 10, .top = 0, .bottom = 0, .left = 0, .right = 0, .accordion = 40 };

/// Upper bound on physical displays, for the stack buffers the display-geometry
/// queries fill (no machine has nearly this many; matches `focus.max_monitors`).
const max_displays = 16;

/// Allocate and initialize a single Con node.
fn makeCon(alloc: Allocator, con_type: data.Con.Type, parent: ?*data.Con, depth: u32, id: u64) !*data.Con {
    const con = try alloc.create(data.Con);
    con.* = .{
        .id = id,
        .con_type = con_type,
        .parent = parent,
        .depth = depth,
    };
    return con;
}

/// Build the full container tree by reconciling SkyLight's per-Space window
/// lists against CoreGraphics window metadata:
///
///   Root → Monitor (per display) → Workspace (per Space) → Container (leaf,
///   one per managed window).
///
/// Windows across *every* Space and display are included. All nodes are
/// allocated with `alloc`; the caller owns the tree (use an arena to free it
/// in one shot). Returns the root Con.
pub fn build_tree(alloc: Allocator, cid: u32) !*data.Con {
    // wid -> CG metadata (owner/pid/bounds); spans all Spaces and displays.
    var meta = std.AutoHashMap(u32, macos.window_list.WindowInfo).init(alloc);
    defer meta.deinit();
    for (try macos.window_list.listAll(alloc)) |info| try meta.put(info.id, info);

    const root = try makeCon(alloc, .Root, null, 0, 0);

    // One Monitor Con per physical display, keyed by display index.
    var monitors = std.AutoHashMap(usize, *data.Con).init(alloc);
    defer monitors.deinit();

    for (try macos.spaces.allSpaces(alloc, cid)) |sp| {
        const gop = try monitors.getOrPut(sp.display_index);
        if (!gop.found_existing) {
            const mon = try makeCon(alloc, .Monitor, root, 1, @intCast(sp.display_index));
            try root.children.append(alloc, mon);
            gop.value_ptr.* = mon;
        }
        const monitor = gop.value_ptr.*;

        const workspace = try makeCon(alloc, .Workspace, monitor, 2, sp.id);
        workspace.gaps = default_gaps;
        workspace.layout = .SCROLL; // every workspace is a Flow strip
        workspace.space_type = sp.type;
        try monitor.children.append(alloc, workspace);

        for (try macos.spaces.manageableWindowsOnSpace(alloc, cid, sp.id)) |wid| {
            const info = meta.get(wid) orelse continue;
            // Non-zero layers are system chrome (menu bar, Dock overlays, etc.).
            if (info.layer != 0) continue;
            const win = window.init(info);
            // Skip windows that aren't "ordered in" (mapped): background macOS
            // native tabs, minimized and hidden windows. The front tab of a tab
            // group is ordered in, so each group contributes one leaf. (Windows
            // on inactive Spaces are still ordered in, so this doesn't hide them.)
            if (!window.isOrderedIn(&win)) continue;
            _ = try addLeaf(alloc, workspace, win);
        }
    }

    return root;
}

/// The Monitor Con for display index `idx`, or null.
pub fn findMonitor(root: *data.Con, idx: usize) ?*data.Con {
    for (root.children.items) |c| {
        if (c.con_type == .Monitor and c.id == @as(u64, idx)) return c;
    }
    return null;
}

/// Find or create the Monitor Con for display index `idx` (its `id`).
pub fn ensureMonitor(alloc: Allocator, root: *data.Con, idx: usize) !*data.Con {
    if (findMonitor(root, idx)) |m| return m;
    const mon = try makeCon(alloc, .Monitor, root, 1, @intCast(idx));
    try root.children.append(alloc, mon);
    return mon;
}

/// Add a new Workspace Con for SkyLight space `sid` under `mon`, with the
/// default gaps — the same shape `build_tree` creates.
pub fn addWorkspace(alloc: Allocator, mon: *data.Con, sid: u64, space_type: i64) !*data.Con {
    const ws = try makeCon(alloc, .Workspace, mon, 2, sid);
    ws.gaps = default_gaps;
    ws.layout = .SCROLL; // every workspace is a Flow strip
    ws.space_type = space_type;
    try mon.children.append(alloc, ws);
    return ws;
}

/// Reset a recycled Workspace Con for reuse under `mon` (keeps its children
/// buffer — empty when parked — so reuse allocates nothing).
fn resetWorkspace(ws: *data.Con, mon: *data.Con, sid: u64, space_type: i64) void {
    ws.children.clearRetainingCapacity();
    ws.id = sid;
    ws.con_type = .Workspace;
    ws.space_type = space_type;
    ws.window = null;
    ws.layout = .SCROLL; // every workspace is a Flow strip
    ws.scroll_offset = 0;
    ws.auto_small = false;
    ws.gaps = default_gaps;
    ws.parent = mon;
    ws.ratio = 1.0;
    ws.depth = mon.depth + 1;
    ws.last_focused_child = null;
}

/// Acquire a Workspace Con for `sid` under `mon`, recycling one from the pool if
/// available (else allocating a fresh one). Appends it to `mon`'s children.
fn acquireWorkspace(appState: *state.AppState, mon: *data.Con, sid: u64, space_type: i64) ?*data.Con {
    if (appState.workspace_pool.items.len > 0) {
        const ws = appState.workspace_pool.items[appState.workspace_pool.items.len - 1];
        appState.workspace_pool.items.len -= 1;
        resetWorkspace(ws, mon, sid, space_type);
        mon.children.append(appState.arena, ws) catch return null;
        return ws;
    }
    return addWorkspace(appState.arena, mon, sid, space_type) catch null;
}

/// Reconcile the tree's Workspace set against the window server's current
/// Spaces: add a (Monitor + ) Workspace Con for every Space we don't know yet,
/// and park *empty* Workspace Cons whose Space has vanished for reuse. This is
/// how agate picks up Spaces created while it runs — a new desktop, or the
/// dedicated Space macOS opens for a native-fullscreen window — which
/// `build_tree` only captured at startup. New workspaces start empty; windows
/// opened on them tile via the normal create path. A fullscreen Space is tracked
/// (so a window parked there is found) but never tiled (see `flushWorkspace`).
/// Returns true if the tree changed.
pub fn reconcileSpaces(appState: *state.AppState) bool {
    const root = appState.tree orelse return false;
    const all = macos.spaces.allSpaces(appState.gpa, appState.skylight_cid) catch return false;
    defer appState.gpa.free(all);

    var changed = false;
    for (all) |sp| {
        if (findWorkspace(root, sp.id) != null) continue;
        const mon = ensureMonitor(appState.arena, root, sp.display_index) catch continue;
        _ = acquireWorkspace(appState, mon, sp.id, sp.type) orelse continue;
        std.debug.print("[tree] +space {d} (display {d}, type {d})\n", .{ sp.id, sp.display_index, sp.type });
        changed = true;
    }
    if (pruneVanishedWorkspaces(appState, all)) changed = true;
    return changed;
}

/// Move every tracked window's leaf to the Workspace matching the Space it is
/// actually on now, using the window server's per-Space window lists (the
/// authoritative source). This is how agate follows a window that changed Space
/// without a create/destroy event — most importantly a window entering or
/// leaving native fullscreen, which silently relocates it to/from a fullscreen
/// Space. A window parked on a fullscreen Space's (non-tiled) Workspace is thus
/// left at full size; when it returns to a user Space its leaf comes back and
/// tiling resumes. Call after `reconcileSpaces` (so destination Workspaces
/// exist). Returns true if any leaf moved.
pub fn reconcileWindowSpaces(appState: *state.AppState) bool {
    const root = appState.tree orelse return false;
    const all = macos.spaces.allSpaces(appState.gpa, appState.skylight_cid) catch return false;
    defer appState.gpa.free(all);

    var changed = false;
    for (all) |sp| {
        const wids = macos.spaces.windowsOnSpace(appState.gpa, appState.skylight_cid, sp.id, true) catch continue;
        defer appState.gpa.free(wids);
        for (wids) |wid| {
            const leaf = findLeaf(root, wid) orelse continue; // not a window we track
            const cur_ws = workspaceOf(leaf) orelse continue;
            if (cur_ws.id == sp.id) continue; // already on the right Space
            const dst = findWorkspace(root, sp.id) orelse continue;
            if (moveLeafToWorkspace(appState.arena, leaf, dst)) changed = true;
        }
    }
    return changed;
}

/// Whether `sid` is among `spaces`.
fn spaceExists(spaces: []const macos.spaces.Space, sid: u64) bool {
    for (spaces) |sp| if (sp.id == sid) return true;
    return false;
}

/// Park *empty* Workspace Cons whose Space no longer exists (a closed desktop, a
/// fullscreen Space dismissed on exit) in the reuse pool. Non-empty workspaces
/// are left alone: their windows moved somewhere when the Space went away and
/// would otherwise be lost from tracking. Returns true if anything was removed.
fn pruneVanishedWorkspaces(appState: *state.AppState, spaces: []const macos.spaces.Space) bool {
    const root = appState.tree orelse return false;
    var changed = false;
    for (root.children.items) |mon| {
        if (mon.con_type != .Monitor) continue;
        var i: usize = 0;
        while (i < mon.children.items.len) {
            const ws = mon.children.items[i];
            if (ws.con_type == .Workspace and ws.children.items.len == 0 and !spaceExists(spaces, ws.id)) {
                _ = mon.children.orderedRemove(i);
                appState.workspace_pool.append(appState.gpa, ws) catch {}; // park for reuse
                changed = true;
                continue; // list shifted; re-check this index
            }
            i += 1;
        }
    }
    return changed;
}

/// Append a new leaf Con holding `win` under `ws`. Returns the leaf. The new
/// leaf takes the average of its siblings' ratios so existing (possibly
/// manually-resized) proportions are preserved and it slots in at a fair size.
pub fn addLeaf(alloc: Allocator, ws: *data.Con, win: data.Window) !*data.Con {
    const leaf = try makeCon(alloc, .Container, ws, ws.depth + 1, win.id);
    leaf.window = win;
    leaf.ratio = averageChildRatio(ws);
    try ws.children.append(alloc, leaf);
    return leaf;
}

/// Add a new window as its own column on a Flow strip, inserted immediately
/// after the column `after` (a direct child of `ws`), or appended to the trailing
/// edge when `after` is null or isn't a child of `ws`. The niri/paneru insertion
/// rule: a new window lands just right of the focused column rather than always at
/// the end. The new column keeps `width_frac = 0` (the layout uses the configured
/// default width) and neighbours keep theirs, so opening a window never resizes
/// the others.
pub fn insertColumnAfter(alloc: Allocator, ws: *data.Con, win: data.Window, after: ?*data.Con) !*data.Con {
    const leaf = try makeCon(alloc, .Container, ws, ws.depth + 1, win.id);
    leaf.window = win;
    leaf.ratio = 1.0;
    const at: usize = blk: {
        if (after) |a| if (childIndexOf(ws, a)) |i| break :blk i + 1;
        break :blk ws.children.items.len;
    };
    try ws.children.insert(alloc, at, leaf);
    return leaf;
}

/// Add a new window *into* the Flow-strip column `col` (a direct child of `ws`)
/// rather than as a fresh column, using the column's `layout` — the open side of
/// `agate.layout`'s "arm" (see `Con.split_armed`). When `col` is still a
/// lone-window leaf it's first wrapped in a split container (carrying the leaf's
/// armed layout, width, and slot), then the new window joins it; an existing
/// container column just gets the new leaf appended. Returns the new leaf.
pub fn addWindowToColumn(alloc: Allocator, col: *data.Con, win: data.Window) !*data.Con {
    // A lone-window column is a leaf: promote it to a split container in place.
    var container = col;
    if (col.window != null) {
        const ws = col.parent orelse return error.NoParent;
        const idx = childIndexOf(ws, col) orelse return error.NotAChild;
        container = try makeCon(alloc, .Container, ws, col.depth, 0);
        container.layout = col.layout; // the armed orientation (H_SPLIT by default)
        container.ratio = col.ratio;
        container.width_frac = col.width_frac; // keep the column's strip width
        container.gaps = ws.gaps; // inner gap / accordion peek
        container.split_armed = col.split_armed;
        // Reparent the existing window under the container as its first child.
        col.parent = container;
        col.depth = container.depth + 1;
        col.ratio = 1.0;
        col.width_frac = 0;
        col.split_armed = false;
        try container.children.append(alloc, col);
        ws.children.items[idx] = container; // container takes the column's slot
    }
    const leaf = try makeCon(alloc, .Container, container, container.depth + 1, win.id);
    leaf.window = win;
    leaf.ratio = 1.0;
    try container.children.append(alloc, leaf);
    return leaf;
}

/// The column (a direct child of workspace `ws`) that contains `leaf`, or null if
/// `leaf` isn't under `ws`. A column is either the leaf itself (a single-window
/// column) or the nested container holding it.
pub fn columnOf(ws: *data.Con, leaf: *data.Con) ?*data.Con {
    var node: *data.Con = leaf;
    while (node.parent) |parent| : (node = parent) {
        if (parent == ws) return node;
    }
    return null;
}

/// Eject `leaf` from its internal column-container into its own top-level column
/// on the strip (niri's "expel"), placed just after the container it left when
/// `forward`, else just before it. No-op when `leaf` is already its own column (a
/// direct child of the workspace) or its container isn't itself a direct
/// workspace column. Returns true if the tree changed (the caller re-flushes).
pub fn expelLeaf(alloc: Allocator, leaf: *data.Con, forward: bool) bool {
    const container = leaf.parent orelse return false;
    if (container.con_type == .Workspace) return false; // already its own column
    const ws = workspaceOf(leaf) orelse return false;
    if (container.parent != ws) return false; // only un-nest one level
    const ci = childIndexOf(ws, container) orelse return false;
    const li = childIndexOf(container, leaf) orelse return false;

    _ = container.children.orderedRemove(li);
    leaf.parent = ws;
    leaf.depth = ws.depth + 1;
    leaf.ratio = 1.0;
    leaf.width_frac = 0; // adopt the default column width
    ws.children.insert(alloc, if (forward) ci + 1 else ci, leaf) catch return false;
    collapseIfDegenerate(container); // the container may now have a single child
    return true;
}

/// Mean ratio of `con`'s children (1.0 if it has none).
fn averageChildRatio(con: *data.Con) f64 {
    const count = con.children.items.len;
    if (count == 0) return 1.0;
    var total: f64 = 0;
    for (con.children.items) |child| total += child.ratio;
    return total / @as(f64, @floatFromInt(count));
}

/// Remove the leaf holding window `wid` from anywhere under `con`. Releases the
/// window's AX element. Returns true if a leaf was removed.
pub fn removeWindow(con: *data.Con, wid: u64) bool {
    for (con.children.items, 0..) |child, i| {
        if (child.con_type == .Container) {
            if (child.window) |*w| {
                if (w.id == wid) {
                    w.deinit();
                    _ = con.children.orderedRemove(i);
                    collapseIfDegenerate(con); // flatten a now-single-child stack
                    return true;
                }
            }
        }
        if (removeWindow(child, wid)) return true;
    }
    return false;
}

/// Remove every leaf window owned by `pid` from anywhere under `con` (an app
/// terminated). Releases each window's AX element. Returns true if any leaf was
/// removed. Walks the children list defensively, re-checking after each removal
/// since `orderedRemove` shifts subsequent indices.
pub fn removeWindowsForPid(con: *data.Con, pid: i32) bool {
    var removed = false;
    var i: usize = 0;
    while (i < con.children.items.len) {
        const child = con.children.items[i];
        if (child.con_type == .Container) {
            if (child.window) |*w| {
                if (w.pid == pid) {
                    w.deinit();
                    _ = con.children.orderedRemove(i);
                    removed = true;
                    continue; // list shifted; re-check this index
                }
            }
        }
        if (removeWindowsForPid(child, pid)) removed = true;
        // `child` may now be a degenerate sub-container; flatten/drop it. A drop
        // shrinks the list, so re-check this index instead of advancing.
        const before = con.children.items.len;
        collapseIfDegenerate(child);
        if (con.children.items.len < before) continue;
        i += 1;
    }
    return removed;
}

/// Whether a leaf for window `wid` already exists under `con`.
pub fn hasWindow(con: *data.Con, wid: u64) bool {
    return findLeaf(con, wid) != null;
}

/// The index of `child` within `parent`'s children, or null if absent.
pub fn childIndexOf(parent: *data.Con, child: *data.Con) ?usize {
    for (parent.children.items, 0..) |c, i| if (c == child) return i;
    return null;
}

/// The sibling adjacent to `con` in its parent's children — the next one if
/// `forward`, else the previous — or null at the edge / for a parentless Con.
pub fn adjacentSibling(con: *data.Con, forward: bool) ?*data.Con {
    const parent = con.parent orelse return null;
    const i = childIndexOf(parent, con) orelse return null;
    if (forward) {
        return if (i + 1 < parent.children.items.len) parent.children.items[i + 1] else null;
    }
    return if (i > 0) parent.children.items[i - 1] else null;
}

/// Detach `leaf` from its current parent and append it to `dst`. The window is
/// preserved (no AX element release). Caller is responsible for relaying out
/// either workspace as needed. Returns true if the move happened.
pub fn moveLeafToWorkspace(alloc: Allocator, leaf: *data.Con, dst: *data.Con) bool {
    const cur_parent = leaf.parent orelse return false;
    if (cur_parent == dst) return false;
    const i = childIndexOf(cur_parent, leaf) orelse return false;
    _ = cur_parent.children.orderedRemove(i);
    leaf.parent = dst;
    leaf.depth = dst.depth + 1;
    dst.children.append(alloc, leaf) catch {
        // Undo the detach so the tree stays consistent.
        cur_parent.children.insert(alloc, i, leaf) catch {};
        leaf.parent = cur_parent;
        return false;
    };
    // A nested source container may now hold a single child — flatten it.
    collapseIfDegenerate(cur_parent);
    return true;
}

/// The Workspace Con for SkyLight space id `sid`, or null.
pub fn findWorkspace(con: *data.Con, sid: u64) ?*data.Con {
    if (con.con_type == .Workspace and con.id == sid) return con;
    for (con.children.items) |child| {
        if (findWorkspace(child, sid)) |w| return w;
    }
    return null;
}

/// The Monitor ancestor of `con` (or `con` itself if it is one), else null.
pub fn monitorOf(con: *data.Con) ?*data.Con {
    var node: ?*data.Con = con;
    while (node) |n| : (node = n.parent) {
        if (n.con_type == .Monitor) return n;
    }
    return null;
}

/// The Workspace ancestor of `con` (or `con` itself if it is one), else null.
pub fn workspaceOf(con: *data.Con) ?*data.Con {
    var node: ?*data.Con = con;
    while (node) |n| : (node = n.parent) {
        if (n.con_type == .Workspace) return n;
    }
    return null;
}

/// The usable (visible) frame of the display that owns `ws`, in AX coordinates.
/// Each Monitor Con's `id` is its `display_index`; we map that to the display's
/// UUID via `managedDisplays`, then to its geometry via `displayFrames`. Falls
/// back to the main display when the mapping can't be resolved (single-display
/// machines, or a display added after the tree was built).
pub fn areaForWorkspace(appState: *state.AppState, ws: *data.Con) macos.window_list.Rect {
    if (resolveMonitorFrame(appState, monitorOf(ws))) |area| return area;
    return macos.display.mainVisibleFrame() orelse zero_rect;
}

const zero_rect: macos.window_list.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

/// Resolve the visible frame of Monitor Con `mon` from the live display layout.
fn resolveMonitorFrame(appState: *state.AppState, mon: ?*data.Con) ?macos.window_list.Rect {
    const monitor = mon orelse return null;
    const idx: usize = @intCast(monitor.id); // Monitor.id == display_index
    var md_buf: [max_displays]macos.spaces.ManagedDisplay = undefined;
    const mds = macos.spaces.managedDisplays(&md_buf, appState.skylight_cid);
    if (idx >= mds.len) return null;
    var frame_buf: [max_displays]macos.display.DisplayFrame = undefined;
    const frames = macos.display.displayFrames(&frame_buf);
    return macos.display.frameForUUID(frames, mds[idx].uuidSlice());
}

/// Lay out the focused display's currently active Space onto its real windows,
/// using that display's own visible frame. Non-visible Spaces are left alone
/// (deferred, as yabai does). Use `flushAllVisible` to re-tile every monitor.
pub fn flushActive(appState: *state.AppState) void {
    const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return;
    const ws = findWorkspace(appState.tree orelse return, sid) orelse return;
    flushWorkspace(appState, ws);
}

/// Whether `ws` is a tiled workspace — a user Space. Native-fullscreen and
/// system Spaces are tracked but left alone (resizing a fullscreen window would
/// break it). Non-Workspace cons are never flushed directly.
fn isTileable(ws: *data.Con) bool {
    return ws.con_type == .Workspace and ws.space_type == 0;
}

/// Lay out the visible Space of *every* display, each within its own frame.
/// Called when a change can affect more than the focused monitor (a Space
/// switch, a display reconfiguration, a window moved across monitors).
pub fn flushAllVisible(appState: *state.AppState) void {
    const root = appState.tree orelse return;
    var md_buf: [max_displays]macos.spaces.ManagedDisplay = undefined;
    const mds = macos.spaces.managedDisplays(&md_buf, appState.skylight_cid);
    if (mds.len == 0) return flushActive(appState); // couldn't enumerate displays
    var frame_buf: [max_displays]macos.display.DisplayFrame = undefined;
    const frames = macos.display.displayFrames(&frame_buf);

    for (mds) |md| {
        if (md.current_space == 0) continue;
        const ws = findWorkspace(root, md.current_space) orelse continue;
        if (!isTileable(ws)) continue; // a fullscreen/system Space is showing — leave it
        const area = macos.display.frameForUUID(frames, md.uuidSlice()) orelse
            macos.display.mainVisibleFrame() orelse continue;
        layout.flushWorkspace(ws, area);
    }
}

/// Lay out `ws` regardless of whether its Space is currently active, within its
/// own display's frame. Used when we move a window into an inactive Space (or a
/// Space on another monitor): AX setSize/setPosition on cached elements still
/// applies even on Spaces the user isn't looking at, so the destination's
/// tiling row is correct before they swipe (or glance) over.
pub fn flushWorkspace(appState: *state.AppState, ws: *data.Con) void {
    if (!isTileable(ws)) return; // never resize windows on a fullscreen/system Space
    layout.flushWorkspace(ws, areaForWorkspace(appState, ws));
}

/// One Monitor Con with its resolved geometry and current visible Space.
pub const MonitorInfo = struct {
    con: *data.Con,
    frame: macos.window_list.Rect,
    current_space: u64,
};

/// Fill `out` with one entry per Monitor Con that resolves to a live display,
/// in display order. Returns the count written (capped at `out.len`). Lets the
/// focus engine pick an adjacent monitor without each caller re-querying the OS.
pub fn collectMonitors(appState: *state.AppState, out: []MonitorInfo) usize {
    const root = appState.tree orelse return 0;
    var md_buf: [max_displays]macos.spaces.ManagedDisplay = undefined;
    const mds = macos.spaces.managedDisplays(&md_buf, appState.skylight_cid);
    var frame_buf: [max_displays]macos.display.DisplayFrame = undefined;
    const frames = macos.display.displayFrames(&frame_buf);

    var count: usize = 0;
    for (root.children.items) |mon| {
        if (count >= out.len) break;
        if (mon.con_type != .Monitor) continue;
        const idx: usize = @intCast(mon.id);
        if (idx >= mds.len) {
            std.debug.print("[monitor] con {d} has no managed display ({d} known)\n", .{ idx, mds.len });
            continue;
        }
        const area = macos.display.frameForUUID(frames, mds[idx].uuidSlice()) orelse {
            std.debug.print("[monitor] con {d}: no NSScreen frame for managed uuid={s}\n", .{ idx, mds[idx].uuidSlice() });
            for (frames) |f| std.debug.print("[monitor]   available screen uuid={s}\n", .{f.uuidSlice()});
            continue;
        };
        out[count] = .{ .con = mon, .frame = area, .current_space = mds[idx].current_space };
        count += 1;
    }
    return count;
}

/// An existing leaf under `ws` belonging to `pid` whose window occupies the same
/// frame as `frame`. A new window that matches means it's joining that window's
/// native macOS tab group: AppKit gives every tab in a group one shared frame,
/// and the window server has no tab concept, so identical frame + same app is
/// the reliable cross-process signal (verified: a new tab is created at exactly
/// the group's frame). Tight epsilon — tab frames are identical, not merely close.
pub fn findTabSibling(ws: *data.Con, pid: i32, frame: macos.window_list.Rect) ?*data.Con {
    const eps: f64 = 2;
    for (ws.children.items) |child| {
        if (child.window) |w| {
            if (w.pid == pid and
                @abs(w.bounds.origin.x - frame.origin.x) < eps and
                @abs(w.bounds.origin.y - frame.origin.y) < eps and
                @abs(w.bounds.size.width - frame.size.width) < eps and
                @abs(w.bounds.size.height - frame.size.height) < eps) return child;
        }
    }
    return null;
}

/// The leaf Con holding window `wid`, or null.
pub fn findLeaf(con: *data.Con, wid: u64) ?*data.Con {
    if (con.con_type == .Container) {
        if (con.window) |w| if (w.id == wid) return con;
    }
    for (con.children.items) |child| {
        if (findLeaf(child, wid)) |found| return found;
    }
    return null;
}

/// Combine `leaf` with its adjacent sibling (the next one if `forward`, else the
/// previous) into a new nested split container with `layout`. This is how a
/// workspace gets a *mixed* layout: e.g. an H_SPLIT row whose left slot is a
/// V_STACK of two windows. The new container takes the lower of the two slots
/// (so on-screen order is preserved) and their combined ratio; both windows are
/// reparented under it with equal weight. Returns the new container, or null if
/// there's no neighbour to join.
pub fn joinWithNeighbor(alloc: Allocator, leaf: *data.Con, forward: bool, mode: data.Layout) ?*data.Con {
    const parent = leaf.parent orelse return null;
    const nb = adjacentSibling(leaf, forward) orelse return null;

    const li = childIndexOf(parent, leaf) orelse return null;
    const ni = childIndexOf(parent, nb) orelse return null;
    const lo = @min(li, ni);
    const hi = @max(li, ni);

    const container = makeCon(alloc, .Container, parent, parent.depth + 1, 0) catch return null;
    container.layout = mode;
    container.ratio = leaf.ratio + nb.ratio;
    container.gaps = parent.gaps; // inherit inner gap / accordion peek

    // Reparent the two windows under the container, preserving their order and
    // giving them equal weight within the new slot.
    const first = if (li < ni) leaf else nb;
    const second = if (li < ni) nb else leaf;
    for ([_]*data.Con{ first, second }) |child| {
        child.parent = container;
        child.depth = container.depth + 1;
        child.ratio = 1.0;
        container.children.append(alloc, child) catch return null;
    }

    // Replace the two parent slots with the single container slot: remove the
    // higher index first (so the lower stays valid), then insert at the lower.
    _ = parent.children.orderedRemove(hi);
    _ = parent.children.orderedRemove(lo);
    parent.children.insert(alloc, lo, container) catch return null;
    return container;
}

/// Collapse a nested split container that a removal left with fewer than two
/// children: promote its sole child into its slot (i3-style flatten), or drop it
/// if it's now empty. Keeps the tree free of single-child container cruft.
/// No-op on workspaces and leaf cons.
fn collapseIfDegenerate(con: *data.Con) void {
    const parent = con.parent orelse return;
    if (con.con_type != .Container or con.window != null) return; // leaf / non-split
    if (con.children.items.len >= 2) return;

    const idx = childIndexOf(parent, con) orelse return;

    if (con.children.items.len == 1) {
        const only = con.children.items[0];
        only.parent = parent;
        only.depth = parent.depth + 1;
        only.ratio = con.ratio; // take over the freed slot's weight
        parent.children.items[idx] = only;
    } else {
        _ = parent.children.orderedRemove(idx);
    }
}

/// Minimum window extent (points) along the split axis, so a neighbour can't be
/// crushed to nothing by a resize.
const min_extent: f64 = 50;

/// Absorb a user resize of `leaf` into the tree: transfer the size delta to the
/// neighbour on the dragged edge so the new size persists and the parent's total
/// is conserved. `frame` is the window's actual frame after the user resized it.
/// Returns true if the tree changed (caller should re-flush).
///
/// The dragged edge is inferred from which fields changed, exactly like yabai's
/// `mouse_drop_try_adjust_bsp_grid` (koekeishiya/yabai, src/mouse_handler.c):
/// a moved origin means the leading edge was dragged (compensate the previous
/// neighbour); a size change with the origin fixed means the trailing edge was
/// dragged (compensate the next neighbour).
pub fn applyManualResize(leaf: *data.Con, frame: macos.window_list.Rect) bool {
    const parent = leaf.parent orelse return false;
    if (parent.layout != .H_SPLIT and parent.layout != .V_SPLIT) return false;
    const horizontal = parent.layout == .H_SPLIT;

    const old = leaf.window.?.bounds;
    const eps: f64 = 2;

    const leading_moved = if (horizontal)
        @abs(frame.origin.x - old.origin.x) > eps
    else
        @abs(frame.origin.y - old.origin.y) > eps;
    const new_main = if (horizontal) frame.size.width else frame.size.height;
    const old_main = if (horizontal) old.size.width else old.size.height;
    const delta = new_main - old_main;
    if (@abs(delta) < eps) return false; // no meaningful main-axis change

    const neighbor = adjacentSibling(leaf, !leading_moved) orelse return false;

    // Pin every sibling's ratio to its current main extent so the weights share
    // the same (point) units, then move `delta` from the neighbour to the leaf.
    pinExtents(parent, horizontal);
    leaf.ratio = new_main;
    neighbor.ratio = @max(neighbor.ratio - delta, min_extent);
    return true;
}

/// Set each child's ratio to its current main-axis extent (from its window's
/// bounds), so subsequent ratio math is in consistent point units.
fn pinExtents(parent: *data.Con, horizontal: bool) void {
    for (parent.children.items) |child| {
        if (child.window) |w| {
            child.ratio = if (horizontal) w.bounds.size.width else w.bounds.size.height;
        }
    }
}

/// Absorb a user move of `leaf`: if the moved window's centre now lands over a
/// sibling's slot, swap the two windows' slots (a positional reorder, like
/// dragging one tile onto another), then the caller re-flushes so both snap
/// into place. Returns true if a swap happened. We swap the window payloads
/// rather than the list nodes so each slot keeps its ratio.
pub fn applyManualMove(leaf: *data.Con, frame: macos.window_list.Rect) bool {
    const parent = leaf.parent orelse return false;
    const cx = frame.origin.x + frame.size.width / 2;
    const cy = frame.origin.y + frame.size.height / 2;

    for (parent.children.items) |child| {
        if (child == leaf) continue;
        const b = (child.window orelse continue).bounds;
        if (cx >= b.origin.x and cx < b.origin.x + b.size.width and
            cy >= b.origin.y and cy < b.origin.y + b.size.height)
        {
            const tmp = leaf.window;
            leaf.window = child.window;
            child.window = tmp;
            leaf.id = leaf.window.?.id;
            child.id = child.window.?.id;
            return true;
        }
    }
    return false;
}

/// Swap `leaf` with its previous (`forward=false`) or next (`forward=true`)
/// sibling in the parent's tiling order. Swaps the two *nodes' positions* in the
/// child list (not their window payloads), so it works when the neighbour is a
/// nested container, not just a leaf — a payload swap would empty the leaf and
/// corrupt the container (which has no window). The ratio travels with each node,
/// so the windows swap size as well as place. Returns true if a swap happened.
pub fn swapLeaf(leaf: *data.Con, forward: bool) bool {
    const parent = leaf.parent orelse return false;
    const target = adjacentSibling(leaf, forward) orelse return false;

    const a = childIndexOf(parent, leaf) orelse return false;
    const b = childIndexOf(parent, target) orelse return false;
    parent.children.items[a] = target;
    parent.children.items[b] = leaf;
    return true;
}

/// Grow `leaf` by `delta` pixels along its parent's split axis, transferring the
/// difference to `neighbor`. Pins every sibling's ratio to its current extent
/// first so the units are consistent (points), matching `applyManualResize`.
/// Returns true if the tree changed; false if the parent isn't a split.
fn transferResize(leaf: *data.Con, neighbor: *data.Con, delta: f64) bool {
    const parent = leaf.parent orelse return false;
    if (parent.layout != .H_SPLIT and parent.layout != .V_SPLIT) return false;
    const horizontal = parent.layout == .H_SPLIT;
    const win = leaf.window orelse return false;
    pinExtents(parent, horizontal);
    const cur = if (horizontal) win.bounds.size.width else win.bounds.size.height;
    leaf.ratio = @max(cur + delta, min_extent);
    neighbor.ratio = @max(neighbor.ratio - delta, min_extent);
    return true;
}

/// Adjust `leaf`'s main-axis ratio by `delta` pixels (positive = grow, negative
/// = shrink), transferring the difference to the neighbour on the `grow` edge.
/// Returns true if the tree changed (no-op without a neighbour there).
pub fn resizeLeaf(leaf: *data.Con, grow: bool, delta: f64) bool {
    if (leaf.parent == null or leaf.window == null) return false;
    const neighbor = adjacentSibling(leaf, grow) orelse return false;
    return transferResize(leaf, neighbor, delta);
}

/// Resize `leaf` along its parent's split axis *without* a direction (AeroSpace's
/// `resize smart`): grow the focused window when `delta > 0`, shrink it when
/// `delta < 0`, transferring the difference to whichever neighbour exists —
/// preferring the next sibling, falling back to the previous. Because the axis
/// follows the container, the same key always makes the focused window
/// bigger/smaller regardless of which slot it occupies (so an edge window, with
/// no neighbour on one side, still resizes). Returns true if the tree changed.
pub fn resizeLeafSmart(leaf: *data.Con, delta: f64) bool {
    const neighbor = adjacentSibling(leaf, true) orelse adjacentSibling(leaf, false) orelse return false;
    return transferResize(leaf, neighbor, delta);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testRect(x: f64, y: f64, w: f64, h: f64) macos.window_list.Rect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn testWindow(id: u32, pid: i32, bounds: macos.window_list.Rect) data.Window {
    return .{ .id = id, .pid = pid, .owner = "test", .bounds = bounds };
}

test "addLeaf appends at the trailing edge with the average sibling ratio" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    try testing.expectEqual(1.0, a.ratio); // first leaf gets the neutral weight
    a.ratio = 3.0;
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)));
    try testing.expectEqual(3.0, b.ratio); // average of the existing {3.0}
    try testing.expectEqual(@as(usize, 2), ws.children.items.len);
    try testing.expectEqual(ws, b.parent.?);
    try testing.expectEqual(ws.depth + 1, b.depth);
}

test "insertColumnAfter places a new column right of the focused one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    ws.layout = .SCROLL;
    const a = try insertColumnAfter(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)), null);
    const b = try insertColumnAfter(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)), null);
    // Insert C after A → order becomes A, C, B (not appended at the end).
    const c = try insertColumnAfter(alloc, ws, testWindow(3, 100, testRect(0, 0, 100, 100)), a);

    try testing.expectEqual(@as(usize, 3), ws.children.items.len);
    try testing.expectEqual(a, ws.children.items[0]);
    try testing.expectEqual(c, ws.children.items[1]);
    try testing.expectEqual(b, ws.children.items[2]);
    try testing.expectEqual(@as(f64, 0), c.width_frac); // uses the default width
}

test "addWindowToColumn wraps a lone column then appends into the container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    ws.layout = .SCROLL;
    // A lone-window column the user armed with agate.layout(v_split).
    const a = try insertColumnAfter(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)), null);
    a.layout = .V_SPLIT;
    a.split_armed = true;
    a.width_frac = 0.5;

    // First open: the leaf is promoted to a split container holding both windows.
    const b = try addWindowToColumn(alloc, a, testWindow(2, 100, testRect(0, 0, 100, 100)));
    try testing.expectEqual(@as(usize, 1), ws.children.items.len); // still one column
    const cont = ws.children.items[0];
    try testing.expect(cont != a); // a fresh container took the slot
    try testing.expectEqual(data.Layout.V_SPLIT, cont.layout); // carries the armed layout
    try testing.expectEqual(@as(f64, 0.5), cont.width_frac); // and the column width
    try testing.expect(cont.split_armed); // stays armed to keep collecting
    try testing.expectEqual(@as(usize, 2), cont.children.items.len);
    try testing.expectEqual(a, cont.children.items[0]);
    try testing.expectEqual(b, cont.children.items[1]);
    try testing.expectEqual(cont, a.parent.?);

    // Second open: appended into the existing container, no new wrapping.
    const c = try addWindowToColumn(alloc, cont, testWindow(3, 100, testRect(0, 0, 100, 100)));
    try testing.expectEqual(@as(usize, 1), ws.children.items.len);
    try testing.expectEqual(@as(usize, 3), cont.children.items.len);
    try testing.expectEqual(c, cont.children.items[2]);
}

test "columnOf resolves the workspace-level column for a nested leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    ws.layout = .SCROLL;
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const cont = try makeCon(alloc, .Container, ws, 1, 0);
    cont.layout = .V_SPLIT;
    try ws.children.append(alloc, cont);
    const b1 = try addLeaf(alloc, cont, testWindow(2, 100, testRect(0, 0, 100, 100)));

    try testing.expectEqual(a, columnOf(ws, a).?); // a leaf column is its own column
    try testing.expectEqual(cont, columnOf(ws, b1).?); // a nested leaf → its container
}

test "expelLeaf ejects a nested window into its own column after the container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try makeCon(alloc, .Root, null, 0, 0);
    const mon = try makeCon(alloc, .Monitor, root, 1, 0);
    try root.children.append(alloc, mon);
    const ws = try makeCon(alloc, .Workspace, mon, 2, 1);
    ws.layout = .SCROLL;
    try mon.children.append(alloc, ws);

    // Column 0: a leaf. Column 1: a vertical split of two windows.
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const cont = try makeCon(alloc, .Container, ws, 3, 0);
    cont.layout = .V_SPLIT;
    try ws.children.append(alloc, cont);
    const b1 = try addLeaf(alloc, cont, testWindow(2, 100, testRect(0, 0, 100, 100)));
    const b2 = try addLeaf(alloc, cont, testWindow(3, 100, testRect(0, 0, 100, 100)));

    // Expel b1 forward: the container collapses to just b2 (promoted into its
    // slot), and b1 becomes its own column right after it. Order: a, b2, b1.
    try testing.expect(expelLeaf(alloc, b1, true));
    try testing.expectEqual(@as(usize, 3), ws.children.items.len);
    try testing.expectEqual(a, ws.children.items[0]);
    try testing.expectEqual(b2, ws.children.items[1]);
    try testing.expectEqual(b1, ws.children.items[2]);
    try testing.expectEqual(ws, b1.parent.?);

    // Expelling an already-top-level column is a no-op.
    try testing.expect(!expelLeaf(alloc, a, true));
}

test "findLeaf / findWorkspace / hasWindow / removeWindow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try makeCon(alloc, .Root, null, 0, 0);
    const mon = try makeCon(alloc, .Monitor, root, 1, 0);
    try root.children.append(alloc, mon);
    const ws = try makeCon(alloc, .Workspace, mon, 2, 77);
    try mon.children.append(alloc, ws);
    _ = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)));

    try testing.expectEqual(ws, findWorkspace(root, 77).?);
    try testing.expect(findWorkspace(root, 78) == null);
    try testing.expectEqual(b, findLeaf(root, 2).?);
    try testing.expect(hasWindow(root, 1));
    try testing.expect(!hasWindow(root, 3));

    try testing.expect(removeWindow(root, 1));
    try testing.expect(!hasWindow(root, 1));
    try testing.expect(!removeWindow(root, 1)); // already gone
    try testing.expectEqual(@as(usize, 1), ws.children.items.len);
}

test "removeWindow collapses a now-single-child nested container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const cont = try makeCon(alloc, .Container, ws, 1, 0);
    cont.ratio = 2.0;
    try ws.children.append(alloc, cont);
    _ = try addLeaf(alloc, cont, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, cont, testWindow(2, 100, testRect(0, 0, 100, 100)));

    try testing.expect(removeWindow(ws, 1));
    // The survivor is promoted into the container's slot, inheriting its weight.
    try testing.expectEqual(b, ws.children.items[0]);
    try testing.expectEqual(ws, b.parent.?);
    try testing.expectEqual(2.0, b.ratio);
}

test "removeWindowsForPid removes every window of the app" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    _ = try addLeaf(alloc, ws, testWindow(1, 10, testRect(0, 0, 100, 100)));
    _ = try addLeaf(alloc, ws, testWindow(2, 20, testRect(0, 0, 100, 100)));
    _ = try addLeaf(alloc, ws, testWindow(3, 10, testRect(0, 0, 100, 100)));

    try testing.expect(removeWindowsForPid(ws, 10));
    try testing.expectEqual(@as(usize, 1), ws.children.items.len);
    try testing.expectEqual(@as(u32, 2), ws.children.items[0].window.?.id);
    try testing.expect(!removeWindowsForPid(ws, 10));
}

test "childIndexOf and adjacentSibling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)));

    try testing.expectEqual(@as(usize, 0), childIndexOf(ws, a).?);
    try testing.expectEqual(@as(usize, 1), childIndexOf(ws, b).?);
    try testing.expectEqual(b, adjacentSibling(a, true).?);
    try testing.expectEqual(a, adjacentSibling(b, false).?);
    try testing.expect(adjacentSibling(a, false) == null); // leading edge
    try testing.expect(adjacentSibling(b, true) == null); // trailing edge
    try testing.expect(adjacentSibling(ws, true) == null); // no parent
}

test "swapLeaf swaps node positions with its neighbour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)));
    const c2 = try addLeaf(alloc, ws, testWindow(3, 100, testRect(0, 0, 100, 100)));

    try testing.expect(swapLeaf(a, true));
    try testing.expectEqual(b, ws.children.items[0]);
    try testing.expectEqual(a, ws.children.items[1]);
    try testing.expectEqual(c2, ws.children.items[2]);
    try testing.expect(!swapLeaf(b, false)); // now at the leading edge
}

test "joinWithNeighbor nests the pair into a new container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(0, 0, 100, 100)));
    a.ratio = 1.5;
    b.ratio = 0.5;
    const c2 = try addLeaf(alloc, ws, testWindow(3, 100, testRect(0, 0, 100, 100)));

    const cont = joinWithNeighbor(alloc, a, true, .V_STACK).?;
    try testing.expectEqual(@as(usize, 2), ws.children.items.len);
    try testing.expectEqual(cont, ws.children.items[0]); // takes the lower slot
    try testing.expectEqual(c2, ws.children.items[1]);
    try testing.expectEqual(data.Layout.V_STACK, cont.layout);
    try testing.expectEqual(2.0, cont.ratio); // combined weight
    try testing.expectEqual(a, cont.children.items[0]); // order preserved
    try testing.expectEqual(b, cont.children.items[1]);
    try testing.expectEqual(cont, a.parent.?);
    try testing.expectEqual(1.0, a.ratio); // equal weight inside the new slot
    try testing.expect(joinWithNeighbor(alloc, c2, true, .V_STACK) == null); // no neighbour
}

test "applyManualResize transfers the dragged delta to the edge neighbour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1); // layout defaults to H_SPLIT
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(100, 0, 100, 100)));

    // Trailing edge dragged: origin fixed, width grew 100 → 150.
    try testing.expect(applyManualResize(a, testRect(0, 0, 150, 100)));
    try testing.expectEqual(150.0, a.ratio);
    try testing.expectEqual(50.0, b.ratio); // 100 - 50, conserved total

    // No meaningful change is a no-op.
    try testing.expect(!applyManualResize(a, testRect(0, 0, 100, 100)));
}

test "applyManualResize leading edge compensates the previous sibling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(100, 0, 100, 100)));

    // b's left edge dragged right: origin moved 100 → 150, width shrank to 50.
    try testing.expect(applyManualResize(b, testRect(150, 0, 50, 100)));
    try testing.expectEqual(50.0, b.ratio);
    try testing.expectEqual(150.0, a.ratio); // absorbed the freed 50
}

test "applyManualMove swaps window payloads when the centre lands on a sibling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(100, 0, 100, 100)));

    // Dropped frame's centre (170, 50) is over b's slot → payloads swap.
    try testing.expect(applyManualMove(a, testRect(120, 0, 100, 100)));
    try testing.expectEqual(@as(u32, 2), a.window.?.id);
    try testing.expectEqual(@as(u32, 1), b.window.?.id);
    try testing.expectEqual(@as(u64, 2), a.id);

    // Dropped where no sibling slot is (off in empty space) → nothing to swap.
    try testing.expect(!applyManualMove(a, testRect(500, 500, 100, 100)));
}

test "resizeLeaf grows by delta at the neighbour's expense" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(100, 0, 100, 100)));

    try testing.expect(resizeLeaf(a, true, 30));
    try testing.expectEqual(130.0, a.ratio);
    try testing.expectEqual(70.0, b.ratio);
    try testing.expect(!resizeLeaf(b, true, 30)); // no trailing neighbour
}

test "resizeLeafSmart grows/shrinks the focused window, picking a neighbour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1); // H_SPLIT
    const a = try addLeaf(alloc, ws, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, ws, testWindow(2, 100, testRect(100, 0, 100, 100)));

    // Grow the leftmost window: no left neighbour, so it takes from the next one.
    try testing.expect(resizeLeafSmart(a, 30));
    try testing.expectEqual(130.0, a.ratio);
    try testing.expectEqual(70.0, b.ratio);

    // A negative delta shrinks the focused window (the edge window still works,
    // unlike a directional resize toward a missing neighbour). Reflect the grow
    // above in both windows' frames first — `pinExtents` reads from bounds.
    a.window.?.bounds = testRect(0, 0, 130, 100);
    b.window.?.bounds = testRect(130, 0, 70, 100);
    try testing.expect(resizeLeafSmart(b, -20));
    try testing.expectEqual(50.0, b.ratio); // 70 - 20
    try testing.expectEqual(150.0, a.ratio); // previous neighbour absorbs it

    // A lone window has no neighbour to trade with.
    const solo = try makeCon(alloc, .Workspace, null, 0, 2);
    const only = try addLeaf(alloc, solo, testWindow(3, 100, testRect(0, 0, 100, 100)));
    try testing.expect(!resizeLeafSmart(only, 30));
}

test "moveLeafToWorkspace reparents the leaf and collapses the source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws1 = try makeCon(alloc, .Workspace, null, 2, 1);
    const ws2 = try makeCon(alloc, .Workspace, null, 2, 2);
    const cont = try makeCon(alloc, .Container, ws1, 3, 0);
    cont.ratio = 2.0;
    try ws1.children.append(alloc, cont);
    const a = try addLeaf(alloc, cont, testWindow(1, 100, testRect(0, 0, 100, 100)));
    const b = try addLeaf(alloc, cont, testWindow(2, 100, testRect(0, 0, 100, 100)));

    try testing.expect(moveLeafToWorkspace(alloc, a, ws2));
    try testing.expectEqual(ws2, a.parent.?);
    try testing.expectEqual(ws2.depth + 1, a.depth);
    try testing.expectEqual(a, ws2.children.items[0]);
    // The source container went degenerate; its survivor took over its slot.
    try testing.expectEqual(b, ws1.children.items[0]);
    try testing.expectEqual(ws1, b.parent.?);

    try testing.expect(!moveLeafToWorkspace(alloc, a, ws2)); // already there
}

test "findTabSibling matches same-pid windows at an identical frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try makeCon(alloc, .Workspace, null, 0, 1);
    const a = try addLeaf(alloc, ws, testWindow(1, 10, testRect(50, 50, 800, 600)));

    try testing.expectEqual(a, findTabSibling(ws, 10, testRect(50, 50, 800, 600)).?);
    try testing.expectEqual(a, findTabSibling(ws, 10, testRect(51, 50, 800, 600)).?); // within eps
    try testing.expect(findTabSibling(ws, 11, testRect(50, 50, 800, 600)) == null); // other app
    try testing.expect(findTabSibling(ws, 10, testRect(60, 50, 800, 600)) == null); // frame differs
}
