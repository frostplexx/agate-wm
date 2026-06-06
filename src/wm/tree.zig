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
            root.children.append(&mon.node);
            gop.value_ptr.* = mon;
        }
        const monitor = gop.value_ptr.*;

        const workspace = try makeCon(alloc, .Workspace, monitor, 2, sp.id);
        workspace.gaps = default_gaps;
        monitor.children.append(&workspace.node);

        for (try macos.spaces.manageableWindowsOnSpace(alloc, cid, sp.id)) |wid| {
            const info = meta.get(wid) orelse continue;
            _ = try addWindowLeaf(alloc, workspace, info);
        }
    }

    return root;
}

/// Append a new leaf Con holding `win` under `ws`. Returns the leaf.
pub fn addLeaf(alloc: Allocator, ws: *data.Con, win: data.Window) !*data.Con {
    const leaf = try makeCon(alloc, .Container, ws, ws.depth + 1, win.id);
    leaf.window = win;
    ws.children.append(&leaf.node);
    return leaf;
}

/// Append a new leaf window Con built from CoreGraphics metadata. Returns the leaf.
pub fn addWindowLeaf(alloc: Allocator, ws: *data.Con, info: macos.window_list.WindowInfo) !*data.Con {
    return addLeaf(alloc, ws, window.init(info));
}

/// Remove the leaf holding window `wid` from anywhere under `con`. Releases the
/// window's AX element. Returns true if a leaf was removed.
pub fn removeWindow(con: *data.Con, wid: u64) bool {
    var it = con.children.first;
    while (it) |n| : (it = n.next) {
        const child = data.Con.fromNode(n);
        if (child.con_type == .Container) {
            if (child.window) |*w| {
                if (w.id == wid) {
                    w.deinit();
                    con.children.remove(n);
                    return true;
                }
            }
        }
        if (removeWindow(child, wid)) return true;
    }
    return false;
}

/// Whether a leaf for window `wid` already exists under `con`.
pub fn hasWindow(con: *data.Con, wid: u64) bool {
    var it = con.children.first;
    while (it) |n| : (it = n.next) {
        const child = data.Con.fromNode(n);
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
    var it = con.children.first;
    while (it) |n| : (it = n.next) {
        if (findWorkspace(data.Con.fromNode(n), sid)) |w| return w;
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
