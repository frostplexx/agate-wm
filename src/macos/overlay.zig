//! The drag-preview overlay: a borderless, translucent, mouse-transparent
//! NSWindow flashed over the tile a dragged window would land in, driven
//! through the Objective-C runtime (same strategy as `workspace.zig`).
//!
//! One lazily-created window is reused for every preview: `show` moves it and
//! orders it front (without activating us), `hide` orders it out. It floats
//! above normal windows, joins every Space, and is invisible to Mission
//! Control and the window cycle — pure chrome, never managed (the WM's own
//! windows are never tracked: agate isn't a "regular" app, so its pid is
//! never observed, and the window's level excludes it from tree builds).
const objc = @import("objc");
const c = @import("c.zig").c;

pub const Rect = c.CGRect;

var g_window: ?objc.Object = null;

/// AppKit's global coordinates are bottom-left-origin relative to the
/// *primary* screen (`NSScreen.screens[0]`); the WM's rects are top-left AX
/// coordinates. The primary screen's height is the flip constant.
fn primaryScreenHeight() ?f64 {
    const NSScreen = objc.getClass("NSScreen") orelse return null;
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    if (screens.value == null) return null;
    if (screens.msgSend(usize, "count", .{}) == 0) return null;
    const first = screens.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)});
    if (first.value == null) return null;
    return first.msgSend(c.CGRect, "frame", .{}).size.height;
}

fn ensureWindow() ?objc.Object {
    if (g_window) |w| return w;

    // NSApplication must exist before any NSWindow; harmless if already done
    // (the status bar also initializes it).
    const NSApplication = objc.getClass("NSApplication") orelse return null;
    _ = NSApplication.msgSend(objc.Object, "sharedApplication", .{});

    const NSWindow = objc.getClass("NSWindow") orelse return null;
    const allocd = NSWindow.msgSend(objc.Object, "alloc", .{});
    if (allocd.value == null) return null;
    const zero = c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    // styleMask 0 = borderless, backing 2 = buffered.
    const win = allocd.msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
        zero, @as(u64, 0), @as(u64, 2), false,
    });
    if (win.value == null) return null;

    win.msgSend(void, "setOpaque:", .{false});
    win.msgSend(void, "setHasShadow:", .{false});
    win.msgSend(void, "setIgnoresMouseEvents:", .{true});
    // Released only at process exit; one window for the process lifetime.
    win.msgSend(void, "setReleasedWhenClosed:", .{false});
    // 101 = NSPopUpMenuWindowLevel: above every normal window, below screensaver.
    win.msgSend(void, "setLevel:", .{@as(i64, 101)});
    // CanJoinAllSpaces (1<<0) | Transient (1<<3, hidden from Mission Control)
    // | IgnoresCycle (1<<6): chrome, not a window the user can land on.
    win.msgSend(void, "setCollectionBehavior:", .{@as(u64, (1 << 0) | (1 << 3) | (1 << 6))});

    const NSColor = objc.getClass("NSColor") orelse return null;
    const fill = NSColor.msgSend(objc.Object, "colorWithCalibratedRed:green:blue:alpha:", .{
        @as(f64, 0.35), @as(f64, 0.55), @as(f64, 1.0), @as(f64, 0.28),
    });
    win.msgSend(void, "setBackgroundColor:", .{fill});

    // Rounded corners + a stronger border so the target slot reads as a frame.
    const view = win.msgSend(objc.Object, "contentView", .{});
    if (view.value != null) {
        view.msgSend(void, "setWantsLayer:", .{true});
        const layer = view.msgSend(objc.Object, "layer", .{});
        if (layer.value != null) {
            layer.msgSend(void, "setCornerRadius:", .{@as(f64, 9)});
            layer.msgSend(void, "setMasksToBounds:", .{true});
            layer.msgSend(void, "setBorderWidth:", .{@as(f64, 2)});
            const border = NSColor.msgSend(objc.Object, "colorWithCalibratedRed:green:blue:alpha:", .{
                @as(f64, 0.35), @as(f64, 0.55), @as(f64, 1.0), @as(f64, 0.9),
            });
            const cg = border.msgSend(?*anyopaque, "CGColor", .{});
            if (cg != null) layer.msgSend(void, "setBorderColor:", .{cg});
        }
    }

    g_window = win;
    return win;
}

/// Show (or move) the overlay over `rect` — top-left AX/CG coordinates, the
/// same space the tree's window bounds live in.
pub fn show(rect: Rect) void {
    const win = ensureWindow() orelse return;
    const flip_h = primaryScreenHeight() orelse return;
    const ns_rect = c.CGRect{
        .origin = .{ .x = rect.origin.x, .y = flip_h - (rect.origin.y + rect.size.height) },
        .size = rect.size,
    };
    win.msgSend(void, "setFrame:display:", .{ ns_rect, true });
    // Order front without making us the active app (we have no key windows).
    win.msgSend(void, "orderFrontRegardless", .{});
}

pub fn hide() void {
    const win = g_window orelse return;
    win.msgSend(void, "orderOut:", .{@as(?*anyopaque, null)});
}
