const std = @import("std");

const macos = @import("macos");
const wm = @import("wm/wm.zig");
const state = @import("state.zig");

pub fn main(init: std.process.Init) !void {

    // Check for accessibility permissions, which are required to get window information.
    if (!macos.isProcessTrusted()) {
        std.debug.print("This process is not trusted for accessibility. Please grant permission in System Settings > Security & Privacy > Accessibility.\n", .{});
        return;
    }

    // init app state
    var appState: state.AppState = .{
        .skylight_cid = macos.skylight.CGSMainConnectionID(), // Skylight WindowServer connection ID
        .arena = init.arena.allocator(), // Arena allocator for temporary data structures
        .gpa = init.gpa, // General-purpose allocator for transient work
        .tree = null, // Container tree, built by init_wm
    };

    try wm.init_wm(&appState);
}


