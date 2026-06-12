const std = @import("std");

const macos = @import("macos");
const wm = @import("wm/wm.zig");
const state = @import("state.zig");

pub fn main(init: std.process.Init) !void {

    // Check for accessibility permissions, which are required to get window information.
    if (!macos.isProcessTrusted()) {
        std.debug.print("This process is not trusted for accessibility. Please grant permission in System Settings > Security & Privacy > Accessibility.\n", .{});
        std.process.exit(1);
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

test {
    _ = @import("wm/tree.zig");
    _ = @import("wm/layout.zig");
    _ = @import("wm/focus/focus.zig");
    _ = @import("wm/gestures.zig");
    _ = @import("wm/animate.zig");
    _ = @import("config/lua.zig");
    _ = @import("lib/regexp.zig");
    // The macos module's tests run in their own test compile (see build.zig);
    // cross-module test collection doesn't happen from here.
}


