const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");
const window = @import("window.zig");

const Allocator = std.mem.Allocator;

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
        monitor.children.append(&workspace.node);

        for (try macos.spaces.manageableWindowsOnSpace(alloc, cid, sp.id)) |wid| {
            const info = meta.get(wid) orelse continue;
            const leaf = try makeCon(alloc, .Container, workspace, 3, wid);
            leaf.window = window.init(info);
            workspace.children.append(&leaf.node);
        }
    }

    return root;
}
