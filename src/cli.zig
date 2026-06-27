//! Command-line interface. When agate is invoked with a subcommand it acts as a
//! client instead of starting the daemon: report the version, the config path,
//! the config contents, or the daemon's status, and stop a running daemon. None
//! of these need accessibility permission, and only `status`/`stop` consult the
//! running instance (via the lock file) — the rest are answered locally.
const std = @import("std");
const build_options = @import("build_options");
const paths = @import("config/paths.zig");
const lock = @import("lock.zig");
const ipc = @import("ipc.zig");

const Args = std.process.Args.Iterator;

const Cmd = enum {
    list_windows, list_workspaces, list_monitors,
    version, help, config, config_show, status, stop,
};

const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
    .{ "list-windows",   .list_windows },
    .{ "list-workspaces", .list_workspaces },
    .{ "list-monitors",  .list_monitors },
    .{ "version",        .version },
    .{ "-v",             .version },
    .{ "--version",      .version },
    .{ "help",           .help },
    .{ "-h",             .help },
    .{ "--help",         .help },
    .{ "config",         .config },
    .{ "config-path",    .config },
    .{ "config-show",    .config_show },
    .{ "print-config",   .config_show },
    .{ "status",         .status },
    .{ "stop",           .stop },
});

/// Handle a CLI subcommand and return the process exit code. `args` is the
/// argument iterator positioned just past the subcommand (for trailing flags).
pub fn run(init: std.process.Init, sub: []const u8, args: *Args) u8 {
    const alloc = init.gpa;

    const cmd = cmd_map.get(sub) orelse {
        std.debug.print("unknown command: {s}\n\n", .{sub});
        printUsage();
        return 2;
    };

    switch (cmd) {
        .list_windows, .list_workspaces, .list_monitors => return listQuery(init, sub, args),

        .version => {
            std.debug.print("agate {s}\n", .{build_options.version});
            return 0;
        },

        .help => {
            printUsage();
            return 0;
        },

        .config => {
            const p = paths.findConfigPath(alloc) orelse {
                std.debug.print("no config file found (searched $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua, ~/.config/agate/init.lua, ./init.lua)\n", .{});
                return 1;
            };
            defer alloc.free(p);
            std.debug.print("{s}\n", .{p});
            return 0;
        },

        .config_show => return showConfig(init),

        .status => {
            if (lock.runningPid(alloc)) |pid| {
                if (pid > 0) std.debug.print("running (pid {d})\n", .{pid}) else std.debug.print("running\n", .{});
            } else {
                std.debug.print("not running\n", .{});
            }
            return 0;
        },

        .stop => {
            if (lock.stop(alloc)) {
                std.debug.print("stopped\n", .{});
                return 0;
            }
            std.debug.print("agate is not running\n", .{});
            return 1;
        },
    }
}

/// Forward a `list-*` query to the running daemon and print its response. The
/// daemon owns the window tree, so this is the only way to reflect agate's live
/// state (workspace, layout, focus). Honors a trailing `--json`.
fn listQuery(init: std.process.Init, sub: []const u8, args: *Args) u8 {
    const alloc = init.gpa;
    var json = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true;
    }
    var buf: [64]u8 = undefined;
    const req = if (json) std.fmt.bufPrint(&buf, "{s} --json", .{sub}) catch sub else sub;

    const resp = ipc.query(alloc, req) orelse {
        std.debug.print("agate is not running (no control socket). Start it with `agate`.\n", .{});
        return 1;
    };
    defer alloc.free(resp);
    std.debug.print("{s}", .{resp});
    return 0;
}

/// Print the contents of the config file agate would load.
fn showConfig(init: std.process.Init) u8 {
    const alloc = init.gpa;
    const p = paths.findConfigPath(alloc) orelse {
        std.debug.print("no config file found\n", .{});
        return 1;
    };
    defer alloc.free(p);
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, p, alloc, .unlimited) catch |err| {
        std.debug.print("could not read {s}: {s}\n", .{ p, @errorName(err) });
        return 1;
    };
    defer alloc.free(data);
    std.debug.print("{s}", .{data});
    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\agate — a macOS tiling window manager
        \\
        \\Usage:
        \\  agate                  Start the window manager daemon (one per user).
        \\  agate status           Show whether the daemon is running, and its PID.
        \\  agate stop             Tell the running daemon to quit.
        \\  agate config           Print the path of the config file agate loads.
        \\  agate config-show      Print the contents of that config file.
        \\  agate version          Print the agate version.
        \\  agate help             Show this help.
        \\
        \\Query the running daemon (add --json for machine-readable output):
        \\  agate list-windows     Managed windows: id, pid, app, bundle-id, title, workspace, monitor, layout.
        \\  agate list-workspaces  Workspaces: number, monitor, layout, type, visibility.
        \\  agate list-monitors    Monitors: number, size, origin, current workspace.
        \\
    , .{});
}
