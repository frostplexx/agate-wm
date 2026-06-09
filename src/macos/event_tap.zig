//! Hand-written `extern` declarations for CoreGraphics' event-tap API
//! (`CGEventTap*`). `<CoreGraphics/CGEvent.h>` can't go through `@cImport` (the
//! CoreGraphics umbrella defeats translate-c — see `c.zig`), so the small slice
//! we need is declared here. Symbols resolve from CoreGraphics, which is linked.
//!
//! We use this read-only (listen-only) to learn when the user presses and
//! releases the left mouse button, so window drags are applied on mouse-up
//! rather than on a timer — the role yabai's mouse event tap plays
//! (koekeishiya/yabai, src/mouse_handler.c).
const std = @import("std");
const c = @import("c.zig").c;

pub const EventRef = ?*anyopaque;
pub const EventTapProxy = ?*anyopaque;
pub const MachPortRef = ?*anyopaque;

pub const EventType = u32;
pub const kCGEventLeftMouseDown: EventType = 1;
pub const kCGEventLeftMouseUp: EventType = 2;
pub const kCGEventLeftMouseDragged: EventType = 6;
pub const kCGEventKeyDown: EventType = 10;
pub const kCGEventKeyUp: EventType = 11;
pub const kCGEventFlagsChanged: EventType = 12;
// The system disables a tap that is too slow or interrupted; the callback must
// re-enable it (yabai, src/mouse_handler.c).
pub const kCGEventTapDisabledByTimeout: EventType = 0xFFFFFFFE;
pub const kCGEventTapDisabledByUserInput: EventType = 0xFFFFFFFF;

pub const EventMask = u64;
/// The event-mask bit for an event type.
pub fn mask(t: EventType) EventMask {
    return @as(EventMask, 1) << @intCast(t);
}

pub const TapLocation = u32;
pub const kCGHIDEventTap: TapLocation = 0; // lowest level — best for injecting real keystrokes
pub const kCGSessionEventTap: TapLocation = 1;
/// Downstream of all session taps: events here have already been annotated/
/// modified by other session taps (e.g. a key remapper like lazykeys). Tapping
/// here makes us see those modifications regardless of tap insertion order —
/// unlike a session tap, whose head/tail placement races other session taps.
pub const kCGAnnotatedSessionEventTap: TapLocation = 2;
pub const TapPlacement = u32;
pub const kCGHeadInsertEventTap: TapPlacement = 0; // runs before pre-existing taps
pub const kCGTailAppendEventTap: TapPlacement = 1; // runs after pre-existing taps
pub const TapOptions = u32;
pub const kCGEventTapOptionDefault: TapOptions = 0; // intercepting tap (can swallow events)
pub const kCGEventTapOptionListenOnly: TapOptions = 1;

// Modifier flag bits present in CGEventGetFlags output.
pub const kCGEventFlagMaskShift: u64 = 0x0002_0000;
pub const kCGEventFlagMaskControl: u64 = 0x0004_0000;
pub const kCGEventFlagMaskAlternate: u64 = 0x0008_0000; // Option key
pub const kCGEventFlagMaskCommand: u64 = 0x0010_0000;
/// Combined mask for all four standard modifier keys.
pub const kCGModifiersMask: u64 =
    kCGEventFlagMaskShift | kCGEventFlagMaskControl |
    kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;

// CGEventField enum value for the virtual key code.
pub const CGEventField = u32;
pub const kCGKeyboardEventKeycode: CGEventField = 9;

pub extern fn CGEventGetIntegerValueField(event: EventRef, field: CGEventField) i64;
pub extern fn CGEventGetFlags(event: EventRef) u64;

