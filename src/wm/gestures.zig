//! Trackpad swipe gestures (the Hyprland-gestures equivalent for Small Screen
//! Mode): 3-/4-finger swipes recognized from raw MultitouchSupport contact
//! frames and dispatched to Lua gesture bindings (`agate.gesture`).
//!
//! Pipeline:
//!   MT thread: `contactCallback` → `Recognizer.feed` (pure math) → on any
//!   phase change, push onto a tiny mutex-guarded queue and signal a v0
//!   CFRunLoopSource on the main run loop.
//!   Main thread: `drainQueue` pops the queue and drives the on-screen Liquid
//!   Glass HUD plus the Lua handler (`lua_config.gesture*`) — AppKit, Lua and
//!   the tree are all main-thread-only.
//!
//! The recognizer is *continuous*, like native macOS space switching (and
//! Hyprland's `workspace_swipe`): the HUD follows your fingers for the whole
//! swipe and the bound action commits exactly once, on lift — either because
//! you dragged far enough or because you flicked fast enough. This replaces the
//! old discrete "one action per quarter-pad step" model, which demanded a fast,
//! dead-straight horizontal swipe to register at all.
const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const lua_config = @import("../config/lua.zig");

const c = macos.c;

pub const Swipe = enum { left, right, up, down };

/// The axis a gesture locked onto once it cleared the deadzone. The HUD orients
/// itself along this axis; only the two directions on it can commit.
pub const Axis = enum { horizontal, vertical };

/// A gesture lifecycle event marshalled to the main thread.
pub const Phase = union(enum) {
    /// The swipe cleared the deadzone and locked an axis: show the HUD.
    begin: Begin,
    /// Continuous progress, signed and normalized so ±1 == "will commit".
    update: Update,
    /// Fingers lifted (or the count changed): hide the HUD and, if the swipe
    /// committed, fire the bound action for `dir` exactly once.
    end: End,

    pub const Begin = struct { fingers: u8, axis: Axis };
    pub const Update = struct { progress: f32 };
    pub const End = struct { fingers: u8, dir: ?Swipe };
};

/// Finger counts we recognize. 1–2 fingers are the cursor and scrolling; 3 and
/// 4 are gesture territory (whichever of them macOS isn't using system-wide is
/// free for agate; the user picks via their bindings).
const min_fingers = 3;
const max_fingers = 4;

