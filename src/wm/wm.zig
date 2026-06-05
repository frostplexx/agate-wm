const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const window = @import("window.zig");

const AppState = state.AppState;

pub fn init_wm(appState: AppState) !void {
    var meta = std.AutoHashMap(u32, macos.window_list.WindowInfo).init(appState.arena);
    for (try macos.window_list.listAll(appState.arena)) |info| {
        try meta.put(info.id, info);
    }
    std.debug.print("meta: {d} windows from CG\n", .{meta.count()});

    const all_spaces = try macos.spaces.allSpaces(appState.arena, appState.skylight_cid);
    std.debug.print("spaces: {d} total\n", .{all_spaces.len});

    for (all_spaces) |sp| {
        const wids = try macos.spaces.windowsOnSpace(appState.arena, appState.skylight_cid, sp.id, true);
        std.debug.print("  space {d} (display {d}, type {d}): {d} wids\n", .{ sp.id, sp.display_index, sp.type, wids.len });

        for (wids) |wid| {
            const info = meta.get(wid) orelse {
                std.debug.print("    #{d} not in CG meta\n", .{wid});
                continue;
            };
            if (!isAppWindow(info)) continue;

            const win = window.init(info) orelse {
                std.debug.print("    #{d} {s}: AX unavailable\n", .{ info.id, info.owner });
                continue;
            };
            defer win.deinit();
            std.debug.print("    #{d} pid={d} {d:.0}x{d:.0}  {s}\n", .{
                win.id, win.pid, win.bounds.size.width, win.bounds.size.height, win.owner,
            });
        }
    }
}

fn isAppWindow(w: macos.window_list.WindowInfo) bool {
    return w.layer == 0 and w.owner.len > 0 and
        w.bounds.size.width > 0 and w.bounds.size.height > 0;
}
