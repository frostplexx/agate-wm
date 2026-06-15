//! Launching shell commands from a keybind (`agate.exec` / the `exec` command).
const std = @import("std");

// `fork` isn't exposed by the Zig 0.16 std (it's a private extern in std.c), but
// `execve`/`waitpid`/`setsid`/`environ`/`_exit` are — declare just `fork`.
extern "c" fn fork() std.c.pid_t;

/// Launch `cmd` through the user's shell without blocking the WM or leaving a
/// zombie behind. Modelled on skhd's `fork_exec` (koekeishiya/skhd): a
/// double-fork daemonizes the worker — the grandchild execs the shell and, once
/// the intermediate child exits, is reparented to launchd, which reaps it; we
/// wait out the intermediate child here so nothing lingers.
///
/// All allocation and env lookup happen in the parent *before* `fork`, because
/// the process is multithreaded (the multitouch thread) and only
/// async-signal-safe calls are legal between `fork` and `execve` in the child.
pub fn spawnShell(alloc: std.mem.Allocator, cmd: []const u8) void {
    if (cmd.len == 0) return;
    const cmdz = alloc.dupeZ(u8, cmd) catch return;
    defer alloc.free(cmdz);

    const shell: [*:0]const u8 = blk: {
        if (std.c.getenv("SHELL")) |s| {
            if (s[0] != 0) break :blk s;
        }
        break :blk "/bin/sh";
    };

    const pid = fork();
    if (pid < 0) {
        std.debug.print("[exec] fork failed for: {s}\n", .{cmd});
        return;
    }
    if (pid == 0) {
        // Intermediate child: detach into its own session, fork the worker, leave.
        _ = std.c.setsid();
        if (fork() == 0) {
            const argv = [_:null]?[*:0]const u8{ shell, "-c", cmdz.ptr };
            _ = std.c.execve(shell, &argv, @ptrCast(std.c.environ));
            std.c._exit(127); // execve only returns on failure
        }
        std.c._exit(0); // orphan the worker so launchd adopts (and reaps) it
    }
    // Parent: the intermediate child exits at once — reap it so it's no zombie.
    _ = std.c.waitpid(pid, null, 0);
}
