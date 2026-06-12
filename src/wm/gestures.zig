//! Trackpad swipe gestures (the Hyprland-gestures equivalent for Small Screen
//! Mode): 3-/4-finger swipes recognized from raw MultitouchSupport contact
//! frames and dispatched to Lua gesture bindings (`agate.gesture`).
//!
//! Pipeline:
//!   MT thread: `contactCallback` → `Recognizer.feed` (pure math) → on a fired
//!   swipe, push onto a tiny mutex-guarded queue and signal a v0
//!   CFRunLoopSource on the main run loop.
//!   Main thread: `drainQueue` pops the queue and runs the Lua handler
//!   (`lua_config.handleGesture`) — Lua and the tree are main-thread-only.
//!
//! The recognizer is discrete-step, like Hyprland's workspace_swipe distance:
//! every `threshold` of normalized trackpad travel fires one swipe event, so a
//! long continuous swipe cycles through several windows.
const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const lua_config = @import("../config/lua.zig");

const c = macos.c;

pub const Swipe = enum { left, right, up, down };

/// A fired gesture: `fingers` fingers swiped one step in `dir`.
pub const Event = struct { fingers: u8, dir: Swipe };

/// Finger counts we recognize. 1–2 fingers are the cursor and scrolling; 3 and
/// 4 are gesture territory (whichever of them macOS isn't using system-wide is
/// free for agate; the user picks via their bindings).
const min_fingers = 3;
const max_fingers = 4;

