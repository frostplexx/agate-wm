//! Accessibility observers that keep the tree in sync with windows appearing
//! and disappearing. Scope (for now): window *create* and *destroy* only.
//!
//! Model mirrors yabai (koekeishiya/yabai, src/application.c `application_observe`
//! and src/event_loop.c): one `AXObserver` per application, added to the main
//! run loop. yabai observes every launched app (via the process manager); we
//! likewise observe every running regular app (`workspace.regularAppPids`) so a
//! new window of a previously window-less app still fires. The per-window
//! destroy registration with the window id smuggled through `refcon` is our own
//! simplification of yabai's window-observation bookkeeping.
//!   * `AXWindowCreated` is registered on the application element — when the app
//!     opens a window we reconcile the active workspace and start observing the
//!     new window.
//!   * `AXUIElementDestroyed` is registered per *window* element, with the
//!     window id smuggled through the `refcon` pointer, so a destroy event tells
//!     us exactly which leaf to drop without touching the (now dead) element.
const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");
const tree = @import("tree.zig");
const window = @import("window.zig");
const state = @import("../state.zig");

const ax = macos.ax;
const c = macos.c;
const foundation = macos.foundation;

const Entry = struct {
    observer: ax.AXObserverRef,
    /// Retained app element — must stay alive while the observer is registered.
    app: *macos.Element,
};

const Manager = struct {
    appState: *state.AppState,
    /// pid -> its observer. Lives for the whole process (arena-allocated).
    entries: std.AutoHashMap(i32, Entry),
};

/// The single WM instance, reached from the C observer callback.
var g_manager: ?*Manager = null;

/// Set up create/destroy observers for every app that currently owns a managed
/// window, then run the loop. Blocks until the run loop stops.
pub fn run(appState: *state.AppState) !void {
    const mgr = try appState.arena.create(Manager);
    mgr.* = .{
        .appState = appState,
        .entries = std.AutoHashMap(i32, Entry).init(appState.arena),
    };
    g_manager = mgr;

    // Observe window creation on every running app — not just those that
    // already own a window — so opening the first window of an otherwise
    // window-less app (Finder, a backgrounded app, …) still fires.
    if (macos.workspace.regularAppPids(appState.gpa)) |pids| {
        defer appState.gpa.free(pids);
        for (pids) |pid| _ = ensureAppObserver(mgr, pid) catch continue;
    } else |_| {}

    // Observe destruction of each window already in the tree.
    if (appState.tree) |root| observeWindows(mgr, root);

    c.CFRunLoopRun();
}

/// Walk the tree and ensure every leaf window's app is observed for creates and
/// that the window itself is observed for destruction.
fn observeWindows(mgr: *Manager, con: *data.Con) void {
    if (con.con_type == .Container) {
        if (con.window) |*w| {
            if (ensureAppObserver(mgr, w.pid)) |entry| {
                if (window.resolveElement(w)) |el| addDestroyNotification(entry.observer, el, w.id);
            } else |_| {}
        }
    }
    var it = con.children.first;
    while (it) |n| : (it = n.next) observeWindows(mgr, data.Con.fromNode(n));
}

/// Get (creating if needed) the observer for `pid`, registered for window
/// creation and wired into the run loop.
fn ensureAppObserver(mgr: *Manager, pid: i32) !Entry {
    if (mgr.entries.get(pid)) |e| return e;

    var observer: ax.AXObserverRef = null;
    if (ax.AXObserverCreate(pid, axCallback, &observer) != ax.kAXErrorSuccess) return error.ObserverCreate;
    const app = macos.Element.createApplication(pid) orelse return error.AppElement;

    // Nudge Chromium/Electron/Firefox-based apps to publish their AX tree so
    // they emit window notifications too.
    app.enableManualAccessibility();
    addCreateNotification(observer, app);
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), ax.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);

    const entry = Entry{ .observer = observer, .app = app };
    try mgr.entries.put(pid, entry);
    return entry;
}

fn addCreateNotification(observer: ax.AXObserverRef, app: *macos.Element) void {
    const name = foundation.String.createUtf8("AXWindowCreated") catch return;
    defer name.release();
    _ = ax.AXObserverAddNotification(observer, app.ref(), name.ref(), null);
}

fn addDestroyNotification(observer: ax.AXObserverRef, el: *macos.Element, wid: u32) void {
    const name = foundation.String.createUtf8("AXUIElementDestroyed") catch return;
    defer name.release();
    // Smuggle the window id through refcon so the destroy callback knows which
    // leaf to remove without querying the dead element.
    _ = ax.AXObserverAddNotification(observer, el.ref(), name.ref(), @ptrFromInt(@as(usize, wid)));
}

/// The C callback for every observed notification. Dispatches on the name.
fn axCallback(
    observer: ax.AXObserverRef,
    element: ax.AXUIElementRef,
    notification: c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void {
    const mgr = g_manager orelse return;
    const s = foundation.String.fromRef(@ptrCast(notification)) orelse return;
    var buf: [64]u8 = undefined;
    const name = s.cstring(&buf) orelse return;

    if (std.mem.eql(u8, name, "AXWindowCreated")) {
        onWindowCreated(mgr, observer, element);
    } else if (std.mem.eql(u8, name, "AXUIElementDestroyed")) {
        if (refcon) |r| onWindowDestroyed(mgr, @intCast(@intFromPtr(r)));
    }
}

/// A window appeared. The created window's AX element is handed to us directly,
/// and we build the Window from it (id/pid/frame via Accessibility) — the window
/// server has not registered it with CoreGraphics/SkyLight yet, so a CG/SLS
/// lookup races and fails. This is what yabai does in `window_create`
/// (src/window.c): never touch CGWindowList for a freshly-created window.
fn onWindowCreated(mgr: *Manager, observer: ax.AXObserverRef, element: ax.AXUIElementRef) void {
    const app = mgr.appState;
    const el = macos.Element.fromRef(element) orelse return;
    const wid = el.windowId() orelse return; // non-window elements have no id
    if (tree.hasWindow(app.tree orelse return, wid)) return;

    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(app.tree.?, sid) orelse return;

    const pid = el.pid() orelse return;
    var namebuf: [256]u8 = undefined;
    const name = macos.workspace.appName(pid, &namebuf) orelse "";
    const owner = app.arena.dupe(u8, name) catch return; // must outlive the event

    const win = window.fromElement(el, owner) orelse return;
    const leaf = tree.addLeaf(app.arena, ws, win) catch return;
    std.debug.print("[observer] +window #{d} {s}\n", .{ win.id, win.owner });

    // `fromElement` already cached the AX element, so this just returns it.
    if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, wid);
    tree.flushActive(app);
}

/// A window was destroyed. Drop its leaf and re-flush.
fn onWindowDestroyed(mgr: *Manager, wid: u32) void {
    const app = mgr.appState;
    if (tree.removeWindow(app.tree orelse return, wid)) {
        std.debug.print("[observer] -window #{d}\n", .{wid});
        tree.flushActive(app);
    }
}
