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

pub extern fn AXValueCreate(theType: ValueType, valuePtr: *const anyopaque) AXValueRef;
pub extern fn AXValueGetValue(value: AXValueRef, theType: ValueType, valuePtr: *anyopaque) Boolean;