/// Pure swipe recognizer fed one contact frame at a time. No OS types so the
/// logic is unit-testable: callers reduce a frame to (finger count, centroid,
/// timestamp). Tracks one continuous gesture and emits begin/update/end phases.
pub const Recognizer = struct {
    /// Travel (normalized pad units) before a gesture commits to an axis. Small,
    /// so the HUD appears almost immediately, but enough to ignore the tiny
    /// jitter of three fingers landing.
    deadzone: f32 = 0.03,
    /// Travel that arms the swipe: progress reaches ±1 here, the direction
    /// arrow appears, and releasing now commits. ~a sixth of the pad — a
    /// comfortable, deliberate drag, like a browser's back/forward swipe.
    commit_distance: f32 = 0.16,
    /// Release speed (normalized pad units/sec) that commits regardless of
    /// distance — a quick flick, like native macOS. This is the main fix for
    /// "only works when you swipe quickly": now a flick works at *any* length.
    /// (A flick commits without ever showing the arrow, also like a browser.)
    flick_speed: f32 = 2.0,
    /// Frames of a momentarily-wrong finger count tolerated mid-gesture before
    /// we treat it as a lift. Three fingers rarely land or leave in lockstep;
    /// without this a one-frame flicker would abort an in-progress swipe.
    lift_grace: u8 = 4,

    /// Finger count locked at gesture start (0 = no gesture in progress).
    active: u8 = 0,
    /// Axis locked after clearing the deadzone (null = still in the deadzone, no
    /// `begin` emitted yet).
    axis: ?Axis = null,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_t: f64 = 0,
    /// Signed cumulative travel from gesture start, per axis.
    travel_x: f32 = 0,
    travel_y: f32 = 0,
    /// Signed, lightly-smoothed speed along the locked axis (pad units/sec).
    velocity: f32 = 0,
    /// Consecutive frames seen with a wrong finger count (see `lift_grace`).
    grace: u8 = 0,

    fn recognized(count: u8) bool {
        return count >= min_fingers and count <= max_fingers;
    }

    fn begin(self: *Recognizer, count: u8, cx: f32, cy: f32, t: f64) void {
        self.active = count;
        self.axis = null;
        self.last_x = cx;
        self.last_y = cy;
        self.last_t = t;
        self.travel_x = 0;
        self.travel_y = 0;
        self.velocity = 0;
        self.grace = 0;
    }

    /// Direction the gesture would commit to, or null if it falls short of both
    /// the distance and flick thresholds.
    fn committedDir(self: *const Recognizer) ?Swipe {
        const axis = self.axis orelse return null;
        const dist = if (axis == .horizontal) @abs(self.travel_x) else @abs(self.travel_y);
        const speed = @abs(self.velocity);
        const flicked = speed >= self.flick_speed and dist >= self.deadzone;
        const dragged = dist >= self.commit_distance;
        if (!flicked and !dragged) return null;
        // A fast flick trusts the release velocity; a slow drag trusts the net
        // displacement (so a drag-out-and-back-a-bit still commits outward).
        const positive = if (flicked) self.velocity > 0 else (if (axis == .horizontal) self.travel_x > 0 else self.travel_y > 0);
        return switch (axis) {
            .horizontal => if (positive) .right else .left,
            .vertical => if (positive) .up else .down,
        };
    }

    /// End the current gesture and report it. Returns an `end` phase only if a
    /// `begin` was emitted (i.e. the gesture cleared the deadzone); a swipe that
    /// never left the deadzone is invisible to the main thread.
    fn finish(self: *Recognizer) ?Phase {
        const had_axis = self.axis != null;
        const fingers = self.active;
        const dir = self.committedDir();
        self.active = 0;
        self.axis = null;
        self.velocity = 0;
        self.grace = 0;
        if (!had_axis) return null;
        return .{ .end = .{ .fingers = fingers, .dir = dir } };
    }

    /// Feed one frame: `count` touching fingers with centroid (`cx`,`cy`) in
    /// normalized [0,1] coordinates (origin bottom-left, like MT reports) at
    /// time `t` (seconds). Returns at most one phase transition per frame.
    pub fn feed(self: *Recognizer, count: u8, cx: f32, cy: f32, t: f64) ?Phase {
        if (self.active == 0) {
            // Idle: start tracking only on a clean recognized count.
            if (recognized(count)) self.begin(count, cx, cy, t);
            return null;
        }

        if (count != self.active) {
            // A clean lift (no contacts at all) is unambiguous: end now.
            if (count == 0) return self.finish();
            if (recognized(count)) {
                // Switched to the *other* gesture count (3↔4): end this one;
                // the next frame starts the new gesture fresh.
                return self.finish();
            }
            // A partial wrong count (1–2 fingers, or a phantom contact). Tolerate
            // a few frames — fingers seldom land/leave together — by freezing the
            // gesture: don't integrate the jittery centroid, just wait it out.
            self.grace += 1;
            if (self.grace <= self.lift_grace) return null;
            return self.finish();
        }
        self.grace = 0;

        const fdx = cx - self.last_x;
        const fdy = cy - self.last_y;
        const dt = t - self.last_t;
        self.last_x = cx;
        self.last_y = cy;
        self.last_t = t;
        self.travel_x += fdx;
        self.travel_y += fdy;

        if (self.axis == null) {
            // Still in the deadzone: lock an axis once either component clears
            // it, then announce the gesture. Locking means a slightly diagonal
            // swipe still reads cleanly as horizontal/vertical for its whole
            // length — the fix for "only works when exactly horizontal".
            if (@abs(self.travel_x) < self.deadzone and @abs(self.travel_y) < self.deadzone) return null;
            const axis: Axis = if (@abs(self.travel_x) >= @abs(self.travel_y)) .horizontal else .vertical;
            self.axis = axis;
            // Seed velocity from this frame so even a flick that locks and lifts
            // in two frames carries a speed.
            if (dt > 0) self.velocity = (if (axis == .horizontal) fdx else fdy) / @as(f32, @floatCast(dt));
            return .{ .begin = .{ .fingers = self.active, .axis = axis } };
        }

        const axis = self.axis.?;
        const frame_along = if (axis == .horizontal) fdx else fdy;
        const travel_along = if (axis == .horizontal) self.travel_x else self.travel_y;
        if (dt > 0) {
            const inst = frame_along / @as(f32, @floatCast(dt));
            // Light EMA so a single noisy frame at release can't fake a flick.
            self.velocity = self.velocity * 0.5 + inst * 0.5;
        }
        return .{ .update = .{ .progress = travel_along / self.commit_distance } };
    }
};

