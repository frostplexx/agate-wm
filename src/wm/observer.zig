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

    if (repairTabLeaf(ctx.observer, leaf, ctx.pid, ctx.frame, ctx.wid)) {
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
    for (p.children.items, 0..) |c2, i| if (c2 == child) return i;
    return 0;
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
    /// Whether the mouse actually moved since mouse-down (a drag, not a click).
    dragging: bool = false,
};

/// The single WM instance, reached from the C observer callback.
var g_manager: ?*Manager = null;

/// Whether the configured hyper trigger key (e.g. F18) is currently held. A key
/// remapper applies the real hyper modifiers downstream of our tap, so we track
/// the trigger key ourselves and synthesize the modifiers in `keyTap`.
var g_hyper_held: bool = false;

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

    // Re-tile whenever the user switches Mission Control spaces.
    _ = macos.skylight.CGSRegisterNotifyProc(
        onSpaceChanged,
        macos.skylight.kCGSNotificationSpaceChanged,
        mgr,
    );

    c.CFRunLoopRun();
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
    }
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
    var timer_ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = ctx,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    // Fire immediately (next loop pass); interval 0 = one-shot.
    const timer = c.CFRunLoopTimerCreate(null, c.CFAbsoluteTimeGetCurrent(), 0, 0, 0, keyActionFired, &timer_ctx);
    if (timer) |t| {
        c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), t, c.kCFRunLoopCommonModes);
        c.CFRelease(t);
    } else {
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
    tree.flushActive(mgr.appState);
    std.debug.print("[observer] space changed → retiled\n", .{});
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

    for (ws.children.items) |leaf| {
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

/// The Workspace Con for the Space window `wid` currently lives on, via
/// `SLSCopySpacesForWindows`. Null if the window has no resolvable space yet.
fn workspaceForWindow(mgr: *Manager, wid: u32) ?*data.Con {
    const root = mgr.appState.tree orelse return null;
    var wid_i64: i64 = @intCast(wid);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &wid_i64) orelse return null;
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    const wins_arr = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse return null;
    defer foundation.CFRelease(wins_arr);
    const space_arr = macos.skylight.SLSCopySpacesForWindows(
        mgr.appState.skylight_cid,
        0xFFFF_FFFF_FFFF_FFFF,
        wins_arr,
    ) orelse return null;
    defer foundation.CFRelease(space_arr);
    if (c.CFArrayGetCount(space_arr) == 0) return null;
    var sid: i64 = 0;
    if (c.CFNumberGetValue(
        @ptrCast(c.CFArrayGetValueAtIndex(space_arr, 0)),
        c.kCFNumberSInt64Type,
        &sid,
    ) == 0) return null;
    return tree.findWorkspace(root, @intCast(sid));
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
        if (!isStandardAXWindow(el)) continue;

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
    var timer_ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = ctx,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const fire_at = c.CFAbsoluteTimeGetCurrent() + observe_retry_delay;
    const timer = c.CFRunLoopTimerCreate(null, fire_at, 0, 0, 0, observeRetryFired, &timer_ctx);
    if (timer) |t| {
        c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), t, c.kCFRunLoopDefaultMode);
        c.CFRelease(t);
    } else {
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

    // Only tile real, standard top-level windows (yabai `window_is_standard`).
    // Sheets, popovers, panels, scroll-indicator overlays (Zen/Firefox), and
    // apps' auxiliary non-standard windows all fire AXWindowCreated too, but
    // tiling them reflows and blinks the layout — so reject anything that isn't
    // an AXWindow/AXStandardWindow.
    if (!isStandardAXWindow(el)) return;

    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(app.tree.?, sid) orelse return;

    const pid = el.pid() orelse return;
    var namebuf: [256]u8 = undefined;
    const name = macos.workspace.appName(pid, &namebuf) orelse "";
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
    if (tree.findTabSibling(ws, win.pid, win.bounds)) |leaf| {
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
    tree.flushActive(app);
}

/// Re-pair `leaf` onto a surviving sibling tab after the tab it tracked was
/// closed. Every window in a native macOS tab group shares one frame, so a
/// same-app window still sitting at the closed tab's frame is the tab AppKit
/// just promoted to front. When one is found, swap the leaf onto it (and
/// re-register the destroy hook for the new window id) so the group keeps its
/// tile instead of collapsing. Returns true if the leaf was re-paired.
fn repairTabLeaf(
    observer: ax.AXObserverRef,
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
    if (repairTabLeaf(observer, leaf, pid, frame, wid)) {
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
        var timer_ctx = c.CFRunLoopTimerContext{
            .version = 0,
            .info = ctx,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const fire_at = c.CFAbsoluteTimeGetCurrent() + 0.30;
        const timer = c.CFRunLoopTimerCreate(null, fire_at, 0, 0, 0, graceTimerFired, &timer_ctx);
        if (timer) |t| {
            c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), t, c.kCFRunLoopDefaultMode);
            c.CFRelease(t);
            return;
        }
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
