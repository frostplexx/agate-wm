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
const focus = @import("focus/focus.zig");
const gestures = @import("gestures.zig");
const state = @import("../state.zig");
const lua_config = @import("../config/lua.zig");

const ax = macos.ax;
const c = macos.c;
const foundation = macos.foundation;

const Entry = struct {
    observer: ax.AXObserverRef,
    /// Retained app element — must stay alive while the observer is registered.
    app: *macos.Element,
};

/// Context for a grace-period tab-repair timer. Heap-allocated on the gpa;
/// freed inside `graceTimerFired`. Carries everything needed to retry the
/// surviving-sibling lookup without touching the (dead) destroyed element.
const GraceContext = struct {
    mgr: *Manager,
    observer: ax.AXObserverRef,
    wid: u32,
    pid: i32,
    frame: macos.window_list.Rect,
};

/// CFRunLoopTimer callback: fires ~0.3 s after a tabbed window's AX element was
/// destroyed and the immediate re-pair (`repairTabLeaf`) found no sibling yet.
/// A previously-background tab can take a moment to surface in the app's
/// `AXWindows` list; retry the re-pair now. If it still fails, the group really
/// is gone — drop the leaf and re-flush.
fn graceTimerFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *GraceContext = @ptrCast(@alignCast(info orelse return));
    const mgr = ctx.mgr;
    defer mgr.appState.gpa.destroy(ctx);
    const root = mgr.appState.tree orelse return;
    const leaf = tree.findLeaf(root, ctx.wid) orelse return; // already removed/re-paired

    if (repairTabLeaf(ctx.observer, root, leaf, ctx.pid, ctx.frame, ctx.wid)) {
        tree.flushActive(mgr.appState);
        return;
    }
    const ws = leaf.parent;
    const idx = childIndex(ws, leaf);
    if (tree.removeWindow(root, ctx.wid)) {
        std.debug.print("[observer] -window #{d} (tab grace expired)\n", .{ctx.wid});
        tree.flushActive(mgr.appState);
        if (ws) |w| focus.focusAfterClose(w, ctx.pid, idx);
    }
}

/// The index of `child` within `parent`'s children slice (0 if absent / no
/// parent). Captured before removal so the focus engine knows which slot — and
/// therefore which left neighbour — a closed window vacated.
fn childIndex(parent: ?*data.Con, child: *data.Con) usize {
    const p = parent orelse return 0;
    return tree.childIndexOf(p, child) orelse 0;
}

/// Schedule a one-shot CFRunLoopTimer on the current run loop, firing `delay`
/// seconds from now in `mode`, passing `info` to `cb`. Returns false if the
/// timer couldn't be created — the caller still owns `info` and must free it.
/// Replaces the CFRunLoopTimerContext boilerplate every deferred action needs.
fn scheduleOneShot(delay: f64, mode: c.CFStringRef, info: ?*anyopaque, cb: c.CFRunLoopTimerCallBack) bool {
    var timer_ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = info,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const timer = c.CFRunLoopTimerCreate(null, c.CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0, cb, &timer_ctx) orelse return false;
    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, mode);
    c.CFRelease(timer);
    return true;
}

const Manager = struct {
    appState: *state.AppState,
    /// pid -> its observer. Lives for the whole process (arena-allocated).
    entries: std.AutoHashMap(i32, Entry),
    /// The mouse event-tap handle (kept so we can re-enable it if disabled).
    tap: macos.event_tap.MachPortRef = null,
    /// The keyboard event-tap handle. Kept for the same reason: an intercepting
    /// tap is disabled by the system whenever its callback runs too long, and the
    /// callback must re-enable *itself* — re-enabling the mouse tap here (the old
    /// bug) left keybindings permanently dead after the first slow action.
    ktap: macos.event_tap.MachPortRef = null,
    /// The scroll-wheel event-tap handle (kept to re-enable it if disabled). An
    /// intercepting tap that swallows scroll while a trackpad gesture is live, so
    /// the window under the swipe doesn't also scroll (see `scrollTap`).
    stap: macos.event_tap.MachPortRef = null,
    /// Whether the mouse actually moved since mouse-down (a drag, not a click).
    dragging: bool = false,
    /// Window id of the leaf identified as being dragged (0 = none yet). Found
    /// by the preview's deferred scan; looked up via `tree.findLeaf` each tick
    /// so a window closing mid-drag can't leave a dangling pointer.
    drag_wid: u32 = 0,
    /// Whether a coalesced drag-preview update is already scheduled (drag
    /// events arrive at device rate; the preview repaints at ~20 Hz).
    preview_pending: bool = false,
    /// Pending debounce timer for a display-reconfiguration re-tile (null when
    /// none is armed). A single configuration change (clamshell, dock/undock)
    /// emits a burst of per-display callbacks; we coalesce them into one flush.
    display_timer: c.CFRunLoopTimerRef = null,
};

/// The single WM instance, reached from the C observer callback.
var g_manager: ?*Manager = null;

/// Whether the configured hyper trigger key (e.g. F18) is currently held. A key
/// remapper applies the real hyper modifiers downstream of our tap, so we track
/// the trigger key ourselves and synthesize the modifiers in `keyTap`.
var g_hyper_held: bool = false;

/// `CFAbsoluteTime` of the last user input that legitimately raises an app — a
/// Cmd-Tab or a mouse click. The activation space-follow only fires within a
/// short window after one of these (see `onAppActivated`), so a *background*
/// app activating itself doesn't yank the user to another Space, and our own
/// post-switch focus can't trigger a follow ping-pong. Mirrors agate-wm's
/// `g_last_cmd_tab`/`g_last_dock_click` gate (src/platform/follow.m).
var g_last_activation_input: f64 = 0;

