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
    //
    // A menu-bar "Restart agate" spawns us with AGATE_RESTART=1 while the outgoing
    // process is still exiting; its lock drops a moment later. Wait that brief
    // window out instead of bailing as "already running". (launchd restarts don't
    // set this — launchd only respawns after the old process is fully dead.)
    const restarting = std.c.getenv("AGATE_RESTART") != null;
    var attempt: u32 = 0;
    while (true) {
        switch (try lock.acquire(init.gpa)) {
            .acquired => |held| {
                _ = held; // keep the lock for the process lifetime
                break;
            },
            .busy => |pid| {
                if (restarting and attempt < 100) { // ~2s total
                    attempt += 1;
                    const ts = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&ts, null);
                    continue;
                }
                std.debug.print("agate is already running (pid {d}).\nRun `agate help` for the CLI.\n", .{pid});
                return;
            },
        }
    }

    // Managing windows requires accessibility permission. Show the system dialog
    // and spin-wait so the process stays alive after kickstart — launchd KeepAlive
    // would restart it anyway, but keeping it alive re-shows the dialog each loop.
    if (!macos.isProcessTrusted()) {
        _ = macos.isProcessTrustedPrompt();
        std.debug.print("Waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)...\n", .{});
        while (!macos.isProcessTrusted()) {
            const ts = std.c.timespec{ .sec = 1, .nsec = 0 };
            _ = std.c.nanosleep(&ts, null);
        }
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
    _ = @import("config/context.zig");
    _ = @import("config/small_screen.zig");
    _ = @import("lock.zig");
    _ = @import("ipc.zig");
    _ = @import("lib/regexp.zig");
    // The macos module's tests run in their own test compile (see build.zig);
    // cross-module test collection doesn't happen from here.
}


