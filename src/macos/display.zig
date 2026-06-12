//! Display geometry via AppKit's `NSScreen` (through the Objective-C runtime).
//! The window-server / AX coordinate space is top-left origin, but AppKit is
//! bottom-left, so the visible frame is flipped here before it's handed out.
const c = @import("c.zig").c;
const objc = @import("objc");

pub const Rect = c.CGRect;

/// The usable frame of the main display in top-left (AX/CG) coordinates —
/// `NSScreen.visibleFrame`, which already excludes the menu bar and the Dock,
/// flipped from AppKit's bottom-left origin. Null if AppKit is unavailable.
pub fn mainVisibleFrame() ?Rect {
    const NSScreen = objc.getClass("NSScreen") orelse return null;
    const screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (screen.value == null) return null;

    const full = screen.msgSend(c.CGRect, "frame", .{});
    const vis = screen.msgSend(c.CGRect, "visibleFrame", .{});
    return .{
        .origin = .{
            .x = vis.origin.x,
            // Flip: AppKit measures y from the bottom of the primary screen.
            .y = full.size.height - (vis.origin.y + vis.size.height),
        },
        .size = vis.size,
    };
}

// --- Small-screen detection -------------------------------------------------

extern fn CGMainDisplayID() u32;
extern fn CGDisplayIsBuiltin(display: u32) i32;
extern fn CGGetActiveDisplayList(maxDisplays: u32, activeDisplays: ?[*]u32, displayCount: *u32) i32;

/// Whether the built-in panel is the *only* active display — the actual
/// "working on the MacBook screen" situation Small Screen Mode is for.
///
/// Deliberately NOT "is the main display built-in": `CGMainDisplayID` is the
/// arrangement-primary display, which often stays the built-in panel while the
/// user works on an external monitor beside it — keying on it put every
/// workspace into the accordion on a big screen. With one display there is no
/// ambiguity.
pub fn builtinIsOnlyDisplay() bool {
    var count: u32 = 0;
    if (CGGetActiveDisplayList(0, null, &count) != 0) return false;
    if (count != 1) return false;
    return CGDisplayIsBuiltin(CGMainDisplayID()) != 0;
}

// --- Display reconfiguration (clamshell, dock/undock, resolution change) ---
//
// CoreGraphics posts a reconfiguration callback whenever the display layout
// changes: a display is added/removed (lid close in clamshell, plugging in an
// external monitor), the main display moves, or a mode (resolution) changes.
// The visible frame the WM tiles to changes with it, but no window event fires,
// so without this hook the layout would keep using the *old* screen geometry
// until the next create/destroy/drag. See `<CoreGraphics/CGDisplayConfiguration.h>`.

pub const CGDirectDisplayID = u32;
pub const CGDisplayChangeSummaryFlags = u32;

/// Fired *before* the configuration changes — the new geometry is not valid yet,
/// so callers should ignore this pass and act on the settled (no-begin) pass.
pub const kCGDisplayBeginConfigurationFlag: CGDisplayChangeSummaryFlags = 1 << 0;

pub const CGDisplayReconfigurationCallBack = *const fn (
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: ?*anyopaque,
) callconv(.c) void;

/// Register `callback` for display-layout changes. Returns a `CGError` (0 =
/// success). The callback fires once per affected display, in two passes (a
/// "begin" pass with `kCGDisplayBeginConfigurationFlag`, then a settled pass).
pub extern fn CGDisplayRegisterReconfigurationCallback(
    callback: CGDisplayReconfigurationCallBack,
    userInfo: ?*anyopaque,
) i32;
