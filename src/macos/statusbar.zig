//! Menu-bar Space indicator: an `NSStatusItem` whose title is the active
//! Space's user index, driven through the Objective-C runtime (same strategy
//! as `workspace.zig`).
//!
//! agate is a daemon, but a status item makes it an AppKit event *consumer*:
//! clicks on the item are delivered as NSEvents to our process. Merely
//! initializing `NSApplication` is not enough — without the `run` loop AppKit's
//! event dispatch never finishes launching, and the first click dies in an
//! uncaught NSException (this crashed the WM). So when the indicator is
//! enabled, the process must block on `runApp` ([NSApp run]) instead of
//! `CFRunLoopRun`; NSApp's loop pumps the same main CFRunLoop, so every event
//! tap, timer, observer and notification source keeps firing exactly as
//! before. The item also gets a real menu (Quit), so a click has well-defined
//! behavior instead of a nil-action dispatch.
//!
//! The activation policy is set to *accessory* so none of this puts an empty
//! app in the Dock or Cmd-Tab.
const std = @import("std");
const objc = @import("objc");

var g_item: ?objc.Object = null;

fn nsString(text: [:0]const u8) ?objc.Object {
    const NSString = objc.getClass("NSString") orelse return null;
    const str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text.ptr});
    if (str.value == null) return null;
    return str;
}

/// Create the status item (call once, main thread, before the run loop).
/// Returns false if AppKit refuses (no window-server session).
pub fn init() bool {
    if (g_item != null) return true;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSApplication = objc.getClass("NSApplication") orelse return false;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == null) return false;
    // 1 = NSApplicationActivationPolicyAccessory: status item, no Dock icon.
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 1)});

    const NSStatusBar = objc.getClass("NSStatusBar") orelse return false;
    const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
    if (bar.value == null) return false;
    // -1.0 = NSVariableStatusItemLength.
    const item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)});
    if (item.value == null) return false;
    // The status bar hands out an autoreleased item and *removes* it when it
    // deallocates — retain it for the process lifetime.
    _ = item.msgSend(objc.Object, "retain", .{});

    // A menu makes the click path safe and useful: AppKit's menu tracking owns
    // the whole interaction (no action/responder dispatch to crash in), and
    // the WM gains a Quit affordance. `terminate:` with a nil target resolves
    // to NSApp.
    if (objc.getClass("NSMenu")) |NSMenu| menu: {
        const menu = NSMenu.msgSend(objc.Object, "new", .{});
        if (menu.value == null) break :menu;
        const NSMenuItem = objc.getClass("NSMenuItem") orelse break :menu;
        const title = nsString("Quit agate") orelse break :menu;
        const empty = nsString("") orelse break :menu;
        const mi_alloc = NSMenuItem.msgSend(objc.Object, "alloc", .{});
        const mi = mi_alloc.msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            title, objc.sel("terminate:"), empty,
        });
        if (mi.value == null) break :menu;
        menu.msgSend(void, "addItem:", .{mi});
        mi.msgSend(void, "release", .{});
        item.msgSend(void, "setMenu:", .{menu});
        menu.msgSend(void, "release", .{}); // the item retains it
    }

    g_item = item;
    return true;
}

/// Whether the status item exists — i.e. whether the process must use
/// `runApp` instead of `CFRunLoopRun` for its main loop.
pub fn active() bool {
    return g_item != null;
}

/// Block on AppKit's main event loop ([NSApp run]). Pumps the same main
/// CFRunLoop as CFRunLoopRun, plus full NSEvent dispatch for the status item.
pub fn runApp() void {
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == null) return;
    app.msgSend(void, "run", .{});
}

/// Set the indicator text (e.g. the space number). No-op before `init`.
pub fn setText(text: [:0]const u8) void {
    const item = g_item orelse return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const button = item.msgSend(objc.Object, "button", .{});
    if (button.value == null) return;
    const str = nsString(text) orelse return;
    button.msgSend(void, "setTitle:", .{str});
}

/// Show the 1-based space index, or a placeholder when it isn't a user space
/// (native fullscreen) / can't be resolved.
pub fn setSpaceNumber(n: ?usize) void {
    var buf: [16]u8 = undefined;
    const text: [:0]const u8 = if (n) |num|
        std.fmt.bufPrintSentinel(&buf, "{d}", .{num}, 0) catch "?"
    else
        "–";
    setText(text);
}
