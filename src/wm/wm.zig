const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const data = @import("data.zig");
const tree = @import("tree.zig");

const AppState = state.AppState;

pub fn init_wm(appState: *AppState) !void {
    appState.tree = try tree.build_tree(appState.arena, appState.skylight_cid);
    print_tree(appState.tree.?, 1);
}

/// Debug-print the container tree, indented by depth. `index` is the node's
/// 1-based position among its siblings — for a Workspace that's its
/// Mission Control number on the display (distinct from the raw SkyLight id).
fn print_tree(con: *const data.Con, index: usize) void {
    for (0..con.depth) |_| std.debug.print("  ", .{});
    switch (con.con_type) {
        .Root => std.debug.print("Root ({d} monitors)\n", .{con.children.len()}),
        .Monitor => std.debug.print("Monitor {d} ({d} workspaces)\n", .{
            index, con.children.len(),
        }),
        .Workspace => std.debug.print("Workspace {d}  [space id {d}, {d} windows]\n", .{
            index, con.id, con.children.len(),
        }),
        .Container => if (con.window) |w| {
            std.debug.print("Window #{d}  {s}  pid={d}  pos=({d:.0},{d:.0})  size={d:.0}x{d:.0}\n", .{
                w.id,             w.owner,             w.pid,
                w.bounds.origin.x, w.bounds.origin.y,
                w.bounds.size.width, w.bounds.size.height,
            });
        } else {
            std.debug.print("Container #{d} ({d} children)\n", .{ con.id, con.children.len() });
        },
    }

    var it = con.children.first;
    var i: usize = 1;
    while (it) |n| {
        print_tree(data.Con.fromNode(n), i);
        it = n.next;
        i += 1;
    }
}