// ---------------------------------------------------------------------------
// MT-thread side
// ---------------------------------------------------------------------------

var g_recognizer: Recognizer = .{};

/// True once the user has bound at least one `agate.gesture`. Set from the main
/// thread at config load; read on the event-tap thread. While false we never
/// swallow scroll, so a config with no gestures leaves the trackpad untouched.
pub var g_enabled: std.atomic.Value(bool) = .init(false);

/// True while a 3-/4-finger gesture is in progress (mirrors `Recognizer.active`,
/// updated every contact frame). Read on the event-tap thread to decide whether
/// to swallow the scroll events macOS would otherwise hand the app underneath.
var g_active: std.atomic.Value(bool) = .init(false);

/// Whether scroll-wheel events should be swallowed right now: a bound gesture is
/// actively being performed. The system consumes its own multi-finger swipes
/// before tap level; we have to consume the scroll ourselves so the window below
/// doesn't also scroll (the role the event tap plays in `wm/observer.zig`).
pub fn blockingScroll() bool {
    return g_enabled.load(.acquire) and g_active.load(.acquire);
}

/// Phases fired on the MT thread, waiting for the main loop to drain them.
/// Tiny: begin/end are rare and consecutive `update`s coalesce in place, so the
/// queue holds at most a couple of entries between drains.
var g_queue: [16]Phase = undefined;
var g_queue_len: usize = 0;
/// Spinlock guarding the queue. Zig 0.16's `std.Io.Mutex` needs an `Io` handle
/// the MT callback thread doesn't have; the critical section is a few-byte
/// copy, so spinning is cheaper than any syscall-backed lock anyway.
var g_queue_lock: std.atomic.Value(bool) = .init(false);