/// Window virtual keycode for Tab (Cmd-Tab is the app switcher).
const kVK_Tab: u16 = 48;
/// How long after a Cmd-Tab / click an activation still counts as user-driven.
const activation_follow_window_s: f64 = 1.5;
/// How long after a rule routes a window its app's activation must not follow
/// it (the launch activation can land seconds after the window appears for a
/// slow-starting app; a deliberate Cmd-Tab after this window follows normally).
const rule_follow_suppress_s: f64 = 3.0;

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
        for (pids) |pid| _ = observeApp(mgr, pid);
    } else |_| {}

    // Observe destruction of each window already in the tree.
    if (appState.tree) |root| observeWindows(mgr, root);

    // Real-time app launch/terminate (see `macos.app_watch`): NSWorkspace posts
    // the instant an app starts or quits. This is the entire discovery path for
    // apps started after us — on launch we observe the app and enumerate the
    // windows it already has (yabai-style); no polling, no reconcile sweep.
    macos.app_watch.start(onAppEvent, mgr);

    // Intercept keyboard events for registered keybindings. This mirrors
    // Ghostty's global event tap (ghostty-org/ghostty, macos GlobalEventTap.swift):
    //   * session tap, head-inserted, `Default` option = an *intercepting* tap so
    //     a matched chord can be swallowed before the focused app sees it;
    //   * the run-loop source is added in `kCFRunLoopCommonModes`, not the default
    //     mode, so the tap keeps firing while the run loop is in a tracking/modal
    //     loop (menus, window drags) instead of going deaf;
    //   * a nil result means the permission (Accessibility / Input Monitoring) is
    //     missing — there is no separate query, the create just fails.
    //
    // A remapper (lazykeys) injects the hyper modifiers from its own session tap,
    // and our tap can land ahead of it in the chain, so the modifier flags are
    // often absent from the key *event* we receive (observed: mods=0x0). We don't
    // rely on the event's flags — `keyTap` queries the live modifier state
    // instead (see `CGEventSourceFlagsState`), which is order-independent. So tap
    // location/placement only needs to support swallowing: a session tap with the
    // Default option does (and tail-append is harmless here).
    // KeyDown for bindings; KeyUp so we can track a held "hyper" key (see keyTap).
    const kmask = macos.event_tap.mask(macos.event_tap.kCGEventKeyDown) |
        macos.event_tap.mask(macos.event_tap.kCGEventKeyUp);
    mgr.ktap = macos.event_tap.CGEventTapCreate(
        macos.event_tap.kCGSessionEventTap,
        macos.event_tap.kCGTailAppendEventTap,
        macos.event_tap.kCGEventTapOptionDefault,
        kmask,
        keyTap,
        null,
    );
    if (mgr.ktap) |tap| {
        const ksrc = macos.event_tap.CFMachPortCreateRunLoopSource(null, tap, 0);
        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), ksrc, c.kCFRunLoopCommonModes);
        macos.event_tap.CGEventTapEnable(tap, true);
    } else {
        std.debug.print("[observer] keyboard tap unavailable; keybindings disabled\n", .{});
    }

    // Menu-bar space indicator. The config is already loaded (wm.zig runs
    // lua_config.init before us), so the toggle is settled by now.
    if (lua_config.spaceIndicatorEnabled()) {
        if (macos.statusbar.init()) {
            macos.statusbar.setSpaceNumber(macos.spaces.activeUserIndex(appState.gpa, appState.skylight_cid));
        } else {
            std.debug.print("[observer] status bar unavailable; space indicator disabled\n", .{});
        }
    }

    // Re-tile whenever the user switches Mission Control spaces.
    _ = macos.skylight.CGSRegisterNotifyProc(
        onSpaceChanged,
        macos.skylight.kCGSNotificationSpaceChanged,
        mgr,
    );

    // Trackpad swipe gestures (Small Screen Mode's window cycling, and any
    // other `agate.gesture` binding). Recognition runs on MultitouchSupport's
    // thread; dispatch lands back on this run loop. Missing framework or no
    // trackpad just leaves gestures off.
    // A 4-finger swipe bound via `agate.gesture` collides with the native macOS
    // 4-finger swipe, which the window server consumes before tap level — so we
    // can't suppress it, only warn the user to turn it off in System Settings.
    if (gestures.start() and lua_config.hasFourFingerGesture()) {
        macos.trackpad.warnIfNativeSwipeEnabled();
    }

    // Swallow scroll while a bound trackpad gesture is in progress. MultitouchSupport
    // only *observes* the touches, so without this the window under a 3-/4-finger
    // swipe keeps scrolling its content — unlike the system's own 4-finger Space
    // swipe, which the window server consumes. An intercepting tap on scroll-wheel
    // events returns null (drops the event) whenever `gestures.blockingScroll()` is
    // set; otherwise it passes every event through untouched, so normal 2-finger
    // scrolling is unaffected. Head-inserted at the session level so we drop the
    // event before the focused app's own session tap can act on it.
    mgr.stap = macos.event_tap.CGEventTapCreate(
        macos.event_tap.kCGSessionEventTap,
        macos.event_tap.kCGHeadInsertEventTap,
        macos.event_tap.kCGEventTapOptionDefault,
        macos.event_tap.mask(macos.event_tap.kCGEventScrollWheel),
        scrollTap,
        null,
    );
    if (mgr.stap) |tap| {
        const ssrc = macos.event_tap.CFMachPortCreateRunLoopSource(null, tap, 0);
        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), ssrc, c.kCFRunLoopCommonModes);
        macos.event_tap.CGEventTapEnable(tap, true);
    } else {
        std.debug.print("[observer] scroll tap unavailable; gestures won't block scrolling\n", .{});
    }

    // Re-tile when the display layout changes (clamshell, dock/undock, a
    // resolution change). The visible frame we tile to moves with it, but no
    // window event fires, so without this the layout keeps the old geometry.
    _ = macos.display.CGDisplayRegisterReconfigurationCallback(onDisplayReconfigured, mgr);

    // With a status item, clicks on it are NSEvents delivered to this process,
    // and only [NSApp run] dispatches those safely — a bare CFRunLoopRun left
    // AppKit half-launched and the first click crashed in an uncaught
    // exception. NSApp's loop pumps the same main CFRunLoop, so every source
    // installed above behaves identically.
    if (macos.statusbar.active()) {
        macos.statusbar.runApp();
    } else {
        c.CFRunLoopRun();
    }
}

/// Walk the tree and ensure every leaf window's app is observed for creates and
/// that the window itself is observed for destruction.
fn observeWindows(mgr: *Manager, con: *data.Con) void {
    if (con.con_type == .Container) {
        if (con.window) |*w| {
            if (observeApp(mgr, w.pid)) |entry| {
                if (window.resolveElement(w)) |el| addDestroyNotification(entry.observer, el, w.id);
            }
        }
    }
    for (con.children.items) |child| observeWindows(mgr, child);
}

/// Ensure `pid` has an active create-observer: an `AXObserver` subscribed to
/// `AXWindowCreated` on the app element and wired into the run loop. Returns the
/// entry, or null if the app's Accessibility interface isn't ready yet — a
/// freshly launched app briefly returns errors from `AXObserverCreate` /
/// `AXObserverAddNotification`, and the caller (`observeAndAddWindows`) retries.
/// Idempotent: a second call for an already-observed pid just returns the entry.
fn observeApp(mgr: *Manager, pid: i32) ?Entry {
    if (mgr.entries.get(pid)) |e| return e;

    var observer: ax.AXObserverRef = null;
    if (ax.AXObserverCreate(pid, axCallback, &observer) != ax.kAXErrorSuccess) return null;
    const app = macos.Element.createApplication(pid) orelse {
        foundation.CFRelease(observer);
        return null;
    };

    // Nudge Chromium/Electron/Firefox-based apps to publish their AX tree so
    // they emit window notifications too.
    app.enableManualAccessibility();
    if (!addAppNotification(observer, app, "AXWindowCreated")) {
        app.release();
        foundation.CFRelease(observer);
        return null; // app not ready — caller retries
    }
    // Track the app's front window changing — notably a native tab switch, which
    // swaps which window is front without any create/destroy event. We pin a tab
    // group to a single tracked window id, so without this the leaf would point
    // at a stale background tab and every later focus/flush would raise THAT tab
    // over the one the user switched to. Best-effort (not all apps emit these).
    _ = addAppNotification(observer, app, "AXFocusedWindowChanged");
    _ = addAppNotification(observer, app, "AXMainWindowChanged");
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), ax.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);

    const entry = Entry{ .observer = observer, .app = app };
    mgr.entries.put(pid, entry) catch {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), ax.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);
        app.release();
        foundation.CFRelease(observer);
        return null;
    };
    return entry;
}

/// Register an application-level notification (the callback receives the
/// affected window element). `refcon` is null for these. Returns true on
/// success — a not-yet-ready app returns an error here.
fn addAppNotification(observer: ax.AXObserverRef, app: *macos.Element, name_str: []const u8) bool {
    const name = foundation.String.createUtf8(name_str) catch return false;
    defer name.release();
    return ax.AXObserverAddNotification(observer, app.ref(), name.ref(), null) == ax.kAXErrorSuccess;
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
        if (refcon) |r| onWindowDestroyed(mgr, observer, @intCast(@intFromPtr(r)));
    } else if (std.mem.eql(u8, name, "AXFocusedWindowChanged") or
        std.mem.eql(u8, name, "AXMainWindowChanged"))
    {
        onFrontWindowChanged(mgr, observer, element);
    }
}

