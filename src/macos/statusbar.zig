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

// macOS-specific: get the absolute path of the running executable.
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
// POSIX exec: replace the (child) process image with a fresh agate.
extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
// `fork`/`setenv` aren't surfaced by Zig 0.16's std; `setsid`/`_exit` come from std.c.
extern "c" fn fork() std.c.pid_t;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

var g_item: ?objc.Object = null;
var g_handler: ?objc.Object = null;

/// Restart agate as a **new process**, never in place. WindowServer tracks the
/// status item per CGS connection, and that connection is bound to our PID; an
/// in-place `execv` keeps the PID, so the new image's status item collides with
/// the still-registered old one and renders blank/dead. Coming back as a fresh
/// PID gives a clean connection: the old one dies with this process and the
/// menu-bar slot is reclaimed.
///
/// launchd-managed (KeepAlive): just exit — launchd relaunches as a new PID.
/// Manually started: fork+exec a detached fresh instance, then exit. The child
/// carries `AGATE_RESTART=1` so its startup waits briefly for our single-instance
/// lock to drop on exit (see `main`). All env/path work happens in the parent
/// before `fork`, since only async-signal-safe calls are legal in the child.
fn restartAgateImp(_: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    // Remove the status item up front so the menu-bar slot disappears immediately
    // rather than lingering until the process actually exits.
    if (g_item) |old| {
        if (objc.getClass("NSStatusBar")) |NSStatusBar| {
            const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
            if (bar.value != null) bar.msgSend(void, "removeStatusItem:", .{old});
        }
        old.msgSend(void, "release", .{});
        g_item = null;
    }

    // launchd owns our lifecycle: exit and let KeepAlive bring back a new PID.
    if (std.c.getenv("XPC_SERVICE_NAME") != null) std.process.exit(0);

    // Manual start: spawn a detached copy of ourselves, then exit.
    var buf: [4096]u8 = undefined;
    var size: u32 = 4096;
    if (_NSGetExecutablePath(&buf, &size) == 0) {
        const path: [*:0]u8 = @ptrCast(&buf);
        const argv = [2]?[*:0]const u8{ path, null };
        // Set in the parent (before fork) so the child inherits it; setenv is not
        // async-signal-safe and must not run between fork and execv.
        _ = setenv("AGATE_RESTART", "1", 1);
        if (fork() == 0) {
            _ = std.c.setsid(); // detach from our session; reparents to launchd on our exit
            _ = execv(path, &argv);
            std.c._exit(127); // execv only returns on failure
        }
    }
    // Parent (or path-resolution failure): exit so the lock and CGS connection drop.
    std.process.exit(0);
}

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

    // Register the AgateMenuHandler class once (idempotent: allocateClassPair
    // returns null if the name is already taken, which is fine on re-init).
    if (g_handler == null) {
        const NSObject = objc.getClass("NSObject") orelse return false;
        if (objc.allocateClassPair(NSObject, "AgateMenuHandler")) |cls| {
            _ = cls.addMethod("restartAgate:", restartAgateImp);
            objc.registerClassPair(cls);
            const h = cls.msgSend(objc.Object, "new", .{});
            if (h.value != null) {
                _ = h.msgSend(objc.Object, "retain", .{});
                g_handler = h;
            }
        }
    }

    // A menu makes the click path safe and useful: AppKit's menu tracking owns
    // the whole interaction (no action/responder dispatch to crash in).
    if (objc.getClass("NSMenu")) |NSMenu| menu: {
        const menu = NSMenu.msgSend(objc.Object, "new", .{});
        if (menu.value == null) break :menu;
        const NSMenuItem = objc.getClass("NSMenuItem") orelse break :menu;
        const empty = nsString("") orelse break :menu;

        // "Restart agate" — re-execs the binary in place; works with or without launchd.
        if (g_handler) |handler| {
            const r_title = nsString("Restart agate") orelse break :menu;
            const r_alloc = NSMenuItem.msgSend(objc.Object, "alloc", .{});
            const r_mi = r_alloc.msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                r_title, objc.sel("restartAgate:"), empty,
            });
            if (r_mi.value != null) {
                r_mi.msgSend(void, "setTarget:", .{handler});
                menu.msgSend(void, "addItem:", .{r_mi});
                r_mi.msgSend(void, "release", .{});
            }
            menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{})});
        }

        // "Quit agate" — terminate: resolves to NSApp via the responder chain.
        const q_title = nsString("Quit agate") orelse break :menu;
        const q_alloc = NSMenuItem.msgSend(objc.Object, "alloc", .{});
        const q_mi = q_alloc.msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            q_title, objc.sel("terminate:"), empty,
        });
        if (q_mi.value == null) break :menu;
        menu.msgSend(void, "addItem:", .{q_mi});
        q_mi.msgSend(void, "release", .{});
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
/// Uses a monospace font so digit widths are consistent across spaces.
pub fn setText(text: [:0]const u8) void {
    const item = g_item orelse return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const button = item.msgSend(objc.Object, "button", .{});
    if (button.value == null) return;
    const str = nsString(text) orelse return;

    styled: {
        const NSFont = objc.getClass("NSFont") orelse break :styled;
        const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse break :styled;
        const NSAttributedString = objc.getClass("NSAttributedString") orelse break :styled;
        const font_key = nsString("NSFont") orelse break :styled;

        // Match the menu-bar font size, but use the system monospace face.
        const ref_font = NSFont.msgSend(objc.Object, "menuBarFontOfSize:", .{@as(f64, 0)});
        const pt_size = if (ref_font.value != null) ref_font.msgSend(f64, "pointSize", .{}) else @as(f64, 14.0);
        const font = NSFont.msgSend(objc.Object, "monospacedSystemFontOfSize:weight:", .{ pt_size, @as(f64, 0) });
        if (font.value == null) break :styled;

        const attrs = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
        if (attrs.value == null) break :styled;
        attrs.msgSend(void, "setObject:forKey:", .{ font, font_key });

        const as_alloc = NSAttributedString.msgSend(objc.Object, "alloc", .{});
        if (as_alloc.value == null) break :styled;
        const as = as_alloc.msgSend(objc.Object, "initWithString:attributes:", .{ str, attrs });
        if (as.value == null) { as_alloc.msgSend(void, "release", .{}); break :styled; }
        defer as.msgSend(void, "release", .{});

        button.msgSend(void, "setAttributedTitle:", .{as});
        return;
    }
    // Fallback: plain title without font styling.
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
