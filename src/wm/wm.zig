const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");

pub fn init_wm(appState: state.AppState) !void {

    //Skylight connection
    var meta = std.AutoHashMap(u32, macos.window_list.WindowInfo).init(appState.arena);
    for (try macos.window_list.listAll(appState.arena)) |w| try meta.put(w.id, w);

    const all_spaces = try macos.spaces.allSpaces(appState.arena, appState.skylight_cid);

    for (all_spaces) |sp| {
        const wids = try macos.spaces.windowsOnSpace(appState.arena, appState.skylight_cid, sp.id, false);

        // Filter to normal, top-level application windows (layer 0). The rest
        // are per-Space system overlays (Dock, Window Server, Notification
        // Center) that SkyLight reports on every Space.
        var app: usize = 0;
        for (wids) |wid| {
            if (meta.get(wid)) |w| {
                if (isAppWindow(w)) app += 1;
            }
        }
        std.debug.print("\nspace {d}  (display {d}, type {d}) — {d} ids, {d} app windows:\n", .{
            sp.id, sp.display_index, sp.type, wids.len, app,
        });
        for (wids) |wid| {
            const w = meta.get(wid) orelse continue;
            if (!isAppWindow(w)) continue;
            std.debug.print("    #{d} pid={d} {d:.0}x{d:.0}  {s}\n", .{
                wid, w.pid, w.bounds.size.width, w.bounds.size.height, w.owner,
            });
        }
    }
}


fn isAppWindow(w: macos.window_list.WindowInfo) bool {
    return w.layer == 0 and w.owner.len > 0;
}