/// The app's front window changed. If it's a window we already track, this is an
/// ordinary focus change — nothing to do. If it's an *untracked* window of the
/// app sitting at the exact frame of one of our leaves, the user switched to a
/// different native tab in that group (background tabs aren't ordered-in, so
/// they're never separate leaves): re-point the leaf at the now-front tab so
/// later focus/flush operate on the tab the user actually has showing, not the
/// stale one the group was created with. Same identical-frame + same-pid signal
/// `findTabSibling` uses (the window server has no tab concept).
fn onFrontWindowChanged(mgr: *Manager, observer: ax.AXObserverRef, element: ax.AXUIElementRef) void {
    const app = mgr.appState;
    const root = app.tree orelse return;
    const el = macos.Element.fromRef(element) orelse return;
    const wid = el.windowId() orelse return; // non-window front element: ignore
    if (tree.hasWindow(root, wid)) return; // tracked window — ordinary focus change

    const pid = el.pid() orelse return;
    const pos = el.position() orelse return;
    const sz = el.size() orelse return;
    const frame = macos.window_list.Rect{ .origin = pos, .size = sz };
    if (frame.size.width == 0 and frame.size.height == 0) return;

    const leaf = findLeafAtFrame(root, pid, frame) orelse return; // not a tab of a tracked group
    // Re-point the tab-group leaf at the front tab. Reuse the arena-owned owner
    // string (outlives the swap), release the stale element, re-arm destroy.
    const owner = (leaf.window orelse return).owner;
    const win = window.fromElement(el, owner) orelse return;
    leaf.window.?.deinit();
    leaf.window = win;
    leaf.id = win.id;
    leaf.window.?.is_tabbed = true;
    if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, win.id);
    std.debug.print("[observer] ~tab #{d} {s} now front\n", .{ win.id, owner });
}

/// A leaf under `con` owned by `pid` whose window occupies (within a tight
/// epsilon) `frame`. Identical frame + same app is the native-tab signal.
fn findLeafAtFrame(con: *data.Con, pid: i32, frame: macos.window_list.Rect) ?*data.Con {
    if (con.window) |w| {
        const eps: f64 = 2;
        if (w.pid == pid and
            @abs(w.bounds.origin.x - frame.origin.x) < eps and
            @abs(w.bounds.origin.y - frame.origin.y) < eps and
            @abs(w.bounds.size.width - frame.size.width) < eps and
            @abs(w.bounds.size.height - frame.size.height) < eps) return con;
    }
    for (con.children.items) |child| {
        if (findLeafAtFrame(child, pid, frame)) |found| return found;
    }
    return null;
}

/// Heap context (gpa) carrying a matched key chord from the tap callback to the
/// deferred executor; freed in `keyActionFired`.
const KeyAction = struct { code: u16, flags: u64 };

/// Run a matched keybinding's action one run-loop pass after the tap callback
/// returns. The actions here (space switch, full re-tile via Accessibility) are
/// slow enough to trip the event tap's ~1 s timeout if run inline, which would
/// have the system disable the tap mid-callback. Doing the work off the callback
/// keeps `keyTap` fast so the tap stays alive.
fn scheduleKeyAction(code: u16, flags: u64) void {
    const mgr = g_manager orelse return;
    const ctx = mgr.appState.gpa.create(KeyAction) catch return;
    ctx.* = .{ .code = code, .flags = flags };
    // Fire immediately (next loop pass).
    if (!scheduleOneShot(0, c.kCFRunLoopCommonModes, ctx, keyActionFired)) {
        mgr.appState.gpa.destroy(ctx);
    }
}

fn keyActionFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *KeyAction = @ptrCast(@alignCast(info orelse return));
    const mgr = g_manager orelse return;
    defer mgr.appState.gpa.destroy(ctx);
    _ = lua_config.handleKey(ctx.code, ctx.flags);
}

/// Keyboard event tap — intercepts kCGEventKeyDown before apps see it.
/// Returns null to swallow an event that matched a registered keybinding, or
/// the original event to let it through. Requires Accessibility permission.
fn keyTap(
    proxy: macos.event_tap.EventTapProxy,
    etype: macos.event_tap.EventType,
    event: macos.event_tap.EventRef,
    info: ?*anyopaque,
) callconv(.c) macos.event_tap.EventRef {
    _ = proxy;
    _ = info;
    switch (etype) {
        // The system disables an intercepting tap whose callback stalls; the only
        // way back is to re-enable it from here. Re-enable the *keyboard* tap.
        macos.event_tap.kCGEventTapDisabledByTimeout,
        macos.event_tap.kCGEventTapDisabledByUserInput,
        => if (g_manager) |m| if (m.ktap) |t| macos.event_tap.CGEventTapEnable(t, true),
        macos.event_tap.kCGEventKeyDown => {
            const code: u16 = @intCast(macos.event_tap.CGEventGetIntegerValueField(
                event,
                macos.event_tap.kCGKeyboardEventKeycode,
            ));
            // Cmd-Tab (the app switcher) is a user-driven activation — open the
            // gate so the resulting NSWorkspace activation follows to its Space.
            if (code == kVK_Tab and (macos.event_tap.CGEventGetFlags(event) & lua_config.MOD_CMD) != 0) {
                g_last_activation_input = c.CFAbsoluteTimeGetCurrent();
            }
            // The hyper trigger key (e.g. F18, from a Caps→F18 remap): track its
            // held state and pass it through so other apps still get it.
            const hk = lua_config.hyperKey();
            if (hk != 0 and code == hk) {
                g_hyper_held = true;
                return event;
            }
            // Synthesize the hyper modifiers a remapper hides from our tap.
            var flags = macos.event_tap.CGEventGetFlags(event);
            if (g_hyper_held) flags |= lua_config.hyperMods();
            // Decide fast (swallow or pass through) here; run the slow action off
            // the callback so we never trip the tap's stall timeout.
            if (lua_config.matchBinding(code, flags)) {
                std.debug.print("[observer] intercepted code={d} mods=0x{x}\n", .{ code, flags & lua_config.MOD_MASK });
                scheduleKeyAction(code, flags);
                return null; // swallow — chord is ours
            }
        },
        macos.event_tap.kCGEventKeyUp => {
            const code: u16 = @intCast(macos.event_tap.CGEventGetIntegerValueField(event, macos.event_tap.kCGKeyboardEventKeycode));
            const hk = lua_config.hyperKey();
            if (hk != 0 and code == hk) g_hyper_held = false;
        },
        else => {},
    }
    return event;
}

/// CGSRegisterNotifyProc callback for kCGSNotificationSpaceChanged: re-tile the
/// newly active workspace. Registered in `run()` below.
fn onSpaceChanged(
    _: u32,
    _: ?*anyopaque,
    _: usize,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const mgr: *Manager = @ptrCast(@alignCast(userdata orelse return));
    // Pick up Spaces created since startup (a new desktop, or the Space macOS
    // opens for a native-fullscreen window) before tiling — otherwise switching
    // to one finds no workspace and the flush/focus below would bail.
    _ = tree.reconcileSpaces(mgr.appState);
    // Follow windows that changed Space without a create/destroy event — chiefly
    // a window entering/leaving native fullscreen, which relocates it to/from a
    // fullscreen Space. Re-homes the leaf so we stop tiling a now-fullscreen
    // window (and resume when it returns).
    _ = tree.reconcileWindowSpaces(mgr.appState);
    // Finish a move that was waiting on a window leaving native fullscreen (the
    // leaf is now back on a user Space, re-homed just above).
    lua_config.runPendingMove(mgr.appState);
    // A Space switch on any display can change which workspace is visible on
    // that display, so re-tile every monitor's visible Space, not just the
    // focused one.
    tree.flushAllVisible(mgr.appState);
    // Keep the menu-bar indicator on the space the user now sees (no-op when
    // the status item was never created).
    macos.statusbar.setSpaceNumber(macos.spaces.activeUserIndex(mgr.appState.gpa, mgr.appState.skylight_cid));
    // A SkyLight space switch leaves the previous space's app frontmost, so the
    // menu bar keeps showing (and overlapping with) its menus. The menu bar
    // tracks the frontmost app, so activate a window on the now-active space to
    // pull the menu bar over. No-op on an empty space (nothing to focus).
    focusActiveSpace(mgr.appState);
    std.debug.print("[observer] space changed → retiled\n", .{});
}

