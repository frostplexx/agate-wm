//! Raw trackpad touches via the private `MultitouchSupport.framework`.
//!
//! CGEventTap never sees 3-/4-finger swipes — the window server consumes them
//! before tap level (and on macOS 26+ the gesture recognizers live in the Swift
//! WindowManager.framework, gated to real trackpad events). The only way to
//! build our own gestures (the Hyprland-style swipes Small Screen Mode wants)
//! is the same source BetterTouchTool/Swish use: MultitouchSupport's contact
//! frame callback, which streams every finger's normalized position per frame.
//!
//! The framework is private with no .tbd in the public SDK, so the symbols are
//! resolved at runtime with dlopen/dlsym — a missing framework or symbol just
//! means `start` returns false and the WM runs without gestures.
//!
//! The callback fires on a MultitouchSupport-owned thread, NOT the main run
//! loop. Callers must marshal back to the main thread themselves (see
//! `wm/gestures.zig`).
const std = @import("std");
const c = @import("c.zig").c;

/// One finger contact, as MultitouchSupport reports it. Layout reconstructed
/// from the de-facto community headers (the same struct every open-source
/// consumer uses; stable across macOS releases since 10.5).
pub const Point = extern struct { x: f32, y: f32 };
pub const Readout = extern struct { pos: Point, vel: Point };
pub const Finger = extern struct {
    frame: i32,
    timestamp: f64,
    identifier: i32,
    /// Touch phase; 4 = touching (1 hover, 2 starting, 3 pressing, 5/6/7 lift).
    state: i32,
    finger_id: i32,
    hand_id: i32,
    /// Normalized to the trackpad: x,y in [0,1], origin bottom-left.
    normalized: Readout,
    size: f32,
    pressure: i32,
    angle: f32,
    major_axis: f32,
    minor_axis: f32,
    absolute: Readout,
    unknown: [2]i32,
    z_density: f32,
};

pub const DeviceRef = ?*anyopaque;

/// `nFingers` entries of `data`; return value is ignored by the framework.
pub const ContactCallback = *const fn (
    device: DeviceRef,
    data: ?[*]Finger,
    nFingers: i32,
    timestamp: f64,
    frame: i32,
) callconv(.c) i32;

const MTDeviceCreateListFn = *const fn () callconv(.c) c.CFArrayRef;
const MTRegisterContactFrameCallbackFn = *const fn (DeviceRef, ContactCallback) callconv(.c) void;
const MTDeviceStartFn = *const fn (DeviceRef, i32) callconv(.c) i32;

const framework_path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

/// Open MultitouchSupport and register `callback` for contact frames on every
/// multitouch device (internal trackpad and external Magic Trackpads). Returns
/// the number of devices started — 0 means no gesture support (framework or
/// symbols missing, or no trackpad present, e.g. a Mac mini with only a mouse).
/// Devices are kept running for the process lifetime (no stop path needed).
pub fn start(callback: ContactCallback) usize {
    const handle = std.c.dlopen(framework_path, .{ .LAZY = true }) orelse return 0;
    const create_list: MTDeviceCreateListFn = @ptrCast(@alignCast(std.c.dlsym(handle, "MTDeviceCreateList") orelse return 0));
    const register_cb: MTRegisterContactFrameCallbackFn = @ptrCast(@alignCast(std.c.dlsym(handle, "MTRegisterContactFrameCallback") orelse return 0));
    const device_start: MTDeviceStartFn = @ptrCast(@alignCast(std.c.dlsym(handle, "MTDeviceStart") orelse return 0));

    const devices = create_list() orelse return 0;
    // The list and its devices are intentionally retained forever: stopping a
    // device mid-stream from its own callback thread is a known crash source in
    // MultitouchSupport, and the WM listens for its whole lifetime anyway.
    const n: usize = @intCast(c.CFArrayGetCount(devices));
    var started: usize = 0;
    for (0..n) |i| {
        const dev: DeviceRef = @constCast(c.CFArrayGetValueAtIndex(devices, @intCast(i)));
        register_cb(dev, callback);
        if (device_start(dev, 0) == 0) started += 1;
    }
    return started;
}
