//! Hand-written `extern` declarations for the macOS Accessibility (AX) C API.
//!
//! These would normally come from `<ApplicationServices/...>` via `@cImport`,
//! but those headers drag in the Carbon-era CoreServices umbrella which
//! translate-c can't process against the SDK's nested sub-frameworks (see
//! `c.zig`). The AX API is tiny and ABI-stable, so we declare exactly the
//! pieces agate needs here. The symbols are exported by the ApplicationServices
//! framework, which the build links — so these resolve at link time.
//!
//! CoreFoundation / CoreGraphics types are reused from the working `@cImport`.
const c = @import("c.zig").c;

/// Opaque CoreFoundation-style handles.
pub const AXUIElementRef = ?*const opaque {};
pub const AXValueRef = ?*const opaque {};

/// `AXError`; only success is needed by name. Non-zero is a failure.
pub const Error = c_int;
pub const kAXErrorSuccess: Error = 0;

/// `AXValueType` (from AXValueConstants.h).
pub const ValueType = enum(u32) {
    illegal = 0,
    cg_point = 1,
    cg_size = 2,
    cg_rect = 3,
    cf_range = 4,
    ax_error = 5,
};

// Apple's `Boolean` is `unsigned char`.
pub const Boolean = u8;

/// Key for the options dict passed to `AXIsProcessTrustedWithOptions` — an
/// exported `CFStringRef`, so we can reference it directly (unlike the
/// `CFSTR(...)`-macro attribute constants).
pub extern const kAXTrustedCheckOptionPrompt: c.CFStringRef;

pub extern fn AXIsProcessTrusted() Boolean;
pub extern fn AXIsProcessTrustedWithOptions(options: c.CFDictionaryRef) Boolean;

pub extern fn AXUIElementCreateApplication(pid: c.pid_t) AXUIElementRef;
pub extern fn AXUIElementCreateSystemWide() AXUIElementRef;
pub extern fn AXUIElementCopyAttributeValue(
    element: AXUIElementRef,
    attribute: c.CFStringRef,
    value: *c.CFTypeRef,
) Error;
pub extern fn AXUIElementSetAttributeValue(
    element: AXUIElementRef,
    attribute: c.CFStringRef,
    value: c.CFTypeRef,
) Error;
/// Perform a named action on an element (e.g. "AXRaise" to bring a window to the
/// front within its application). Used by the focus engine.
pub extern fn AXUIElementPerformAction(element: AXUIElementRef, action: c.CFStringRef) Error;

pub extern fn AXValueCreate(theType: ValueType, valuePtr: *const anyopaque) AXValueRef;
pub extern fn AXValueGetValue(value: AXValueRef, theType: ValueType, valuePtr: *anyopaque) Boolean;

/// The pid that owns an AXUIElement.
pub extern fn AXUIElementGetPid(element: AXUIElementRef, pid: *c.pid_t) Error;

// --- Observers (AX notifications) ------------------------------------------
// The per-application observer model (one AXObserver per app, added to the run
// loop) follows yabai's `application_observe` (koekeishiya/yabai, src/application.c).

pub const AXObserverRef = ?*const opaque {};

/// C callback invoked on the run loop when a registered notification fires.
/// `notification` is a CFString (e.g. "AXWindowCreated"); `refcon` is the
/// opaque value passed to `AXObserverAddNotification`.
pub const ObserverCallback = *const fn (
    observer: AXObserverRef,
    element: AXUIElementRef,
    notification: c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void;

pub extern fn AXObserverCreate(application: c.pid_t, callback: ObserverCallback, out: *AXObserverRef) Error;
pub extern fn AXObserverAddNotification(observer: AXObserverRef, element: AXUIElementRef, notification: c.CFStringRef, refcon: ?*anyopaque) Error;
pub extern fn AXObserverRemoveNotification(observer: AXObserverRef, element: AXUIElementRef, notification: c.CFStringRef) Error;
/// The run-loop source that delivers this observer's callbacks. Add it to a
/// run loop with `CFRunLoopAddSource`.
pub extern fn AXObserverGetRunLoopSource(observer: AXObserverRef) c.CFRunLoopSourceRef;

/// Private SPI: resolve the CGWindowID for a window AXUIElement. Same call
/// yabai uses for `ax_window_id` (koekeishiya/yabai, src/window.c).
pub extern fn _AXUIElementGetWindow(element: AXUIElementRef, wid: *u32) Error;

/// Private SPI: fabricate an AXUIElement from a "remote token" (a 20-byte blob
/// of {pid, magic, element_id}). This is how a window's AX element can be
/// reached even when its Space has never been active and so it's absent from
/// the app's `AXWindows` list. Technique from yabai
/// (koekeishiya/yabai, src/window_manager.c) — see `windowForIdViaRemoteToken`.
pub extern fn _AXUIElementCreateWithRemoteToken(data: c.CFDataRef) AXUIElementRef;