/// CGDisplayRegisterReconfigurationCallback callback: the display layout
/// changed (clamshell open/close, an external monitor plugged or unplugged, a
/// resolution change). Re-tile the active workspace so its windows resize to the
/// new screen geometry. Registered in `run()`.
fn onDisplayReconfigured(
    _: macos.display.CGDirectDisplayID,
    flags: macos.display.CGDisplayChangeSummaryFlags,
    userInfo: ?*anyopaque,
) callconv(.c) void {
    // The "begin" pass fires before the change is applied — `mainVisibleFrame`
    // still reports the old geometry, so act only on the settled pass.
    if (flags & macos.display.kCGDisplayBeginConfigurationFlag != 0) return;
    const mgr: *Manager = @ptrCast(@alignCast(userInfo orelse return));
    scheduleDisplayReflush(mgr);
}

/// Arm (or re-arm) the debounced display re-tile. One configuration change emits
/// a callback per affected display, and the new geometry can take a beat to
/// settle, so each call cancels any pending timer and schedules a fresh one —
/// the flush runs once, shortly after the *last* callback of the burst.
fn scheduleDisplayReflush(mgr: *Manager) void {
    if (mgr.display_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        mgr.display_timer = null;
    }
    var timer_ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = mgr,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const fire_at = c.CFAbsoluteTimeGetCurrent() + 0.5;
    const timer = c.CFRunLoopTimerCreate(null, fire_at, 0, 0, 0, displayReflushFired, &timer_ctx);
    // Keep the +1 from Create as our own reference (so we can cancel it on the
    // next burst event); it's released when the timer fires or is replaced.
    if (timer) |t| {
        c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), t, c.kCFRunLoopCommonModes);
        mgr.display_timer = t;
    }
}

fn displayReflushFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const mgr: *Manager = @ptrCast(@alignCast(info orelse return));
    if (mgr.display_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        mgr.display_timer = null;
    }
    // The main display may have changed class (built-in vs external): move
    // workspaces into or out of Small Screen Mode before tiling to the new
    // geometry, so undocking lands straight in the accordion.
    _ = lua_config.applySmallScreenMode(mgr.appState);
    // A display change can add/remove Spaces too — reconcile before tiling.
    _ = tree.reconcileSpaces(mgr.appState);
    // Geometry changed for potentially every display — re-tile them all.
    tree.flushAllVisible(mgr.appState);
    std.debug.print("[observer] display reconfigured → retiled\n", .{});
}

/// Make an app on the currently active space frontmost (see `onSpaceChanged`).
fn focusActiveSpace(app: *state.AppState) void {
    const root = app.tree orelse return;
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(root, sid) orelse return;

    // A window was just moved to this Space and the user followed it over → keep
    // *that* window selected (yabai keeps a moved window focused). Only consume
    // the request when its target Space is the one now active, so the
    // intermediate notifications of a multi-step switch don't discard it.
    if (app.pending_focus) |pf| {
        if (pf.sid == sid) {
            app.pending_focus = null;
            if (tree.findLeaf(root, pf.wid)) |leaf| {
                if (focus.focusLeaf(leaf)) return;
            }
        }
    }

    // If the frontmost app already owns a window on this Space, macOS has
    // restored focus correctly — leave it. Overriding here used to force a
    // stacked tile to the front, and to raise a native tab group's *tracked*
    // window rather than the tab the user actually had showing (the tree tracks
    // one window id per tab group, not the live front tab). Only the stale case
    // — the previous Space's app still frontmost after the switch — needs us to
    // pull the menu bar over, which we then do via the most-recently-used tile.
    if (macos.workspace.frontmostAppPid()) |pid| {
        if (focus.pidHasWindowUnder(ws, pid)) return;
    }
    _ = focus.focusMostRecent(ws);
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
        macos.event_tap.kCGEventLeftMouseDown => {
            mgr.dragging = false;
            // A click (incl. on a Dock icon) is a user-driven activation — open
            // the follow gate. Coarser than agate-wm's Dock hit-test, but a click
            // that activates an app whose focused window is on the visible Space
            // resolves to "no off-screen space" and is a no-op anyway.
            g_last_activation_input = c.CFAbsoluteTimeGetCurrent();
        },
        macos.event_tap.kCGEventLeftMouseDragged => {
            mgr.dragging = true;
            schedulePreviewUpdate(mgr);
        },
        // Capture the cursor's drop location from the event itself. It's the
        // authoritative "where did you let go" point — unlike the dragged
        // window's AX frame, which lags behind a fast flick and can still read a
        // mid-drag position at mouse-up, defeating the cross-monitor hit-test.
        macos.event_tap.kCGEventLeftMouseUp => onMouseUp(mgr, macos.event_tap.CGEventGetLocation(event)),
        else => {},
    }
    return event; // listen-only: pass the event through unchanged
}

/// Intercepting tap on scroll-wheel events. Drops the event (returns null) while
/// a bound trackpad gesture is being performed so the window under the swipe
/// doesn't scroll; otherwise passes it through, leaving ordinary 2-finger
/// scrolling completely untouched.
fn scrollTap(
    proxy: macos.event_tap.EventTapProxy,
    etype: macos.event_tap.EventType,
    event: macos.event_tap.EventRef,
    info: ?*anyopaque,
) callconv(.c) macos.event_tap.EventRef {
    _ = proxy;
    _ = info;
    switch (etype) {
        // The system disables an intercepting tap if its callback stalls; the
        // tap must re-enable itself (re-enabling a different tap was the old bug).
        macos.event_tap.kCGEventTapDisabledByTimeout,
        macos.event_tap.kCGEventTapDisabledByUserInput,
        => if (g_manager) |m| if (m.stap) |t| macos.event_tap.CGEventTapEnable(t, true),
        macos.event_tap.kCGEventScrollWheel => if (gestures.blockingScroll()) return null,
        else => {},
    }
    return event;
}

/// What a scan of the active workspace found out of place: the first window
/// whose real size no longer matches the tree (a resize), and the first whose
/// position moved with its size intact (a move).
const DragScan = struct {
    resized: ?*data.Con = null,
    resized_frame: macos.window_list.Rect = undefined,
    moved: ?*data.Con = null,
    moved_frame: macos.window_list.Rect = undefined,
};

/// Recursively compare every leaf's real AX frame under `con` against the tree
/// bounds, classifying mismatches into `s` (yabai's `mouse_window_info_populate`
/// field-change test). Recursing — rather than only walking the workspace's
/// direct children, as this used to — lets windows inside nested containers be
/// dragged and previewed too.
fn scanChangedWindows(con: *data.Con, s: *DragScan) void {
    const eps: f64 = 2;
    if (con.window) |*win| {
        const el = window.resolveElement(win) orelse return;
        const pos = el.position() orelse return;
        const sz = el.size() orelse return;
        const frame = macos.window_list.Rect{ .origin = pos, .size = sz };

        const size_changed = @abs(sz.width - win.bounds.size.width) > eps or
            @abs(sz.height - win.bounds.size.height) > eps;
        const pos_changed = @abs(pos.x - win.bounds.origin.x) > eps or
            @abs(pos.y - win.bounds.origin.y) > eps;

        // A size mismatch only counts as a user resize where a resize is
        // possible: a split parent. In stacks/accordions (and for apps that
        // clamp their size, e.g. terminals snapping to the cell grid) the
        // mismatch is permanent noise — recording it would make every later
        // drag classify as a "resize" of that window and swallow the real move.
        const parent_layout = if (con.parent) |p| p.layout else data.Layout.H_SPLIT;
        const resizable = parent_layout == .H_SPLIT or parent_layout == .V_SPLIT;
        if (size_changed and resizable and s.resized == null) {
            s.resized = con;
            s.resized_frame = frame;
        } else if (pos_changed and !size_changed and s.moved == null) {
            s.moved = con;
            s.moved_frame = frame;
        }
        return;
    }
    for (con.children.items) |child| scanChangedWindows(child, s);
}

