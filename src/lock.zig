//! Single-instance lock. The daemon holds an exclusive `flock` on a per-user
//! lock file for its whole lifetime; the kernel drops it automatically when the
//! process exits (cleanly or killed), so there is no stale-lock cleanup to do —
//! a leftover file with an old PID never blocks a fresh daemon. A second
//! invocation that can't take the lock knows a daemon is already running, and
//! reads the holder's PID from the file for reporting / signalling.
//!
//! Modelled on yabai's `/tmp/yabai_$USER.lock` (koekeishiya/yabai, src/misc/lock.c).
const std = @import("std");

// libc bits not surfaced by the Zig 0.16 std the way we need them; declare the
// handful we use directly (the codebase already does this for `fork`).
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn pread(fd: c_int, buf: [*]u8, nbyte: usize, offset: i64) isize;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, nbyte: usize, offset: i64) isize;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

// Darwin fcntl.h / sys/file.h constants.
const O_RDONLY: c_int = 0x0000;
const O_RDWR: c_int = 0x0002;
const O_CREAT: c_int = 0x0200;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
const LOCK_UN: c_int = 8;
const SIGTERM: c_int = 15;

/// A held lock. Keep it alive for the daemon's lifetime — dropping the value
/// does nothing, but letting the process exit releases the kernel lock. `fd` is
/// deliberately never closed while running.
pub const Lock = struct { fd: c_int };

pub const Acquire = union(enum) {
    /// We are now the sole daemon; the lock is held until exit.
    acquired: Lock,
    /// Another daemon already holds the lock; this is its PID (0 if unreadable).
    busy: i32,
};

/// `${TMPDIR:-/tmp}/agate-<uid>.lock`, NUL-terminated. Per-user so two accounts
/// can each run a daemon. Caller owns the slice.
fn lockPath(alloc: std.mem.Allocator) ![:0]u8 {
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const uid = std.c.getuid();
    // Strip a trailing slash so we don't produce a `//` (macOS TMPDIR has one).
    const base = std.mem.trimEnd(u8, tmp, "/");
    return std.fmt.allocPrintSentinel(alloc, "{s}/agate-{d}.lock", .{ base, uid }, 0);
}

fn readPid(fd: c_int) i32 {
    var buf: [32]u8 = undefined;
    const n = pread(fd, &buf, buf.len, 0);
    if (n <= 0) return 0;
    const text = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    return std.fmt.parseInt(i32, text, 10) catch 0;
}

/// Try to become the daemon. On success the lock is held (and our PID written);
/// on `busy` the running daemon's PID is returned.
pub fn acquire(alloc: std.mem.Allocator) !Acquire {
    const path = try lockPath(alloc);
    defer alloc.free(path);

    const fd = open(path.ptr, O_RDWR | O_CREAT, @as(c_uint, 0o600));
    if (fd < 0) return error.LockOpenFailed;

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        // Held by another process — read its PID for the caller, then let go of
        // our fd (closing it does NOT touch the other process's lock).
        const pid = readPid(fd);
        _ = close(fd);
        return .{ .busy = pid };
    }

    // Ours now. Record our PID so `status`/`stop` can find us.
    _ = ftruncate(fd, 0);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()}) catch "";
    if (text.len != 0) _ = pwrite(fd, text.ptr, text.len, 0);
    return .{ .acquired = .{ .fd = fd } };
}

/// The PID of the running daemon, or null if none is running. Determined by
/// probing the lock (file presence alone is unreliable — a crash leaves a stale
/// file but no held lock).
pub fn runningPid(alloc: std.mem.Allocator) ?i32 {
    const path = lockPath(alloc) catch return null;
    defer alloc.free(path);

    const fd = open(path.ptr, O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null; // no lock file → never started
    defer _ = close(fd);

    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
        // We took the lock, so nobody held it — not running. Release it again.
        _ = flock(fd, LOCK_UN);
        return null;
    }
    const pid = readPid(fd);
    return if (pid > 0) pid else 0; // running, PID possibly unknown
}

/// Ask the running daemon to terminate (SIGTERM). Returns false if none runs.
pub fn stop(alloc: std.mem.Allocator) bool {
    const pid = runningPid(alloc) orelse return false;
    if (pid <= 0) return false;
    return kill(pid, SIGTERM) == 0;
}

test "acquire is exclusive and reports the holder's pid" {
    const alloc = std.testing.allocator;
    const me: i32 = @intCast(std.c.getpid());
    switch (try acquire(alloc)) {
        // A real daemon is already running on this machine — can't test cleanly.
        .busy => return error.SkipZigTest,
        .acquired => |held| {
            defer _ = close(held.fd); // release the lock so the run leaves no trace
            // A second attempt (a distinct open file description) must be denied
            // even from the same process, and surface our PID from the file.
            const again = try acquire(alloc);
            try std.testing.expect(std.meta.activeTag(again) == .busy);
            try std.testing.expectEqual(me, again.busy);
            // ...and the probe used by `status`/`stop` agrees.
            try std.testing.expectEqual(@as(?i32, me), runningPid(alloc));
        },
    }
}
