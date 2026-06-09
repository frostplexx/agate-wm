//! Synthesize macOS Space-switch gestures by injecting a real **IOHIDEvent**
//! into the HID event system (IOKit SPI), rather than a CGEvent.
//!
//! Why: on macOS 26/27 (Tahoe) the Space-swipe recognizer moved into the Swift
//! `WindowManager` framework (`SystemGestureBase.handleEvent` →
//! `SpaceSwapSystemGesture`). RE of that path shows it calls
//! `CGEventCopyIOHIDEvent` on the incoming event and reads the gesture from the
//! *backing IOHIDEvent* — a synthetic CGEvent has none, so it's dropped (the
//! decoder returns the "invalid" tag and `handleEvent` skips it). There is no
//! public `CGEventCreateWithIOHIDEvent`, so we instead create a DockSwipe
//! IOHIDEvent and dispatch it through an `IOHIDEventSystemClient`, feeding the
//! same stream a real trackpad produces.
//!
//! Signatures were recovered by disassembling IOKit on this build (ipsw):
//! `IOHIDEventCreateDockSwipeEvent` is a wrapper over
//! `IOHIDEventCreateSwipeEventOfTypeWithFlavor` that injects
//! type=kIOHIDEventTypeDockSwipe(0x17) and flavor=3; its args land in
//! x2=mask(+0x1c), x3=phase(+0x20), x4=options, d0=progress(+0x24),
//! d1=x(+0x10), d2=y(+0x14).
//!
//! OPEN: whether `IOHIDEventSystemClientDispatchEvent` is honored from a normal
//! (non-Dock, unentitled) process is unknown until run — if it's gated, this
//! silently no-ops and a virtual-HID DriverKit extension would be the only way.
const std = @import("std");
const c = @import("c.zig").c;

pub const IOHIDEventRef = ?*anyopaque;
pub const IOHIDEventSystemClientRef = ?*anyopaque;

// IOHIDSwipeMask (IOKit/hid/IOHIDEventTypes.h).
const kIOHIDSwipeLeft: u32 = 0x4;
const kIOHIDSwipeRight: u32 = 0x8;
// IOHIDGesturePhaseBits.
const kIOHIDGesturePhaseBegan: u32 = 1;
const kIOHIDGesturePhaseChanged: u32 = 2;
const kIOHIDGesturePhaseEnded: u32 = 4;

pub extern fn IOHIDEventCreateDockSwipeEvent(
    allocator: ?*const anyopaque,
    time_stamp: u64,
    mask: u32,
    phase: u32,
    options: u32,
    progress: f64,
    x: f64,
    y: f64,
) IOHIDEventRef;
pub extern fn IOHIDEventSystemClientCreate(allocator: ?*const anyopaque) IOHIDEventSystemClientRef;
pub extern fn IOHIDEventSystemClientDispatchEvent(client: IOHIDEventSystemClientRef, event: IOHIDEventRef) void;
extern fn mach_absolute_time() u64;

/// Process-wide HID event client, created lazily.
var g_client: IOHIDEventSystemClientRef = null;
var g_client_tried: bool = false;

fn client() IOHIDEventSystemClientRef {
    if (!g_client_tried) {
        g_client_tried = true;
        g_client = IOHIDEventSystemClientCreate(null);
        if (g_client == null) std.debug.print("[iohid] IOHIDEventSystemClientCreate failed\n", .{});
    }
    return g_client;
}

fn dispatch(mask: u32, phase: u32, progress: f64, x: f64) void {
    const cl = client() orelse return;
    const ev = IOHIDEventCreateDockSwipeEvent(null, mach_absolute_time(), mask, phase, 0, progress, x, 0) orelse return;
    defer c.CFRelease(@ptrCast(ev));
    IOHIDEventSystemClientDispatchEvent(cl, ev);
}

/// Inject one full horizontal Dock swipe (began→changed→ended) to move one
/// Space in `dir`. Three phases are required, like a real trackpad swipe.
pub fn dispatchDockSwipe(right: bool) void {
    const mask = if (right) kIOHIDSwipeRight else kIOHIDSwipeLeft;
    const dx: f64 = if (right) 1.0 else -1.0;
    dispatch(mask, kIOHIDGesturePhaseBegan, 0.0, 0.0);
    dispatch(mask, kIOHIDGesturePhaseChanged, 1.0, dx);
    dispatch(mask, kIOHIDGesturePhaseEnded, 1.0, dx);
}