/// A drag ended. Find which managed window on the active Space actually changed
/// (its real frame no longer matches what the tree last set), classify it as a
/// resize or a move, let it influence the tree, and re-flush once. Scanning for
/// the changed window — rather than hit-testing the cursor at mouse-down — avoids
/// grabbing the wrong window when the press lands on a shared edge or in a gap.
fn onMouseUp(mgr: *Manager, drop: c.CGPoint) void {
    if (!mgr.dragging) return; // a plain click, not a drag
    mgr.dragging = false;
    mgr.drag_wid = 0;
    macos.overlay.hide();

    const app = mgr.appState;
    const root = app.tree orelse return;

    // Scan every *visible* workspace (each monitor's current Space), not just
    // the focused display's: dropping a window onto another monitor makes that
    // monitor the focused one, yet the dragged leaf is still tracked under the
    // source monitor's workspace — scanning only the active Space would miss it.
    var mbuf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const nmon = tree.collectMonitors(app, &mbuf);

    var scan = DragScan{};
    if (nmon == 0) {
        const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
        if (tree.findWorkspace(root, sid)) |ws| scanChangedWindows(ws, &scan);
    } else {
        for (mbuf[0..nmon]) |mi| {
            const ws = tree.findWorkspace(root, mi.current_space) orelse continue;
            scanChangedWindows(ws, &scan);
        }
    }

    // A displaced window whose centre now sits on another display is a
    // cross-monitor drag — handle that first (checked for both the resize and
    // move classifications, since a drop onto a smaller display can resize too).
    if (scan.resized) |leaf| {
        if (moveDraggedAcrossMonitors(app, leaf, drop)) return;
        _ = tree.applyManualResize(leaf, scan.resized_frame);
        tree.flushActive(app);
        return;
    }
    if (scan.moved) |leaf| {
        if (moveDraggedAcrossMonitors(app, leaf, drop)) return;
        _ = tree.applyManualMove(leaf, scan.moved_frame);
        tree.flushActive(app);
    }
}

