//! Window-frame animation, AX-driven — because nothing else can move other
//! apps' windows on this macOS.
//!
//! Probed live (tools/transform_probe.m): `SLSSetWindowTransform` and the
//! transaction variant both return success for foreign windows but the
//! write is silently IGNORED (read-back unchanged; own windows store fine),
//! and no `SLSBridged*` window-transform operation exists — the bridged ops
//! are all space-level. Window-server transform animation (yabai's model)
//! therefore requires Dock injection, which agate won't do. What remains is
//! interpolating the frame through Accessibility, engineered to stay cheap:
//!
//!   * The final SIZE is applied once, up front — resizing is the expensive
//!     part (the app relayouts); a position move is a near-free server-side
//!     reshuffle the app barely participates in.
//!   * Ticks interpolate POSITION only: one `AXPosition` set per window per
//!     tick, 60 Hz, ease-out cubic, at most `max_windows` windows.
//!   * A per-tick time budget watches the synchronous AX calls; a slow app
//!     (busy main thread) blowing the budget twice ends the animation in a
//!     snap instead of letting the whole WM stutter.
//!   * `AXEnhancedUserInterface` stays disabled for every animated app for
//!     the sweep's duration (the flush's guard is handed over), so AppKit
//!     doesn't add its own easing on top of each tick.
//!
//! Everything is fixed-size and allocation-free. Speed knob:
//! `agate.config{ animation_duration }` in MILLISECONDS.
const std = @import("std");
const macos = @import("macos");
const layout = @import("layout.zig");

const c = macos.c;
const Rect = macos.window_list.Rect;

/// Animation length in milliseconds. 0 disables (flushes snap). Set from Lua.
pub var duration_ms: f64 = 150;

/// Most windows animated per flush; extras just snap. Bounds a tick's worst
/// case: this many synchronous AX position sets.
const max_windows = 8;
/// Tick rate. 60 Hz is plenty for a 100–300 ms ease; doubling it would double
/// the AX traffic for no visible gain.
const tick_interval: f64 = 1.0 / 60.0;
/// A tick spending more than this on AX calls means some app's main thread is
/// busy; two strikes and the animation finishes early (windows snap to place).
const tick_budget_s: f64 = 0.010;

const Move = struct {
    /// Retained by `add`, released in `finishNow` — the tree's leaf (and its
    /// element reference) can vanish mid-animation when a window closes.
    el: *macos.Element,
    from: Rect,
    to: Rect,
};

var g_moves: [max_windows]Move = undefined;
var g_count: usize = 0;
var g_pending: usize = 0; // collection cursor between begin() and commit()
var g_start_time: f64 = 0;
var g_timer: c.CFRunLoopTimerRef = null;
var g_over_budget: u32 = 0;
/// The flush's EUI guard, owned by the animator until the sweep ends.
var g_eui: ?layout.EuiGuard = null;

/// Whether animation is configured on.
pub fn enabled() bool {
    return duration_ms >= 1;
}

/// Whether this frame change is worth animating (the move is perceptible).
pub fn shouldAnimate(from: Rect, to: Rect) bool {
    const eps: f64 = 2;
    return @abs(from.origin.x - to.origin.x) > eps or
        @abs(from.origin.y - to.origin.y) > eps or
        @abs(from.size.width - to.size.width) > eps or
        @abs(from.size.height - to.size.height) > eps;
}

/// Begin collecting one flush's moves. Caller: layout.flushWorkspace.
///
/// Finishes any still-in-flight previous batch FIRST: `add` overwrites the
/// `g_moves` slots, so the previous batch's retained elements must be released
/// (via `finishNow`) before we reuse those slots — otherwise `commit`'s own
/// `finishNow` would release the *new* batch's elements (the ones just written
/// into those slots) and they'd be released a second time when this batch ends,
/// over-releasing the AX element (a use-after-free → crash). Harmless when no
/// batch is live (the common case: the prior animation already completed).
pub fn begin() void {
    finishNow();
    g_pending = 0;
}