/// The *current* modifier-flag state for an event source, independent of any
/// particular event. We need this because a key remapper (lazykeys) can hold a
/// "hyper" chord whose flags never appear on the individual key event our tap
/// sees (tap-ordering against the remapper), yet the modifiers are active —
/// querying the combined session state recovers them. `stateID` 0 = combined
/// session state.
pub const CGEventSourceStateID = u32;
pub const kCGEventSourceStateCombinedSessionState: CGEventSourceStateID = 0;
pub const kCGEventSourceStateHIDSystemState: CGEventSourceStateID = 1;
pub extern fn CGEventSourceFlagsState(stateID: CGEventSourceStateID) u64;

/// Listen-only callback. Return `event` unchanged (we don't modify the stream).
pub const TapCallBack = *const fn (
    proxy: EventTapProxy,
    type: EventType,
    event: EventRef,
    userInfo: ?*anyopaque,
) callconv(.c) EventRef;

pub extern fn CGEventTapCreate(
    tap: TapLocation,
    place: TapPlacement,
    options: TapOptions,
    eventsOfInterest: EventMask,
    callback: TapCallBack,
    userInfo: ?*anyopaque,
) MachPortRef;
pub extern fn CGEventTapEnable(tap: MachPortRef, enable: bool) void;
/// The cursor location (global, top-left origin) carried by a mouse event.
pub extern fn CGEventGetLocation(event: EventRef) c.CGPoint;
pub extern fn CFMachPortCreateRunLoopSource(
    allocator: ?*const anyopaque,
    port: MachPortRef,
    order: c.CFIndex,
) c.CFRunLoopSourceRef;

// ---------------------------------------------------------------------------
// Synthetic Dock-swipe gesture (instant Space switching)
// ---------------------------------------------------------------------------
//
// A direct `SLSManagedDisplaySetCurrentSpace` switches the window-server's
// active Space but bypasses Dock.app — which owns Mission Control and the menu
// bar — so the menu bar is left stale (overlapping menus). Instead we
// synthesize the same horizontal Dock-swipe CGEvent that a trackpad emits, the
// way InstantSpaceSwitcher does (jurplel/InstantSpaceSwitcher, Sources/ISS/ISS.c).
// Dock.app runs its own transition in response, so the menu bar stays correct.
//
// These CGEvent "field" numbers and the `DockControl` event type are private
// (not in any public header); the values are the ones ISS reverse-engineered.

pub extern fn CGEventCreate(source: ?*anyopaque) EventRef;
pub extern fn CGEventSetIntegerValueField(event: EventRef, field: CGEventField, value: i64) void;
pub extern fn CGEventSetDoubleValueField(event: EventRef, field: CGEventField, value: f64) void;
pub extern fn CGEventPost(tap: TapLocation, event: EventRef) void;
/// Create an event source bound to a state (we use HID-system state so the
/// gesture looks like it originated from the kernel HID path).
pub extern fn CGEventSourceCreate(stateID: CGEventSourceStateID) ?*anyopaque;

const kCGSEventTypeField: CGEventField = 55;
const kCGEventGestureHIDType: CGEventField = 110;
const kCGEventGestureSwipeMotion: CGEventField = 123;
const kCGEventGestureSwipeProgress: CGEventField = 124;
const kCGEventGestureSwipeVelocityX: CGEventField = 129;
const kCGEventGestureSwipeVelocityY: CGEventField = 130;
const kCGEventGesturePhase: CGEventField = 132;
/// Source process id carried by the event. Real trackpad/HID gestures report 0
/// (kernel). Tahoe's gesture recognizer (WindowManager.SpaceSwapSystemGesture,
/// eventSource gated to `.trackpad`) rejects events that look synthetic — RE'd
/// from `SystemGestureBase.handleEvent`. We force this to 0 to fake HID origin.
const kCGEventSourceUnixProcessID: CGEventField = 41;

const kCGSEventDockControl: i64 = 30; // CGSEventType for a dock-control gesture
const kIOHIDEventTypeDockSwipe: i64 = 23; // IOHIDEventType
const kCGGestureMotionHorizontal: i64 = 1;

/// A swipe traverses Mission Control left or right.
pub const SwipeDirection = enum { left, right };