/// If the window was dropped (cursor at `drop`, global top-left coords) on a
/// display other than its own, re-home its leaf to that display's visible
/// workspace, tile both displays, and follow focus to it. Returns true if a
/// cross-monitor move happened. The drop *cursor* — not the window's AX centre —
/// drives the hit-test, so a fast flick whose window frame hasn't settled by
/// mouse-up still resolves to the display the user released over.
fn moveDraggedAcrossMonitors(
    app: *state.AppState,
    leaf: *data.Con,
    drop: c.CGPoint,
) bool {
    var buf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const count = tree.collectMonitors(app, &buf);
    if (count < 2) return false;
    const mons = buf[0..count];

    const src_mon = tree.monitorOf(leaf);
    const src_ws = tree.workspaceOf(leaf);
    const cx = drop.x;
    const cy = drop.y;

    for (mons) |m| {
        if (src_mon != null and m.con == src_mon.?) continue;
        const f = m.frame;
        const inside = cx >= f.origin.x and cx < f.origin.x + f.size.width and
            cy >= f.origin.y and cy < f.origin.y + f.size.height;
        if (!inside) continue;
        if (m.current_space == 0) return false;

        const root = app.tree orelse return false;
        const dst_ws = tree.findWorkspace(root, m.current_space) orelse return false;
        if (dst_ws == leaf.parent) return false;
        const win = if (leaf.window) |w| w else return false;

        _ = macos.spaces.moveWindowToSpace(win.id, m.current_space); // idempotent
        _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
        if (src_ws) |sw| tree.flushWorkspace(app, sw); // re-tile the source we shrank
        tree.flushWorkspace(app, dst_ws); // tile the destination
        _ = focus.focusLeaf(leaf);
        std.debug.print("[observer] window #{d} dragged to monitor {d}\n", .{ win.id, m.con.id });
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Drag preview (the "where will it tile" overlay)
// ---------------------------------------------------------------------------

/// Arm one coalesced preview tick. Drag events arrive at device rate (60+ Hz);
/// the preview repaints from a one-shot timer so the tap callback stays cheap
/// (the AX frame reads happen off the callback) and at most one update is in
/// flight.
fn schedulePreviewUpdate(mgr: *Manager) void {
    if (!lua_config.dragPreviewEnabled()) return;
    if (mgr.preview_pending) return;
    mgr.preview_pending = true;
    if (!scheduleOneShot(0.05, c.kCFRunLoopCommonModes, mgr, previewUpdateFired)) {
        mgr.preview_pending = false;
    }
}

fn previewUpdateFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const mgr: *Manager = @ptrCast(@alignCast(info orelse return));
    mgr.preview_pending = false;
    if (!mgr.dragging) {
        macos.overlay.hide();
        return;
    }
    updateDragPreview(mgr);
}

/// One preview tick: identify the window being dragged (the leaf whose real
/// position left its tree slot with its size intact), then highlight the
/// sibling slot its centre is currently over — the exact slot
/// `tree.applyManualMove` will swap it into on mouse-up. No target (dragging
/// in place, or a resize) hides the overlay.
fn updateDragPreview(mgr: *Manager) void {
    const app = mgr.appState;
    const root = app.tree orelse return;
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(root, sid) orelse return;

    // Resolve the dragged leaf: the one identified on an earlier tick (if it
    // still exists and is still displaced), else a fresh scan.
    var leaf: ?*data.Con = null;
    var frame: macos.window_list.Rect = undefined;
    if (mgr.drag_wid != 0) {
        if (tree.findLeaf(root, mgr.drag_wid)) |l| {
            var scan = DragScan{};
            scanChangedWindows(l, &scan);
            if (scan.moved) |m| {
                leaf = m;
                frame = scan.moved_frame;
            }
        }
    }
    if (leaf == null) {
        var scan = DragScan{};
        scanChangedWindows(ws, &scan);
        if (scan.moved) |m| {
            leaf = m;
            frame = scan.moved_frame;
            mgr.drag_wid = @intCast(m.id);
        }
    }
    const dragged = leaf orelse {
        macos.overlay.hide();
        return;
    };

    // Same hit test as tree.applyManualMove: the sibling whose slot contains
    // the dragged window's centre is where it will land.
    const parent = dragged.parent orelse {
        macos.overlay.hide();
        return;
    };
    const cx = frame.origin.x + frame.size.width / 2;
    const cy = frame.origin.y + frame.size.height / 2;
    for (parent.children.items) |child| {
        if (child == dragged) continue;
        const b = (child.window orelse continue).bounds;
        if (cx >= b.origin.x and cx < b.origin.x + b.size.width and
            cy >= b.origin.y and cy < b.origin.y + b.size.height)
        {
            macos.overlay.show(b);
            return;
        }
    }
    macos.overlay.hide();
}

/// yabai's `window_is_standard` (koekeishiya/yabai, src/window.c): a window we
/// tile must report role `AXWindow` and subrole `AXStandardWindow`. This is a
/// *whitelist*, unlike the old subrole blacklist — it rejects sheets, popovers,
/// panels, and the auxiliary non-standard windows some apps (Ghostty, browsers)
/// keep around, which a blacklist would let through and double-tile.
fn isStandardAXWindow(el: *macos.Element) bool {
    const role = el.copyString("AXRole") orelse return false;
    defer role.release();
    var rbuf: [64]u8 = undefined;
    const r = role.cstring(&rbuf) orelse return false;
    if (!std.mem.eql(u8, r, "AXWindow")) return false;

    const sub = el.copyString("AXSubrole") orelse return false;
    defer sub.release();
    var sbuf: [64]u8 = undefined;
    const s = sub.cstring(&sbuf) orelse return false;
    return std.mem.eql(u8, s, "AXStandardWindow");
}

/// Apps (by owner name) that routinely have *no* fullscreen button yet whose
/// windows are normal, tileable windows — so the "no fullscreen button = dialog"
/// heuristic must not float them. From AeroSpace's exclusion list
/// (nikitabobko/AeroSpace, isDialogHeuristic). Ghostty is handled separately.
fn isFullscreenButtonExempt(app: []const u8) bool {
    const exempt = [_][]const u8{
        "Alacritty", "kitty", "WezTerm", "iTerm2", "Terminal",
        "Emacs",     "Code",  "Steam",   "qutebrowser",
    };
    for (exempt) |name| if (std.mem.eql(u8, app, name)) return true;
    return false;
}

/// A browser Picture-in-Picture overlay. These pass the standard-window gate
/// (role `AXWindow`, subrole `AXStandardWindow`) and Firefox/Zen even expose an
/// `AXFullScreenButton`, so the fullscreen-button heuristic alone would tile
/// them. The reliable cross-browser signal is the window title: Firefox/Zen
/// "Picture-in-Picture", Brave "Picture-in-picture", Chrome/Edge "Picture in
/// Picture" — matched case-insensitively (confirmed against AeroSpace's axDumps).
fn isPictureInPicture(el: *macos.Element) bool {
    const title = el.copyString("AXTitle") orelse return false;
    defer title.release();
    var buf: [256]u8 = undefined;
    const t = title.cstring(&buf) orelse return false; // long title ⇒ not PiP
    return std.ascii.indexOfIgnoreCase(t, "picture-in-picture") != null or
        std.ascii.indexOfIgnoreCase(t, "picture in picture") != null;
}

/// True if the (enabled) AX button `attr` (e.g. "AXFullScreenButton",
/// "AXCloseButton") is present on `el`. The window-title-bar buttons are child
/// AXUIElements exposed as attributes; absence means the value doesn't resolve.
fn hasEnabledButton(el: *macos.Element, attr: []const u8) bool {
    const btn = el.copyElement(attr) orelse return false;
    defer btn.release();
    return btn.getBool("AXEnabled") orelse false;
}

/// Whether agate should *tile* `el` (vs. leave it floating where macOS put it).
/// Ports AeroSpace's dialog heuristic (nikitabobko/AeroSpace, `isDialogHeuristic`
/// in Sources/AppBundle/model/AxUiElementWindowType.swift): Apple's AX API lets
/// apps mark dialogs, but many (and even some Apple windows, e.g. Finder's
/// "Copy" progress sheet) don't, so we also infer it. A window with no enabled
/// *fullscreen* button (distinct from the maximize/zoom button) is treated as a
/// dialog and floated — except terminals and a few special-cased apps, which
/// legitimately lack one. `app` is the owning application's name.
fn shouldTile(el: *macos.Element, app: []const u8) bool {
    // Sheets, popovers, panels and other non-standard windows: never tile.
    if (!isStandardAXWindow(el)) return false;

    // Browser Picture-in-Picture overlays float (Firefox/Zen expose a fullscreen
    // button, so they'd otherwise be tiled). Checked before the app cases since
    // it's app-agnostic.
    if (isPictureInPicture(el)) return false;

    // Terminals & friends often lack a fullscreen button but are real windows.
    if (isFullscreenButtonExempt(app)) return true;

    // Ghostty quirk (AeroSpace special case): a Ghostty window is a dialog only
    // when it has no fullscreen button *and* does have a close button; its real
    // windows have both, its prompts have only close.
    if (std.mem.eql(u8, app, "Ghostty")) {
        return hasEnabledButton(el, "AXFullScreenButton") or
            !hasEnabledButton(el, "AXCloseButton");
    }

    // General heuristic: a real tileable window has an enabled fullscreen button.
    return hasEnabledButton(el, "AXFullScreenButton");
}

/// Run the user's assignment rules (`agate.rule`) on a newly tracked window:
/// a match sends it to the rule's Space and re-homes its leaf (the rule logic
/// lives in the config layer). The window's title is read here, at detection
/// time, since rules can match on it. Callers re-flush the active space after.
fn applyAssignmentRules(app: *state.AppState, leaf: *data.Con, el: *macos.Element) void {
    var tbuf: [256]u8 = undefined;
    var title: []const u8 = "";
    if (el.copyString("AXTitle")) |t| {
        defer t.release();
        if (t.cstring(&tbuf)) |s| title = s;
    }
    lua_config.applyRulesToLeaf(app, leaf, title);
}

/// The Workspace Con for the Space window `wid` currently lives on, via
/// `macos.spaces.spaceForWindow`. Null if the window has no resolvable space yet.
fn workspaceForWindow(mgr: *Manager, wid: u32) ?*data.Con {
    const root = mgr.appState.tree orelse return null;
    const sid = macos.spaces.spaceForWindow(mgr.appState.skylight_cid, wid, 0xFFFF_FFFF_FFFF_FFFF) orelse return null;
    return tree.findWorkspace(root, sid);
}

/// Enumerate `pid`'s current windows via Accessibility and add any standard,
/// not-yet-tracked one — yabai's `window_manager_add_application_windows`
/// (koekeishiya/yabai, src/window_manager.c). Run right after an app is observed
/// so a window it created in the gap between launching and our observer attaching
/// (which would miss the `AXWindowCreated` event) is still picked up. Keyed by
/// `_AXUIElementGetWindow` id with a `hasWindow` guard, so it never double-adds.
fn addApplicationWindows(mgr: *Manager, pid: i32, observer: ax.AXObserverRef) void {
    const app = mgr.appState;
    const root = app.tree orelse return;
    const app_el = macos.Element.createApplication(pid) orelse return;
    defer app_el.release();
    app_el.enableManualAccessibility();

    const wins_v = app_el.copyAttribute("AXWindows") orelse return;
    defer foundation.CFRelease(wins_v);
    const arr: c.CFArrayRef = @ptrCast(wins_v);
    const n: usize = @intCast(c.CFArrayGetCount(arr));
    if (n == 0) return;

    var namebuf: [256]u8 = undefined;
    const name = macos.workspace.appName(pid, &namebuf) orelse "";

    var changed = false;
    for (0..n) |i| {
        const elem_ref: ax.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(arr, @intCast(i)));
        const el = macos.Element.fromRef(elem_ref) orelse continue;
        const wid = el.windowId() orelse continue;
        if (tree.hasWindow(root, wid)) continue;
        if (!shouldTile(el, name)) continue;

        const ws = workspaceForWindow(mgr, wid) orelse continue;
        const owner = app.arena.dupe(u8, name) catch continue;
        const win = window.fromElement(el, owner) orelse continue;
        if (win.bounds.size.width == 0 and win.bounds.size.height == 0) {
            win.deinit();
            continue;
        }
        const leaf = tree.addLeaf(app.arena, ws, win) catch {
            win.deinit();
            continue;
        };
        if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, wid);
        std.debug.print("[observer] +window #{d} {s} (launch)\n", .{ wid, win.owner });
        applyAssignmentRules(app, leaf, el);
        changed = true;
    }
    if (changed) tree.flushActive(app);
}