/// Track `el` (the window's AX element) for the position sweep `from` → `to`.
/// Returns false when the per-flush slots are full — the caller then just
/// applies the final frame directly. Retains `el`.
pub fn add(el: *macos.Element, from: Rect, to: Rect) bool {
    if (g_pending >= max_windows) return false;
    el.retain();
    g_moves[g_pending] = .{ .el = el, .from = from, .to = to };
    g_pending += 1;
    return true;
}

/// Start sweeping the collected moves, taking ownership of the flush's EUI
/// guard (restored when the sweep ends, so AppKit can't ease our ticks). Any
/// previous sweep still in flight is finished first.
pub fn commit(eui: layout.EuiGuard) void {
    finishNow();
    g_eui = eui;
    if (g_pending == 0) {
        restoreEui();
        return;
    }
    g_count = g_pending;
    g_pending = 0;
    g_over_budget = 0;
    g_start_time = c.CFAbsoluteTimeGetCurrent();

    var timer_ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = null,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const timer = c.CFRunLoopTimerCreate(
        null,
        g_start_time + tick_interval,
        tick_interval,
        0,
        0,
        tickFired,
        &timer_ctx,
    ) orelse {
        finishNow();
        return;
    };
    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopCommonModes);
    g_timer = timer;
}

fn tickFired(_: c.CFRunLoopTimerRef, _: ?*anyopaque) callconv(.c) void {
    const t = (c.CFAbsoluteTimeGetCurrent() - g_start_time) / (duration_ms / 1000.0);
    if (t >= 1.0) {
        finishNow();
        return;
    }
    // Ease-out cubic: fast start, gentle landing — reads as "snappy".
    const inv = 1.0 - t;
    const eased = 1.0 - inv * inv * inv;

    const tick_start = c.CFAbsoluteTimeGetCurrent();
    for (g_moves[0..g_count]) |m| {
        _ = m.el.setPosition(.{
            .x = lerp(m.from.origin.x, m.to.origin.x, eased),
            .y = lerp(m.from.origin.y, m.to.origin.y, eased),
        });
    }
    // Synchronous AX cost check: a busy app stalls every set sent to it. Two
    // bad ticks → land everything now rather than stutter through the rest.
    if (c.CFAbsoluteTimeGetCurrent() - tick_start > tick_budget_s) {
        g_over_budget += 1;
        if (g_over_budget >= 2) finishNow();
    }
}

/// Land every in-flight window exactly (final position, size re-asserted for
/// apps that clamp), release the elements, restore EUI, stop the timer.
fn finishNow() void {
    if (g_timer) |timer| {
        c.CFRunLoopTimerInvalidate(timer);
        c.CFRelease(timer);
        g_timer = null;
    }
    for (g_moves[0..g_count]) |m| {
        _ = m.el.setPosition(m.to.origin);
        _ = m.el.setSize(m.to.size);
        m.el.release();
    }
    g_count = 0;
    restoreEui();
}

fn restoreEui() void {
    if (g_eui) |*eui| {
        eui.restore();
        g_eui = null;
    }
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

// ---------------------------------------------------------------------------
// Tests — the pure parts only (AX elements need a window server).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rect(x: f64, y: f64, w: f64, h: f64) Rect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "shouldAnimate ignores sub-pixel noise, catches real moves and resizes" {
    try testing.expect(!shouldAnimate(rect(0, 0, 100, 100), rect(1, 1, 100, 100)));
    try testing.expect(shouldAnimate(rect(0, 0, 100, 100), rect(50, 0, 100, 100)));
    try testing.expect(shouldAnimate(rect(0, 0, 100, 100), rect(0, 0, 180, 100)));
}

test "lerp endpoints and midpoint" {
    try testing.expectApproxEqAbs(10.0, lerp(10, 50, 0), 1e-9);
    try testing.expectApproxEqAbs(50.0, lerp(10, 50, 1), 1e-9);
    try testing.expectApproxEqAbs(30.0, lerp(10, 50, 0.5), 1e-9);
}