/// Gesture phases. macOS needs all three (began→changed→ended) for the swipe to
/// register; sending only two leaves Mission Control unmoved.
const GesturePhase = enum(i64) { began = 1, changed = 2, ended = 4 };

fn postDockSwipe(phase: GesturePhase, dir: SwipeDirection, velocity: f64) void {
    // The smallest positive subnormal float (C's FLT_TRUE_MIN). Paired with a
    // large velocity this makes the switch instant (no slide animation).
    const tiny: f64 = std.math.floatTrueMin(f32);
    const progress: f64 = if (dir == .right) tiny else -tiny;
    const vel: f64 = if (dir == .right) velocity else -velocity;

    // Build the event from an HID-system source so it carries kernel-ish
    // provenance (see kCGEventSourceUnixProcessID note).
    const src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    defer if (src) |s| c.CFRelease(@ptrCast(s));
    const ev = CGEventCreate(src) orelse return;
    defer c.CFRelease(@ptrCast(ev));
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, @intFromEnum(phase));
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    // Fake kernel/HID provenance: real gestures report source pid 0.
    CGEventSetIntegerValueField(ev, kCGEventSourceUnixProcessID, 0);
    // Post at the HID tap (most upstream), where real gestures enter.
    CGEventPost(kCGHIDEventTap, ev);
}

/// Step one Space in `dir`. On macOS 26/27 the CGEvent dock-swipe (`postDockSwipe`
/// below) is rejected — the recognizer reads the IOHIDEvent backing the event,
/// which a synthetic CGEvent lacks. So we inject a real DockSwipe IOHIDEvent via
/// `iohid` instead. `velocity` is unused on the IOHID path (kept for signature
/// stability); `postDockSwipe` is retained only as documentation of the old way.
pub fn performSwitchGesture(dir: SwipeDirection, velocity: f64) void {
    _ = velocity;
    @import("iohid.zig").dispatchDockSwipe(dir == .right);
}

// ---------------------------------------------------------------------------
// Mission Control keyboard-shortcut emulation (the macOS 26+/Tahoe path)
// ---------------------------------------------------------------------------
//
// Since the dock-swipe gesture above no longer works, we switch Spaces the only
// way that still works without disabling SIP: by synthesizing the system "Move
// left/right a space" shortcut (Control+Arrow), the same symbolic hotkey the
// user could press by hand. Dock.app handles the transition, so the menu bar
// stays correct. Needs the shortcut enabled in System Settings ▸ Keyboard ▸
// Shortcuts ▸ Mission Control (Control+Arrow is on by default).

pub extern fn CGEventCreateKeyboardEvent(source: ?*anyopaque, keycode: u16, keydown: bool) EventRef;
pub extern fn CGEventSetFlags(event: EventRef, flags: u64) void;

// kVK_LeftArrow / kVK_RightArrow (HIToolbox/Events.h).
const kVK_LeftArrow: u16 = 123;
const kVK_RightArrow: u16 = 124;

/// Switch one Space in `dir` by emulating the Control+Arrow Mission Control
/// shortcut. Posted at the HID level so the system hotkey handler sees it.
pub fn performSpaceShortcut(dir: SwipeDirection) void {
    const keycode: u16 = if (dir == .right) kVK_RightArrow else kVK_LeftArrow;
    // Control-only flags. A binding may fire while a Control-containing "hyper"
    // key is physically held; we must not let Alt/Cmd leak into the event or the
    // ^Arrow hotkey won't match (the matcher compares the event's flags).
    const flags = kCGEventFlagMaskControl;

    const down = CGEventCreateKeyboardEvent(null, keycode, true) orelse return;
    defer c.CFRelease(@ptrCast(down));
    CGEventSetFlags(down, flags);
    CGEventPost(kCGHIDEventTap, down);

    const up = CGEventCreateKeyboardEvent(null, keycode, false) orelse return;
    defer c.CFRelease(@ptrCast(up));
    CGEventSetFlags(up, flags);
    CGEventPost(kCGHIDEventTap, up);
}
