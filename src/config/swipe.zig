//! Trackpad-gesture runtime (`agate.gesture`): the Liquid Glass edge-arrow HUD
//! that tracks an in-progress swipe and the dispatch of a committed swipe to its
//! bound action. Runs on the main run loop (see `wm/gestures.zig` for the
//! cross-thread marshalling). Bindings are registered in `api.agateGesture`.
const std = @import("std");
const macos = @import("macos");
const gestures = @import("../wm/gestures.zig");
const types = @import("types.zig");
const ctx = @import("context.zig");
const keybind = @import("keybind.zig");

const Config = types.Config;

/// State for the in-progress swipe's Liquid Glass arrow (the browser-style
/// back/forward affordance). The arrow only appears once the swipe has travelled
/// far enough to commit, and only for a direction the user actually bound.
var g_gesture_fingers: u8 = 0;
var g_gesture_axis: gestures.Axis = .horizontal;
var g_arrow_dir: ?gestures.Swipe = null;

/// Progress (normalized so ±1 == "far enough to commit") at which the arrow
/// appears, and the lower point at which it retracts — a little hysteresis so it
/// can't flicker when you hover right on the line.
const arrow_reveal: f32 = 1.0;
const arrow_conceal: f32 = 0.85;

/// True if a binding matches `fingers` + `dir` exactly.
fn gestureDirBound(cfg: *Config, fingers: u8, dir: gestures.Swipe) bool {
    for (cfg.gesture_bindings.items) |b| {
        if (b.fingers == fingers and b.dir == dir) return true;
    }
    return false;
}

/// Whether any 4-finger swipe is bound, used to decide whether to warn about the
/// conflicting native macOS gesture (see `wm/observer.zig`).
pub fn hasFourFingerGesture() bool {
    const cfg = ctx.config orelse return false;
    for (cfg.gesture_bindings.items) |b| if (b.fingers == 4) return true;
    return false;
}

/// The swipe direction for an axis + sign (progress is +right/+up).
fn dirOf(axis: gestures.Axis, positive: bool) gestures.Swipe {
    return switch (axis) {
        .horizontal => if (positive) .right else .left,
        .vertical => if (positive) .up else .down,
    };
}

/// Map a recognizer direction to the HUD's arrow direction. The arrow points
/// *against* the swipe and hugs the opposite edge — swipe right, a back-chevron
/// appears on the left, like Safari/Chrome's two-finger back/forward affordance.
fn hudDir(d: gestures.Swipe) macos.glass_hud.Dir {
    return switch (d) {
        .left => .right,
        .right => .left,
        .up => .down,
        .down => .up,
    };
}

/// Gesture lifecycle (main run loop; see `wm/gestures.zig`). A swipe begins once
/// it clears the deadzone; we just remember its axis and finger count. On
/// `update` we show or hide the edge arrow as the swipe crosses the commit
/// threshold, and on `end` we tear the arrow down and — if the swipe committed —
/// fire the bound action exactly once.
pub fn gestureBegin(fingers: u8, axis: gestures.Axis) void {
    g_gesture_fingers = fingers;
    g_gesture_axis = axis;
    g_arrow_dir = null;
}

pub fn gestureUpdate(fingers: u8, progress: f32) void {
    const cfg = ctx.config orelse return;
    // The peak finger count can climb after `begin` (a 4-finger swipe that
    // started as 3), so keep the HUD's notion of it current each frame.
    g_gesture_fingers = fingers;
    const mag = @abs(progress);
    const positive = progress >= 0;

    if (g_arrow_dir) |cur| {
        // Retract if we've fallen back under the threshold or reversed past
        // center — then fall through so a reversal can re-show the other way.
        const cur_positive = cur == .right or cur == .up;
        if (mag < arrow_conceal or positive != cur_positive) {
            macos.glass_hud.hide();
            g_arrow_dir = null;
        } else return;
    }
    if (mag >= arrow_reveal) {
        const dir = dirOf(g_gesture_axis, positive);
        if (gestureDirBound(cfg, g_gesture_fingers, dir)) {
            macos.glass_hud.show(hudDir(dir));
            g_arrow_dir = dir;
        }
    }
}

pub fn gestureEnd(fingers: u8, dir: ?gestures.Swipe) void {
    if (g_arrow_dir != null) macos.glass_hud.hide();
    g_arrow_dir = null;
    if (dir) |d| _ = handleGesture(fingers, d);
}

/// Dispatch a committed trackpad swipe against the registered gesture bindings
/// (`agate.gesture`). Runs on the main run loop (see `wm/gestures.zig` for the
/// marshalling) — safe to call Lua and the tree. Returns true if a binding
/// matched.
pub fn handleGesture(fingers: u8, dir: gestures.Swipe) bool {
    const cfg = ctx.config orelse return false;
    for (cfg.gesture_bindings.items) |b| {
        if (b.fingers != fingers or b.dir != dir) continue;
        keybind.runAction(cfg, b.action);
        return true;
    }
    return false;
}