/// Pure swipe recognizer fed one contact frame at a time. No OS types so the
/// logic is unit-testable: callers reduce a frame to (finger count, centroid).
pub const Recognizer = struct {
    /// Normalized trackpad travel that fires one swipe step. ~a quarter of the
    /// pad per step feels like Hyprland's default swipe distance.
    threshold: f32 = 0.22,

    /// Finger count of the gesture in progress (0 = none).
    active: u8 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    accum_x: f32 = 0,
    accum_y: f32 = 0,

    /// Feed one frame: `count` touching fingers with centroid (`cx`,`cy`) in
    /// normalized [0,1] coordinates (origin bottom-left, like MT reports).
    /// Returns a swipe step if the accumulated travel crossed the threshold.
    pub fn feed(self: *Recognizer, count: u8, cx: f32, cy: f32) ?Event {
        if (count != self.active) {
            // Finger count changed: begin a new gesture on a recognized count,
            // otherwise end the current one. Travel never carries across.
            self.active = if (count >= min_fingers and count <= max_fingers) count else 0;
            self.last_x = cx;
            self.last_y = cy;
            self.accum_x = 0;
            self.accum_y = 0;
            return null;
        }
        if (self.active == 0) return null;

        self.accum_x += cx - self.last_x;
        self.accum_y += cy - self.last_y;
        self.last_x = cx;
        self.last_y = cy;

        // Dominant-axis test, then step: consume one threshold of travel and
        // zero the cross axis so a sloppy diagonal doesn't double-fire.
        if (@abs(self.accum_x) >= self.threshold and @abs(self.accum_x) >= @abs(self.accum_y)) {
            const dir: Swipe = if (self.accum_x > 0) .right else .left;
            self.accum_x -= std.math.copysign(self.threshold, self.accum_x);
            self.accum_y = 0;
            return .{ .fingers = self.active, .dir = dir };
        }
        if (@abs(self.accum_y) >= self.threshold) {
            // MT normalizes with a bottom-left origin, so +y is up.
            const dir: Swipe = if (self.accum_y > 0) .up else .down;
            self.accum_y -= std.math.copysign(self.threshold, self.accum_y);
            self.accum_x = 0;
            return .{ .fingers = self.active, .dir = dir };
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// MT-thread side
// ---------------------------------------------------------------------------

var g_recognizer: Recognizer = .{};

/// Events fired on the MT thread, waiting for the main loop to drain them.
/// Tiny: a swipe fires a handful of steps per second at most.
var g_queue: [16]Event = undefined;
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

/// MultitouchSupport contact-frame callback (MT thread!). Reduce the frame to
/// (touching count, centroid), feed the recognizer, queue any fired event and
/// poke the main run loop. No allocation, no Lua, no tree access here.
fn contactCallback(
    _: macos.multitouch.DeviceRef,
    data: ?[*]macos.multitouch.Finger,
    nFingers: i32,
    _: f64,
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
    const event = g_recognizer.feed(count, sum_x / nf, sum_y / nf) orelse return 0;

    {
        lockQueue();
        defer unlockQueue();
        if (g_queue_len < g_queue.len) {
            g_queue[g_queue_len] = event;
            g_queue_len += 1;
        }
    }
    if (g_source) |src| {
        c.CFRunLoopSourceSignal(src);
        if (g_main_loop) |loop| c.CFRunLoopWakeUp(loop);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Main-thread side
// ---------------------------------------------------------------------------

/// The v0 source's perform callback — runs on the main run loop. Drain the
/// queue under the lock, then dispatch outside it (a Lua handler can run long).
fn drainQueue(_: ?*anyopaque) callconv(.c) void {
    var events: [g_queue.len]Event = undefined;
    var n: usize = 0;
    {
        lockQueue();
        defer unlockQueue();
        n = g_queue_len;
        @memcpy(events[0..n], g_queue[0..n]);
        g_queue_len = 0;
    }
    for (events[0..n]) |ev| _ = lua_config.handleGesture(ev.fingers, ev.dir);
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

test "three-finger swipe right fires after threshold travel" {
    var r = Recognizer{ .threshold = 0.2 };
    try testing.expect(r.feed(3, 0.4, 0.5) == null); // gesture begins, no travel yet
    try testing.expect(r.feed(3, 0.5, 0.5) == null); // 0.1 accumulated
    const ev = r.feed(3, 0.65, 0.5).?; // 0.25 total — crossed 0.2
    try testing.expectEqual(Swipe.right, ev.dir);
    try testing.expectEqual(@as(u8, 3), ev.fingers);
}

test "long swipe fires one step per threshold" {
    var r = Recognizer{ .threshold = 0.2 };
    _ = r.feed(3, 0.1, 0.5);
    try testing.expect(r.feed(3, 0.35, 0.5) != null); // 0.25 → step (0.05 kept)
    try testing.expect(r.feed(3, 0.45, 0.5) == null); // 0.15 accumulated
    try testing.expect(r.feed(3, 0.55, 0.5) != null); // 0.25 → second step
}

test "vertical swipe down fires with bottom-left origin" {
    var r = Recognizer{ .threshold = 0.2 };
    _ = r.feed(4, 0.5, 0.8);
    const ev = r.feed(4, 0.5, 0.55).?; // y dropped 0.25 → down
    try testing.expectEqual(Swipe.down, ev.dir);
    try testing.expectEqual(@as(u8, 4), ev.fingers);
}

test "dominant axis wins and the cross axis resets" {
    var r = Recognizer{ .threshold = 0.2 };
    _ = r.feed(3, 0.4, 0.4);
    const ev = r.feed(3, 0.65, 0.55).?; // dx 0.25 > dy 0.15 → horizontal
    try testing.expectEqual(Swipe.right, ev.dir);
    // The 0.15 of vertical drift was discarded with the step: another 0.15 of
    // travel must NOT fire (0.30 total would have, without the reset).
    try testing.expect(r.feed(3, 0.65, 0.70) == null);
}

test "finger-count change resets accumulated travel" {
    var r = Recognizer{ .threshold = 0.2 };
    _ = r.feed(3, 0.4, 0.5);
    try testing.expect(r.feed(3, 0.55, 0.5) == null); // 0.15 — below threshold
    try testing.expect(r.feed(2, 0.6, 0.5) == null); // dropped to 2 → gesture ends
    try testing.expect(r.feed(3, 0.7, 0.5) == null); // new gesture, travel reset
    try testing.expect(r.feed(3, 0.8, 0.5) == null); // only 0.1 since restart
}

test "one and two fingers never fire" {
    var r = Recognizer{ .threshold = 0.2 };
    try testing.expect(r.feed(1, 0.1, 0.5) == null);
    try testing.expect(r.feed(1, 0.9, 0.5) == null);
    try testing.expect(r.feed(2, 0.1, 0.5) == null);
    try testing.expect(r.feed(2, 0.9, 0.5) == null);
}
