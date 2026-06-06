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
