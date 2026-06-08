const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");
const window = @import("window.zig");
const layout = @import("layout.zig");
const state = @import("../state.zig");

const Allocator = std.mem.Allocator;

/// Default gaps applied to each workspace until config exists.
const default_gaps: data.gaps = .{ .inner = 10, .outer = 10, .top = 0, .bottom = 0, .left = 0, .right = 0 };

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

/// Mean ratio of `con`'s children (1.0 if it has none).
fn averageChildRatio(con: *data.Con) f64 {
    const count = con.children.items.len;
    if (count == 0) return 1.0;
    var total: f64 = 0;
    for (con.children.items) |child| total += child.ratio;
    return total / @as(f64, @floatFromInt(count));
}

/// Append a new leaf window Con built from CoreGraphics metadata. Returns the leaf.
pub fn addWindowLeaf(alloc: Allocator, ws: *data.Con, info: macos.window_list.WindowInfo) !*data.Con {
    return addLeaf(alloc, ws, window.init(info));
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
        i += 1;
    }
    return removed;
}

/// Whether a leaf for window `wid` already exists under `con`.
pub fn hasWindow(con: *data.Con, wid: u64) bool {
    for (con.children.items) |child| {
        if (child.con_type == .Container) {
            if (child.window) |w| if (w.id == wid) return true;
        }
        if (hasWindow(child, wid)) return true;
    }
    return false;
}

/// The Workspace Con for SkyLight space id `sid`, or null.
pub fn findWorkspace(con: *data.Con, sid: u64) ?*data.Con {
    if (con.con_type == .Workspace and con.id == sid) return con;
    for (con.children.items) |child| {
        if (findWorkspace(child, sid)) |w| return w;
    }
    return null;
}

/// Lay out the currently active Space's workspace onto its real windows.
/// Non-visible Spaces are left alone (deferred, as yabai does).
pub fn flushActive(appState: *state.AppState) void {
    const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return;
    const ws = findWorkspace(appState.tree orelse return, sid) orelse return;
    const area = macos.display.mainVisibleFrame() orelse return;
    layout.flushWorkspace(ws, area);
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

/// The previous / next sibling Con in the parent's children slice, or null.
fn prevSibling(con: *data.Con) ?*data.Con {
    const parent = con.parent orelse return null;
    for (parent.children.items, 0..) |child, i| {
        if (child == con) return if (i > 0) parent.children.items[i - 1] else null;
    }
    return null;
}
fn nextSibling(con: *data.Con) ?*data.Con {
    const parent = con.parent orelse return null;
    for (parent.children.items, 0..) |child, i| {
        if (child == con) {
            return if (i + 1 < parent.children.items.len) parent.children.items[i + 1] else null;
        }
    }
    return null;
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

    const neighbor = (if (leading_moved) prevSibling(leaf) else nextSibling(leaf)) orelse return false;

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
