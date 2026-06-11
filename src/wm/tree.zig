const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");
const window = @import("window.zig");
const layout = @import("layout.zig");
const state = @import("../state.zig");

const Allocator = std.mem.Allocator;

/// Default gaps applied to each workspace until config exists.
const default_gaps: data.Gaps = .{ .inner = 10, .outer = 10, .top = 0, .bottom = 0, .left = 0, .right = 0, .accordion = 40 };

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

/// Lay out the currently active Space's workspace onto its real windows.
/// Non-visible Spaces are left alone (deferred, as yabai does).
pub fn flushActive(appState: *state.AppState) void {
    const sid = macos.spaces.activeSpace(appState.skylight_cid) orelse return;
    const ws = findWorkspace(appState.tree orelse return, sid) orelse return;
    const area = macos.display.mainVisibleFrame() orelse return;
    layout.flushWorkspace(ws, area);
}

/// Lay out `ws` regardless of whether its Space is currently active. Used when
/// we move a window into an inactive Space: AX setSize/setPosition on cached
/// elements still applies even on Spaces the user isn't looking at, so the
/// destination's tiling row is correct before they swipe over.
pub fn flushWorkspace(ws: *data.Con) void {
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

/// Adjust `leaf`'s main-axis ratio by `delta` pixels (positive = grow, negative
/// = shrink), transferring the difference to the neighbour on the trailing edge.
/// Pins every sibling's ratio to its current extent first so the units are
/// consistent with `applyManualResize`. Returns true if the tree changed.
pub fn resizeLeaf(leaf: *data.Con, grow: bool, delta: f64) bool {
    const parent = leaf.parent orelse return false;
    if (parent.layout != .H_SPLIT and parent.layout != .V_SPLIT) return false;
    const horizontal = parent.layout == .H_SPLIT;
    const neighbor = adjacentSibling(leaf, grow) orelse return false;
    const win = leaf.window orelse return false;
    pinExtents(parent, horizontal);
    const cur = if (horizontal) win.bounds.size.width else win.bounds.size.height;
    leaf.ratio = @max(cur + delta, min_extent);
    neighbor.ratio = @max(neighbor.ratio - delta, min_extent);
    return true;
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