fn lockQueue() void {
    while (g_queue_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockQueue() void {
    g_queue_lock.store(false, .release);
}

var g_source: c.CFRunLoopSourceRef = null;
var g_main_loop: c.CFRunLoopRef = null;

/// Enqueue a phase, coalescing a run of `update`s into the latest one so a slow
/// drain never lags behind the finger.
fn enqueue(phase: Phase) void {
    lockQueue();
    defer unlockQueue();
    if (phase == .update and g_queue_len > 0 and g_queue[g_queue_len - 1] == .update) {
        g_queue[g_queue_len - 1] = phase;
        return;
    }
    if (g_queue_len < g_queue.len) {
        g_queue[g_queue_len] = phase;
        g_queue_len += 1;
    }
}

/// MultitouchSupport contact-frame callback (MT thread!). Reduce the frame to
/// (touching count, centroid), feed the recognizer, queue any fired phase and
/// poke the main run loop. No allocation, no Lua, no tree access here.
fn contactCallback(
    _: macos.multitouch.DeviceRef,
    data: ?[*]macos.multitouch.Finger,
    nFingers: i32,
    timestamp: f64,
    _: i32,
) callconv(.c) i32 {
    const fingers = if (data) |d| d[0..@intCast(@max(nFingers, 0))] else &[_]macos.multitouch.Finger{};

    var count: u8 = 0;
    var sum_x: f32 = 0;
    var sum_y: f32 = 0;
    for (fingers) |f| {
        // States 2..5 are on-pad phases (starting/pressing/touching/lingering);
        // 1 is hovering and ≥6 is lift-off — those would jitter the centroid.
        if (f.state < 2 or f.state > 5) continue;
        count += 1;
        sum_x += f.normalized.pos.x;
        sum_y += f.normalized.pos.y;
    }
    const nf: f32 = @floatFromInt(@max(count, 1));
    const phase = g_recognizer.feed(count, sum_x / nf, sum_y / nf, timestamp);
    // Publish liveness every frame (even when `feed` reports nothing) so the
    // scroll-blocking tap arms the instant the fingers land and disarms on lift.
    g_active.store(g_recognizer.active != 0, .release);

    if (phase) |p| {
        enqueue(p);
        if (g_source) |src| {
            c.CFRunLoopSourceSignal(src);
            if (g_main_loop) |loop| c.CFRunLoopWakeUp(loop);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Main-thread side
// ---------------------------------------------------------------------------

/// The v0 source's perform callback — runs on the main run loop. Drain the
/// queue under the lock, then dispatch outside it (a Lua handler can run long).
fn drainQueue(_: ?*anyopaque) callconv(.c) void {
    var events: [g_queue.len]Phase = undefined;
    var n: usize = 0;
    {
        lockQueue();
        defer unlockQueue();
        n = g_queue_len;
        @memcpy(events[0..n], g_queue[0..n]);
        g_queue_len = 0;
    }
    for (events[0..n]) |ev| switch (ev) {
        .begin => |b| lua_config.gestureBegin(b.fingers, b.axis),
        .update => |u| lua_config.gestureUpdate(u.progress),
        .end => |e| lua_config.gestureEnd(e.fingers, e.dir),
    };
}

/// Start gesture recognition: install the main-loop dispatch source, then
/// register with MultitouchSupport. Call from the main thread before the run
/// loop runs. Returns false when no trackpad/framework is available — the WM
/// just runs without gestures.
pub fn start() bool {
    var ctx = c.CFRunLoopSourceContext{
        .version = 0,
        .info = null,
        .retain = null,
        .release = null,
        .copyDescription = null,
        .equal = null,
        .hash = null,
        .schedule = null,
        .cancel = null,
        .perform = drainQueue,
    };
    const src = c.CFRunLoopSourceCreate(null, 0, &ctx) orelse return false;
    g_main_loop = c.CFRunLoopGetCurrent();
    c.CFRunLoopAddSource(g_main_loop, src, c.kCFRunLoopCommonModes);
    g_source = src;

    const devices = macos.multitouch.start(contactCallback);
    if (devices == 0) {
        std.debug.print("[gestures] no multitouch device; trackpad gestures disabled\n", .{});
        return false;
    }
    std.debug.print("[gestures] listening on {d} multitouch device(s)\n", .{devices});
    return true;
}

// ---------------------------------------------------------------------------
// Tests — drive the pure recognizer with synthetic centroid frames.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Advance one frame and return the phase (if any). Frames are spaced 10ms so
/// the velocity math sees a plausible dt.
const Driver = struct {
    r: Recognizer,
    t: f64 = 0,
    fn step(self: *Driver, count: u8, cx: f32, cy: f32) ?Phase {
        self.t += 0.01;
        return self.r.feed(count, cx, cy, self.t);
    }
};

test "swipe begins only after clearing the deadzone, then updates" {
    var d = Driver{ .r = .{ .deadzone = 0.04, .commit_distance = 0.2 } };
    try testing.expect(d.step(3, 0.40, 0.5) == null); // first contact, no travel
    try testing.expect(d.step(3, 0.42, 0.5) == null); // 0.02 — inside deadzone
    const b = d.step(3, 0.46, 0.5).?; // 0.06 — clears it
    try testing.expectEqual(Axis.horizontal, b.begin.axis);
    try testing.expectEqual(@as(u8, 3), b.begin.fingers);
    const u = d.step(3, 0.50, 0.5).?;
    try testing.expect(u == .update);
    try testing.expect(u.update.progress > 0); // moving right → positive
}

test "a deliberate drag past the commit distance commits on lift" {
    var d = Driver{ .r = .{ .deadzone = 0.04, .commit_distance = 0.2, .flick_speed = 100 } };
    _ = d.step(3, 0.30, 0.5);
    _ = d.step(3, 0.45, 0.5);
    _ = d.step(3, 0.55, 0.5); // travelled 0.25 > 0.2
    const e = d.step(0, 0.55, 0.5).?; // fingers lift
    try testing.expectEqual(Swipe.right, e.end.dir.?);
}

test "a short fast flick commits even below the drag distance" {
    var d = Driver{ .r = .{ .deadzone = 0.03, .commit_distance = 0.4, .flick_speed = 1.0 } };
    _ = d.step(3, 0.50, 0.5);
    _ = d.step(3, 0.55, 0.5); // 0.05 in 10ms → 5 units/sec, well past flick_speed
    const e = d.step(0, 0.55, 0.5).?; // all fingers gone
    try testing.expectEqual(Swipe.right, e.end.dir.?); // far short of 0.4 but flicked
}

test "a tiny drag that never commits ends with no direction" {
    var d = Driver{ .r = .{ .deadzone = 0.03, .commit_distance = 0.4, .flick_speed = 100 } };
    _ = d.step(3, 0.50, 0.5);
    _ = d.step(3, 0.54, 0.5); // cleared deadzone (begin) but only 0.04 travel
    const e = d.step(0, 0.54, 0.5).?;
    try testing.expect(e.end.dir == null);
}

test "axis locks: a diagonal swipe reads as its dominant axis throughout" {
    var d = Driver{ .r = .{ .deadzone = 0.03, .commit_distance = 0.08, .flick_speed = 100 } };
    _ = d.step(3, 0.40, 0.40);
    const b = d.step(3, 0.48, 0.45).?; // dx 0.08 > dy 0.05 → horizontal lock
    try testing.expectEqual(Axis.horizontal, b.begin.axis);
    // Now drift mostly vertically; the lock holds, so it must NOT become a
    // vertical swipe. Net horizontal travel still commits right.
    _ = d.step(3, 0.50, 0.70);
    const e = d.step(0, 0.50, 0.70).?;
    try testing.expectEqual(Swipe.right, e.end.dir.?);
    try testing.expect(e.end.dir != .up and e.end.dir != .down);
}

test "a one-frame finger-count flicker does not abort the gesture" {
    var d = Driver{ .r = .{ .deadzone = 0.03, .commit_distance = 0.1, .flick_speed = 100, .lift_grace = 4 } };
    _ = d.step(3, 0.30, 0.5);
    _ = d.step(3, 0.40, 0.5); // begin (cleared deadzone)
    try testing.expect(d.step(2, 0.40, 0.5) == null); // phantom drop — tolerated
    _ = d.step(3, 0.48, 0.5); // recovers and keeps travelling
    const e = d.step(0, 0.48, 0.5).?; // real lift
    try testing.expectEqual(Swipe.right, e.end.dir.?); // gesture survived
}

test "vertical swipe down commits with bottom-left origin" {
    var d = Driver{ .r = .{ .deadzone = 0.03, .commit_distance = 0.2, .flick_speed = 100 } };
    _ = d.step(4, 0.5, 0.80);
    _ = d.step(4, 0.5, 0.70);
    _ = d.step(4, 0.5, 0.56); // y dropped 0.24 → down
    const e = d.step(0, 0.5, 0.56).?;
    try testing.expectEqual(Swipe.down, e.end.dir.?);
    try testing.expectEqual(@as(u8, 4), e.end.fingers);
}

test "one and two fingers never start a gesture" {
    var d = Driver{ .r = .{} };
    try testing.expect(d.step(1, 0.1, 0.5) == null);
    try testing.expect(d.step(1, 0.9, 0.5) == null);
    try testing.expect(d.step(2, 0.1, 0.5) == null);
    try testing.expect(d.step(2, 0.9, 0.5) == null);
}
