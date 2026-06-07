//! Monotonic millisecond clock via libc `clock_gettime`. Zig 0.16 moved the
//! `std.time` timestamp helpers behind the Io interface; we only need a coarse
//! monotonic counter (for event de-duplication), so we call libc directly.
const CLOCK_MONOTONIC: c_int = 6; // <time.h> on Darwin

const timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;

/// Monotonic time in milliseconds. Not wall-clock; only differences are meaningful.
pub fn nowMs() i64 {
    var ts: timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}
