//! Accessibility observers that keep the tree in sync with the windows on
//! screen. Scope: window create, destroy, move, and resize.
//!
//! Model mirrors yabai (koekeishiya/yabai, src/application.c `application_observe`
//! and src/event_loop.c): one `AXObserver` per application, added to the main
//! run loop. yabai observes every launched app (via the process manager); we
//! likewise observe every running regular app (`workspace.regularAppPids`) so a
//! new window of a previously window-less app still fires.
//!   * `AXWindowCreated` is registered on the *application* element; the event
//!     hands us the new window element.
//!   * `AXUIElementDestroyed` is registered per *window* element, with the
//!     window id smuggled through the `refcon` pointer, so a destroy event tells
//!     us exactly which leaf to drop without touching the (now dead) element.
//!
//! Drags (move/resize) are driven by a CoreGraphics mouse event tap, the way
//! yabai does it (koekeishiya/yabai, src/mouse_handler.c) — not by AX
//! move/resize notifications. `LeftMouseDragged` marks that a drag happened; on
//! `LeftMouseUp` we scan the active workspace for the window whose real frame no
//! longer matches the tree, classify it as resize or move (yabai's
//! `mouse_window_info_populate` field-change test), let it influence the tree
//! (`tree.applyManualResize` rewrites ratios; `tree.applyManualMove` swaps
//! slots), and re-flush once. Nothing moves mid-drag, and a disabled tap is
//! re-enabled from the callback.
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
    /// The mouse event-tap handle (kept so we can re-enable it if disabled).
    tap: macos.event_tap.MachPortRef = null,
    /// Whether the mouse actually moved since mouse-down (a drag, not a click).
    dragging: bool = false,
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

    // A listen-only tap on left mouse down/dragged/up, so window drags are
    // applied when the user releases the mouse (see `mouseTap`). Needs
    // Accessibility (which we already have) / Input Monitoring permission.
    const mask = macos.event_tap.mask(macos.event_tap.kCGEventLeftMouseDown) |
        macos.event_tap.mask(macos.event_tap.kCGEventLeftMouseDragged) |
        macos.event_tap.mask(macos.event_tap.kCGEventLeftMouseUp);
    mgr.tap = macos.event_tap.CGEventTapCreate(
        macos.event_tap.kCGSessionEventTap,
        macos.event_tap.kCGHeadInsertEventTap,
        macos.event_tap.kCGEventTapOptionListenOnly,
        mask,
        mouseTap,
        null,
    );
    if (mgr.tap) |tap| {
        const src = macos.event_tap.CFMachPortCreateRunLoopSource(null, tap, 0);
        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        macos.event_tap.CGEventTapEnable(tap, true);
    } else {
        std.debug.print("[observer] mouse event tap unavailable; drag reflow disabled\n", .{});
    }

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
    addAppNotification(observer, app, "AXWindowCreated");
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), ax.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);

    const entry = Entry{ .observer = observer, .app = app };
    try mgr.entries.put(pid, entry);
    return entry;
}

/// Register an application-level notification (the callback receives the
/// affected window element). `refcon` is null for these.
fn addAppNotification(observer: ax.AXObserverRef, app: *macos.Element, name_str: []const u8) void {
    const name = foundation.String.createUtf8(name_str) catch return;
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

/// Listen-only mouse tap (the drag driver). Mirrors yabai's `mouse_handler`
/// (src/mouse_handler.c): re-enable on disable, grab the window on down, note
/// the drag, and apply it on up.
fn mouseTap(
    proxy: macos.event_tap.EventTapProxy,
    etype: macos.event_tap.EventType,
    event: macos.event_tap.EventRef,
    info: ?*anyopaque,
) callconv(.c) macos.event_tap.EventRef {
    _ = proxy;
    _ = info;
    const mgr = g_manager orelse return event;
    switch (etype) {
        // The system disables the tap if it stalls; turn it back on.
        macos.event_tap.kCGEventTapDisabledByTimeout,
        macos.event_tap.kCGEventTapDisabledByUserInput,
        => if (mgr.tap) |t| macos.event_tap.CGEventTapEnable(t, true),
        macos.event_tap.kCGEventLeftMouseDown => mgr.dragging = false,
        macos.event_tap.kCGEventLeftMouseDragged => mgr.dragging = true,
        macos.event_tap.kCGEventLeftMouseUp => onMouseUp(mgr),
        else => {},
    }
    return event; // listen-only: pass the event through unchanged
}

/// A drag ended. Find which managed window on the active Space actually changed
/// (its real frame no longer matches what the tree last set), classify it as a
/// resize or a move, let it influence the tree, and re-flush once. Scanning for
/// the changed window — rather than hit-testing the cursor at mouse-down — avoids
/// grabbing the wrong window when the press lands on a shared edge or in a gap.
fn onMouseUp(mgr: *Manager) void {
    if (!mgr.dragging) return; // a plain click, not a drag
    mgr.dragging = false;

    const app = mgr.appState;
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(app.tree orelse return, sid) orelse return;
    const eps: f64 = 2;

    var moved: ?*data.Con = null;
    var moved_frame: macos.window_list.Rect = undefined;

    var it = ws.children.first;
    while (it) |n| : (it = n.next) {
        const leaf = data.Con.fromNode(n);
        const win = if (leaf.window) |*w| w else continue;
        const el = window.resolveElement(win) orelse continue;
        const pos = el.position() orelse continue;
        const sz = el.size() orelse continue;
        const final = macos.window_list.Rect{ .origin = pos, .size = sz };

        const size_changed = @abs(sz.width - win.bounds.size.width) > eps or
            @abs(sz.height - win.bounds.size.height) > eps;
        const pos_changed = @abs(pos.x - win.bounds.origin.x) > eps or
            @abs(pos.y - win.bounds.origin.y) > eps;

        if (size_changed) {
            // Resize wins over a move (a leading-edge resize changes both).
            _ = tree.applyManualResize(leaf, final);
            tree.flushActive(app);
            return;
        }
        if (pos_changed and moved == null) {
            moved = leaf;
            moved_frame = final;
        }
    }

    if (moved) |leaf| {
        _ = tree.applyManualMove(leaf, moved_frame);
        tree.flushActive(app);
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

    // Native macOS tab: a new window created at the exact frame of an existing
    // window of the same app is a tab joining that group (AppKit gives a tab
    // group one shared frame). Replace the group's leaf with the new front tab
    // instead of adding a second tile — the window server has no tab concept, so
    // this frame-identity test is how we collapse a tab group to one window.
    if (tree.findTabSibling(ws, win.pid, win.bounds)) |leaf| {
        leaf.window.?.deinit();
        leaf.window = win;
        leaf.id = win.id;
        if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, wid);
        tree.flushActive(app);
        return;
    }

    std.debug.print("[observer] +window #{d} {s}\n", .{ win.id, win.owner });
    const leaf = tree.addLeaf(app.arena, ws, win) catch return;

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
