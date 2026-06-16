const std = @import("std");

const macos = @import("macos");
const wm = @import("wm/wm.zig");
const state = @import("state.zig");
const lock = @import("lock.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next(); // executable path

    // Any explicit subcommand is a CLI invocation: it talks to (or reports on)
    // the daemon instead of starting one, and needs no accessibility permission.
    if (args.next()) |sub| {
        std.process.exit(cli.run(init, sub, &args));
    }

    // No subcommand → run as the daemon. Enforce a single instance: the lock is
    // held for the whole process lifetime and released by the kernel on exit.
    switch (try lock.acquire(init.gpa)) {
        .busy => |pid| {
            std.debug.print("agate is already running (pid {d}).\nRun `agate help` for the CLI.\n", .{pid});
            return;
        },
        .acquired => |held| _ = held, // keep the lock for the process lifetime
    }

    // Managing windows requires accessibility permission.
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
    _ = @import("config/parse.zig");
    _ = @import("config/events.zig");
    _ = @import("config/small_screen.zig");
    _ = @import("lock.zig");
    _ = @import("ipc.zig");
    _ = @import("lib/regexp.zig");
    // The macos module's tests run in their own test compile (see build.zig);
    // cross-module test collection doesn't happen from here.
}


