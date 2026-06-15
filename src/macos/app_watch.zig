//! Real-time application launch / termination events via AppKit's NSWorkspace
//! notification center — the event-driven replacement for polling
//! `workspace.regularAppPids`.
//!
//! NSWorkspace posts `NSWorkspaceDidLaunchApplicationNotification` the instant an
//! app starts and `NSWorkspaceDidTerminateApplicationNotification` the instant it
//! quits. The termination event is the *only* reliable signal that an app has
//! died: per-window `AXUIElementDestroyed` notifications are not delivered when
//! the owning process exits (the AXObserver dies with it), so without this a
//! cmd-q'd app's windows would linger in the tree until the next poll.
//!
//! Mirrors yabai's `workspace_create_observer` (koekeishiya/yabai,
//! src/workspace.m): a tiny Objective-C observer object registered on
//! `[NSWorkspace sharedWorkspace].notificationCenter`. We have no .m file, so the
//! class is built at runtime through the objc runtime bridge (mitchellh/zig-objc):
//! `allocateClassPair` + `addMethod` + `registerClassPair`.
const objc = @import("objc");

/// What happened to an application. Explicit tag type so it can cross the C ABI
/// (the callback is invoked with the C calling convention).
pub const AppEvent = enum(c_int) { launched, terminated, activated };

/// C-ABI callback invoked on the main run loop when an app launches or quits.
/// `context` is the opaque pointer handed to `start`.
pub const Callback = *const fn (event: AppEvent, pid: i32, context: ?*anyopaque) callconv(.c) void;

// AppKit notification-name / userInfo-key constants (`NSString *`), resolved
// from the linked AppKit framework at link time. The userInfo of both
// notifications carries the affected `NSRunningApplication` under
// `NSWorkspaceApplicationKey`.
extern const NSWorkspaceDidLaunchApplicationNotification: objc.c.id;
extern const NSWorkspaceDidTerminateApplicationNotification: objc.c.id;
/// Posted the instant an app is brought to the front (Cmd-Tab, dock click, or a
/// programmatic activation). Used to follow activation to the window's Space.
extern const NSWorkspaceDidActivateApplicationNotification: objc.c.id;
extern const NSWorkspaceApplicationKey: objc.c.id;

var g_callback: ?Callback = null;
var g_context: ?*anyopaque = null;

/// Begin delivering app launch/terminate events to `callback`. Registers a
/// single observer for the process lifetime (the observer object and its class
/// are intentionally never torn down). Must run on the thread that owns the main
/// run loop, before `CFRunLoopRun`.
pub fn start(callback: Callback, context: ?*anyopaque) void {
    g_callback = callback;
    g_context = context;

    const NSObject = objc.getClass("NSObject") orelse return;
    const cls = objc.allocateClassPair(NSObject, "AgateAppWatch") orelse return;
    _ = cls.addMethod("onAppLaunched:", onAppLaunched);
    _ = cls.addMethod("onAppTerminated:", onAppTerminated);
    _ = cls.addMethod("onAppActivated:", onAppActivated);
    objc.registerClassPair(cls);

    const observer = cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    const NSWorkspace = objc.getClass("NSWorkspace") orelse return;
    const shared = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const center = shared.msgSend(objc.Object, "notificationCenter", .{});

    center.msgSend(void, "addObserver:selector:name:object:", .{
        observer.value,
        objc.sel("onAppLaunched:"),
        NSWorkspaceDidLaunchApplicationNotification,
        @as(objc.c.id, null),
    });
    center.msgSend(void, "addObserver:selector:name:object:", .{
        observer.value,
        objc.sel("onAppTerminated:"),
        NSWorkspaceDidTerminateApplicationNotification,
        @as(objc.c.id, null),
    });
    center.msgSend(void, "addObserver:selector:name:object:", .{
        observer.value,
        objc.sel("onAppActivated:"),
        NSWorkspaceDidActivateApplicationNotification,
        @as(objc.c.id, null),
    });
}

fn onAppLaunched(_: objc.c.id, _: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    dispatch(.launched, notification);
}

fn onAppTerminated(_: objc.c.id, _: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    dispatch(.terminated, notification);
}

fn onAppActivated(_: objc.c.id, _: objc.c.SEL, notification: objc.c.id) callconv(.c) void {
    dispatch(.activated, notification);
}

/// Pull the `NSRunningApplication` out of the notification's userInfo, read its
/// pid, and forward it to the registered callback.
fn dispatch(event: AppEvent, notification: objc.c.id) void {
    const cb = g_callback orelse return;
    const note = objc.Object.fromId(notification);
    const info = note.msgSend(objc.Object, "userInfo", .{});
    if (info.value == null) return;
    const app = info.msgSend(objc.Object, "objectForKey:", .{NSWorkspaceApplicationKey});
    if (app.value == null) return;
    const pid = app.msgSend(i32, "processIdentifier", .{});
    if (pid > 0) cb(event, pid, g_context);
}