/// Tear down `pid`'s app observer and drop all of its windows from the tree
/// (the app terminated). Releases the now-defunct AXObserver + app element and
/// re-flushes if any window was removed. Safe to call for a pid we aren't
/// tracking (no-op beyond the window sweep).
fn removeApp(mgr: *Manager, pid: i32) void {
    const app = mgr.appState;
    const root = app.tree orelse return;
    if (mgr.entries.fetchRemove(pid)) |kv| {
        const src = ax.AXObserverGetRunLoopSource(kv.value.observer);
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        foundation.CFRelease(kv.value.observer);
        kv.value.app.release();
    }
    if (tree.removeWindowsForPid(root, pid)) {
        std.debug.print("[observer] -app pid={d} (terminated)\n", .{pid});
        tree.flushActive(app);
    }
}

/// Max attempts and delay for the launch-time observe retry. A freshly launched
/// app's Accessibility server can lag the launch notification by a few hundred
/// ms, so `AXObserverCreate`/`AXObserverAddNotification` transiently fail.
const max_observe_attempts: u32 = 12;
const observe_retry_delay: f64 = 0.5;

/// Heap-allocated context for an observe retry timer (freed in the callback).
const ObserveRetry = struct {
    mgr: *Manager,
    pid: i32,
    attempt: u32,
};

fn observeRetryFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *ObserveRetry = @ptrCast(@alignCast(info orelse return));
    defer ctx.mgr.appState.gpa.destroy(ctx);
    observeAndAddWindows(ctx.mgr, ctx.pid, ctx.attempt);
}

/// Observe `pid` and pull in the windows it already has. If the app isn't ready
/// to be observed yet, retry on a short timer (up to `max_observe_attempts`),
/// mirroring yabai's launch retry (koekeishiya/yabai, src/event.c
/// APPLICATION_LAUNCHED). Once observed, `AXWindowCreated` handles every later
/// window, so this only needs to run until the first successful observe.
fn observeAndAddWindows(mgr: *Manager, pid: i32, attempt: u32) void {
    if (observeApp(mgr, pid)) |entry| {
        addApplicationWindows(mgr, pid, entry.observer);
        return;
    }
    if (attempt + 1 >= max_observe_attempts) return;

    const ctx = mgr.appState.gpa.create(ObserveRetry) catch return;
    ctx.* = .{ .mgr = mgr, .pid = pid, .attempt = attempt + 1 };
    if (!scheduleOneShot(observe_retry_delay, c.kCFRunLoopDefaultMode, ctx, observeRetryFired)) {
        mgr.appState.gpa.destroy(ctx);
    }
}

/// Real-time NSWorkspace app launch/terminate handler (see `macos.app_watch`).
/// Launch → observe the app (with retry) and enumerate its existing windows;
/// terminate → drop the app's windows immediately.
fn onAppEvent(event: macos.app_watch.AppEvent, pid: i32, context: ?*anyopaque) callconv(.c) void {
    const mgr: *Manager = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .launched => observeAndAddWindows(mgr, pid, 0),
        .terminated => removeApp(mgr, pid),
        .activated => onAppActivated(mgr, pid),
    }
}

/// An app was brought to the front (Cmd-Tab, dock click, or a programmatic
/// activation). If its focused window lives on another Space, switch to that
/// Space *instantly* (by id, no animation) so activation follows the window.
///
/// This is the fast replacement for macOS's "When switching to an application,
/// switch to a Space with open windows for the application" — turn that setting
/// OFF (Settings ▸ Desktop & Dock ▸ Mission Control) so macOS doesn't play its
/// slow animated switch, and let agate switch here instead via the Dock-swipe
/// gesture (instant; the SkyLight `SetCurrentSpace` path is broken). If the
/// setting is left ON, macOS switches first and this is a no-op (target Space is
/// already active), so the two never fight.
///
/// The switch is async (the gesture lands a moment later), so we don't re-tile
/// here — `onSpaceChanged` does that when the Space actually changes. The
/// activated window is armed as the pending focus for its Space, so that handler
/// keeps *it* selected rather than the first tile.
fn onAppActivated(_: *Manager, pid: i32) void {
    if (pid == std.c.getpid()) return; // never follow our own activation

    // Gate: only follow activations the user drove via Cmd-Tab or a click in the
    // last ~1.5s. Excludes background self-activations (which would yank the
    // user's Space) and the activation our own post-switch focus provokes.
    if (c.CFAbsoluteTimeGetCurrent() - g_last_activation_input > activation_follow_window_s) return;

    // Defer the actual resolution + Space switch to a fresh run-loop turn. The
    // switch posts synthetic Dock-swipe gesture events; doing that *inside* the
    // NSWorkspace activation callback (re-entering the event system during its
    // own delivery) destabilizes the gesture recognizer and event taps over
    // repeated use — the same reason keybinding actions run deferred
    // (`scheduleKeyAction`). One clean turn later, the AX focused window is also
    // fully settled.
    scheduleActivationFollow(pid);
}

/// Heap context (gpa) carrying the activated pid from the notification callback
/// to the deferred follow; freed in `activationFollowFired`.
const ActivationFollow = struct { pid: i32 };

fn scheduleActivationFollow(pid: i32) void {
    const mgr = g_manager orelse return;
    const ctx = mgr.appState.gpa.create(ActivationFollow) catch return;
    ctx.* = .{ .pid = pid };
    if (!scheduleOneShot(0, c.kCFRunLoopCommonModes, ctx, activationFollowFired)) {
        mgr.appState.gpa.destroy(ctx);
    }
}

fn activationFollowFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *ActivationFollow = @ptrCast(@alignCast(info orelse return));
    const mgr = g_manager orelse return;
    defer mgr.appState.gpa.destroy(ctx);
    followActivation(mgr, ctx.pid);
}

