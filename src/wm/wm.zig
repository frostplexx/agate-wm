const std = @import("std");
const state = @import("../state.zig");
const data = @import("data.zig");
const tree = @import("tree.zig");
const observer = @import("observer.zig");
const lua_config = @import("../config/lua.zig");

const AppState = state.AppState;

pub fn init_wm(appState: *AppState) !void {
    appState.tree = try tree.build_tree(appState.arena, appState.skylight_cid);

    // Load init.lua; registers keybindings via agate.bind() calls. Must run
    // before the observer (which sets up the keyboard tap that dispatches them).
    const cfg = try lua_config.init(appState.gpa, appState);
    _ = cfg; // config lifetime managed by lua_config module globals

    // Tile each display's visible Space; non-visible Spaces are deferred until
    // shown (yabai-style).
    tree.flushAllVisible(appState);
    print_tree(appState.tree.?, 1);

    // Observe window create/destroy and keep tiling. Blocks on the run loop.
    try observer.run(appState);
}

/// Debug-print the container tree, indented by depth. `index` is the node's
/// 1-based position among its siblings — for a Workspace that's its
/// Mission Control number on the display (distinct from the raw SkyLight id).
fn print_tree(con: *const data.Con, index: usize) void {
    for (0..con.depth) |_| std.debug.print("  ", .{});
    switch (con.con_type) {
        .Root => std.debug.print("Root ({d} monitors)\n", .{con.children.items.len}),
        .Monitor => std.debug.print("Monitor {d} ({d} workspaces)\n", .{
            index, con.children.items.len,
        }),
        .Workspace => std.debug.print("Workspace {d}  [space id {d}, {d} windows, layout={s}]\n", .{
            index, con.id, con.children.items.len, @tagName(con.layout),
        }),
        .Container => if (con.window) |w| {
            std.debug.print("Window #{d}  {s}  pid={d}  pos=({d:.0},{d:.0})  size={d:.0}x{d:.0}\n", .{
                w.id,             w.owner,             w.pid,
                w.bounds.origin.x, w.bounds.origin.y,
                w.bounds.size.width, w.bounds.size.height,
            });
        } else {
            std.debug.print("Container #{d}  [{d} children, layout={s}]\n", .{
                con.id, con.children.items.len, @tagName(con.layout),
            });
        },
    }

    for (con.children.items, 1..) |child, i| {
        print_tree(child, i);
    }
}