/// Resolve `pid`'s focused window's Space and, if it's a non-visible Space,
/// switch to it (keeping the activated window selected via `pending_focus`).
/// Runs deferred from `scheduleActivationFollow`.
fn followActivation(mgr: *Manager, pid: i32) void {
    const app = mgr.appState;
    const app_el = macos.Element.createApplication(pid) orelse return;
    defer app_el.release();
    app_el.enableManualAccessibility();

    const focused = app_el.copyElement("AXFocusedWindow") orelse return;
    defer focused.release();
    const wid = focused.windowId() orelse return;

    // Only follow windows agate actually manages. Clicking an unmanaged window
    // — a browser Picture-in-Picture overlay, the macOS password/security modal,
    // and other windows `shouldTile` rejected at creation — activates its app but
    // must not yank the user to another Space (these float and can report a
    // foreign space id). If it's not in the tree, we don't manage it: stay put.
    if (!tree.hasWindow(app.tree orelse return, wid)) return;

    // An assignment rule just sent this window to its Space; the activation
    // we're handling is the app's own launch activation, not the user asking to
    // go there. The rule already handled the user's view (its own follow switch,
    // or staying put for `follow = false`), so following here would only add a
    // duplicate/unwanted switch. Time-bounded so a later Cmd-Tab still follows.
    if (app.rule_moved) |rm| {
        if (rm.wid == wid and c.CFAbsoluteTimeGetCurrent() - rm.at < rule_follow_suppress_s) {
            app.rule_moved = null;
            return;
        }
    }

    // Mask 0x7 returns the window's space only when it's *not* the visible one
    // (null here) — that null is the "nothing to follow" signal. The wide ~0
    // mask would wrongly report the active space for every window (agate-wm
    // src/platform/follow.m), so the follow would never fire.
    const target_sid = macos.spaces.spaceForWindow(app.skylight_cid, wid, 0x7) orelse return;
    if (target_sid == (macos.spaces.activeSpace(app.skylight_cid) orelse return)) return;

    app.pending_focus = .{ .wid = wid, .sid = target_sid };
    macos.spaces.switchToSpaceId(app.gpa, app.skylight_cid, target_sid) catch return;
    std.debug.print("[observer] activation follows window #{d} → space {d}\n", .{ wid, target_sid });
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

    const pid = el.pid() orelse return;
    var namebuf: [256]u8 = undefined;
    const name = macos.workspace.appName(pid, &namebuf) orelse "";

    // Only tile real, standard top-level windows; float dialogs. Sheets,
    // popovers, panels, scroll-indicator overlays (Zen/Firefox), and apps'
    // auxiliary non-standard windows all fire AXWindowCreated too, and tiling
    // them reflows and blinks the layout. `shouldTile` rejects those plus
    // windows the dialog heuristic flags (no fullscreen button, etc.).
    if (!shouldTile(el, name)) return;

    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    // The window may have opened on a Space created since startup (a new desktop)
    // — reconcile so its workspace exists, then look it up.
    const ws = tree.findWorkspace(app.tree.?, sid) orelse blk: {
        _ = tree.reconcileSpaces(app);
        break :blk tree.findWorkspace(app.tree.?, sid) orelse return;
    };

    const owner = app.arena.dupe(u8, name) catch return; // must outlive the event

    const win = window.fromElement(el, owner) orelse return;
    // A zero-size frame means the app hasn't committed the window's geometry yet
    // (or the AX query failed). These are transient overlays — skip them.
    if (win.bounds.size.width == 0 and win.bounds.size.height == 0) {
        win.deinit();
        return;
    }

    // Native macOS tab: a new window created at the exact frame of an existing
    // window of the same app is a tab joining that group (AppKit gives a tab
    // group one shared frame). Replace the group's leaf with the new front tab
    // instead of adding a second tile — the window server has no tab concept, so
    // this frame-identity test is how we collapse a tab group to one window.
    //
    // ONLY in split layouts: in a stack/accordion (and FLOAT) windows
    // legitimately share frames — terminals even open new windows at the
    // previous window's exact frame — so the frame-identity signal is
    // meaningless there and used to *swallow* the existing leaf, leaving its
    // window untracked at full size. In those layouts a genuine new native tab
    // simply gets its own (harmlessly overlapping) leaf.
    const frame_identity_is_tab = ws.layout == .H_SPLIT or ws.layout == .V_SPLIT;
    const frame_sibling: ?*data.Con = if (frame_identity_is_tab)
        tree.findTabSibling(ws, win.pid, win.bounds)
    else
        null;
    if (frame_sibling) |leaf| {
        leaf.window.?.deinit();
        leaf.window = win;
        leaf.id = win.id;
        // We just *observed* a tab join (same pid + identical frame), so mark the
        // leaf as a tab-group member directly. We can't rely on an AX attribute
        // for this: a dyld-cache search confirms `AXTabbedWindows` does not exist
        // on macOS 26, so the old `window.isTabbed` check always read false and
        // every tab close fell through to plain removal (untiling the group).
        leaf.window.?.is_tabbed = true;
        if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, wid);
        tree.flushActive(app);
        return;
    }

    std.debug.print("[observer] +window #{d} {s}\n", .{ win.id, win.owner });
    const leaf = tree.addLeaf(app.arena, ws, win) catch return;

    // `fromElement` already cached the AX element, so this just returns it.
    if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, wid);
    applyAssignmentRules(app, leaf, el);
    tree.flushActive(app);

    // In a stack/accordion the tiles overlap almost entirely; make sure the
    // new window is the one in front, not a sliver peeking out behind the
    // previous tile. (Skip if a rule just re-homed the leaf to another Space.)
    if (leaf.parent == ws and (ws.layout == .H_STACK or ws.layout == .V_STACK)) {
        _ = focus.focusLeaf(leaf);
    }
}

/// Re-pair `leaf` onto a surviving sibling tab after the tab it tracked was
/// closed. Every window in a native macOS tab group shares one frame, so a
/// same-app window still sitting at the closed tab's frame is the tab AppKit
/// just promoted to front. When one is found, swap the leaf onto it (and
/// re-register the destroy hook for the new window id) so the group keeps its
/// tile instead of collapsing. Returns true if the leaf was re-paired.
///
/// A sibling that already has its own leaf under `root` is never a tab: it's
/// just another tiled window sharing the frame (stack/accordion layouts put
/// every window at near-identical frames; "tabs" at *identical* ones). Pairing
/// onto it would put the same window id on two leaves and corrupt the tree.
fn repairTabLeaf(
    observer: ax.AXObserverRef,
    root: *data.Con,
    leaf: *data.Con,
    pid: i32,
    frame: macos.window_list.Rect,
    dead_wid: u32,
) bool {
    const app_el = macos.Element.createApplication(pid) orelse return false;
    defer app_el.release();
    app_el.enableManualAccessibility();

    const eps: f64 = 2;
    const sib = app_el.windowMatchingFrame(frame, eps, dead_wid) orelse return false;
    if (sib.windowId()) |sib_wid| {
        if (tree.hasWindow(root, sib_wid)) {
            sib.release();
            return false;
        }
    }
    // Reuse the old window's owner string (arena-allocated, outlives the swap).
    const owner = leaf.window.?.owner;
    const win = window.fromElement(sib, owner) orelse {
        sib.release();
        return false;
    };
    sib.release(); // `fromElement` took its own retain on the element

    leaf.window.?.deinit();
    leaf.window = win;
    leaf.id = win.id;
    leaf.window.?.is_tabbed = true; // still a member of the (now smaller) group
    if (window.resolveElement(&leaf.window.?)) |wel| addDestroyNotification(observer, wel, win.id);
    std.debug.print("[observer] ~window #{d} -> #{d} (tab survived)\n", .{ dead_wid, win.id });
    return true;
}

/// A window was destroyed. If it was the front tab of a native tab group, the
/// surviving sibling is already at the same frame, so re-pair the leaf onto it
/// (`repairTabLeaf`) instead of dropping the tile. If the window was a known tab
/// member but no sibling is queryable yet (the promoted tab can lag in
/// `AXWindows`), hold the slot ~0.3 s and retry from the grace timer. Otherwise
/// it's a plain window close: drop the leaf and re-flush.
fn onWindowDestroyed(mgr: *Manager, observer: ax.AXObserverRef, wid: u32) void {
    const app = mgr.appState;
    const root = app.tree orelse return;
    const leaf = tree.findLeaf(root, wid) orelse return;
    const w = if (leaf.window) |*win| win else return;
    const pid = w.pid;
    const frame = w.bounds;
    const was_tabbed = w.is_tabbed;

    // Fast path: the promoted sibling tab is already sitting at the closed tab's
    // frame — keep the tile by swapping the leaf onto it.
    if (repairTabLeaf(observer, root, leaf, pid, frame, wid)) {
        tree.flushActive(app);
        return;
    }

    // Known tab group whose sibling hasn't surfaced yet: retry after a grace
    // period before giving up the tile.
    if (was_tabbed) {
        const ctx = app.gpa.create(GraceContext) catch {
            _ = tree.removeWindow(root, wid);
            tree.flushActive(app);
            return;
        };
        ctx.* = .{ .mgr = mgr, .observer = observer, .wid = wid, .pid = pid, .frame = frame };
        if (scheduleOneShot(0.30, c.kCFRunLoopDefaultMode, ctx, graceTimerFired)) return;
        app.gpa.destroy(ctx);
    }

    const ws = leaf.parent;
    const idx = childIndex(ws, leaf);
    if (tree.removeWindow(root, wid)) {
        std.debug.print("[observer] -window #{d}\n", .{wid});
        tree.flushActive(app);
        // Feature 1: if that was the app's last window here, focus the tile to
        // its left so focus doesn't fall onto an unrelated app (yabai-style).
        if (ws) |parent| focus.focusAfterClose(parent, pid, idx);
    }
}
