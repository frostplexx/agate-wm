//! Enumerate Spaces and the windows on them via SkyLight — the window-server's
//! own view, which (unlike the public CGWindowList) spans every Space and
//! display, including Spaces that aren't currently visible.
//!
//! Flow (the approach yabai uses):
//!   1. `SLSCopyManagedDisplaySpaces` -> per-display dicts, each with a "Spaces"
//!      array of space dicts ("id64", "type", ...).
//!   2. For a space id, `SLSCopyWindowsWithOptionsAndTags` -> the window ids on
//!      it (a CFArray of CFNumbers).
//!
//! SkyLight returns only window *ids*; pair them with
//! `window_list.listAll` to recover owner/title/bounds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const sl = @import("skylight.zig");
const foundation = @import("foundation.zig");
const String = foundation.String;
const event_tap = @import("event_tap.zig");
const display = @import("display.zig");
const objc = @import("objc");

pub const Space = struct {
    /// The window-server space id ("id64").
    id: u64,
    /// Space type: 0 = user, 2 = fullscreen, 4 = system (per observation).
    type: i64,
    /// Index into the managed-display list this space belongs to. NOT stable
    /// across display reconfiguration — only meaningful within the query it came
    /// from. The display's stable identity is `monitor_key`.
    display_index: usize,
    /// Stable identity (UUID hash, `monitor.keyForUUID`) of the display this
    /// Space lives on — what a Monitor Con is keyed by. 0 if the display's UUID
    /// couldn't be resolved.
    monitor_key: u64 = 0,
    /// The display UUID this Space lives on. NUL-free; `uuid_len` is its length.
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,

    pub fn uuidSlice(self: *const Space) []const u8 {
        return self.uuid[0..self.uuid_len];
    }
};

/// A physical display as the window server sees it: its UUID (matching
/// `display.DisplayFrame.uuid`), and the Space currently visible on it. The
/// array index returned by `managedDisplays` equals the `display_index` of the
/// Spaces on that display (both walk `SLSCopyManagedDisplaySpaces` in order).
pub const ManagedDisplay = struct {
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    /// The space id currently shown on this display (its visible workspace).
    current_space: u64 = 0,

    pub fn uuidSlice(self: *const ManagedDisplay) []const u8 {
        return self.uuid[0..self.uuid_len];
    }
};

/// Whether `s` is a canonical UUID string (36 chars with dashes at 8/13/18/23),
/// distinguishing a real "Display Identifier" UUID from the literal "Main".
fn looksLikeUUID(s: []const u8) bool {
    if (s.len != 36) return false;
    return s[8] == '-' and s[13] == '-' and s[18] == '-' and s[23] == '-';
}

/// Every managed display in window-server order, each with its UUID and the
/// Space currently visible on it, written into `buf` (a caller-owned, typically
/// stack, buffer — displays are few, so no heap allocation is needed on this
/// per-flush path). Returns the filled prefix. Mirrors yabai's display
/// enumeration (koekeishiya/yabai, src/display_manager.c).
pub fn managedDisplays(buf: []ManagedDisplay, cid: sl.ConnectionID) []ManagedDisplay {
    const displays = sl.SLSCopyManagedDisplaySpaces(cid) orelse return buf[0..0];
    defer foundation.CFRelease(displays);

    const key_disp = String.createUtf8("Display Identifier") catch return buf[0..0];
    defer key_disp.release();

    const ndisp: usize = @intCast(c.CFArrayGetCount(displays));
    var n: usize = 0;
    var di: usize = 0;
    while (di < ndisp and n < buf.len) : (di += 1) {
        const ddict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(displays, @intCast(di)));
        var md = ManagedDisplay{};
        if (c.CFDictionaryGetValue(ddict, key_disp.ref())) |v| {
            const uuid_ref: c.CFStringRef = @ptrCast(v);
            if (String.fromRef(uuid_ref)) |s| {
                if (s.cstring(&md.uuid)) |slice| md.uuid_len = slice.len;
            }
            // Resolve the live current space from SkyLight's own identifier
            // (more reliable across macOS versions than the dict's "Current
            // Space"). SLS understands its identifier even when it's "Main".
            md.current_space = sl.SLSManagedDisplayGetCurrentSpace(cid, uuid_ref);
            // The main display's identifier may be the literal "Main" rather
            // than a UUID; the NSScreen-derived frames are keyed by UUID, so
            // substitute the main display's canonical UUID for matching.
            if (!looksLikeUUID(md.uuidSlice())) {
                md.uuid_len = if (display.mainDisplayUUID(&md.uuid)) |slice| slice.len else 0;
            }
        }
        buf[n] = md;
        n += 1;
    }
    return buf[0..n];
}

/// A single-element CFArray<CFNumber(SInt64)> holding `sid` — the shape SkyLight's
/// space-set calls (`SLSShowSpaces`/`SLSHideSpaces`) expect. Caller releases it.
fn spaceArray(sid: u64) ?c.CFArrayRef {
    var id64: i64 = @intCast(sid);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &id64) orelse return null;
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    return c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks);
}

/// Switch the display identified by `uuid` to the Space `sid` directly, via
/// SkyLight (no gesture). Unlike `switchToSpaceId` this can target a display that
/// ISN'T the focused one — the gesture path only ever drives the active display.
///
/// A bare `SLSManagedDisplaySetCurrentSpace` leaves the *outgoing* Space's menu-bar
/// overlay standing, so after a cross-display switch the old bar doubles over the
/// new one. Mirror yabai's `do_space_focus`: show the destination Space, **hide the
/// source Space** (this tears down its menu bar), then set the current space.
/// `uuid` is the display's "Display Identifier".
///
/// NOTE: this silent SkyLight path does not make Dock re-render the menu bar's
/// *app menus* (Dock never observes an event), so it can still leave them doubled
/// on a cross-display switch — prefer the gesture path (`switchToSpaceIdOnDisplay`)
/// when you can warp the cursor onto the target display.
pub fn setDisplaySpace(cid: sl.ConnectionID, uuid: []const u8, sid: u64) void {
    const s = String.createUtf8(uuid) catch return;
    defer s.release();

    const source = sl.SLSManagedDisplayGetCurrentSpace(cid, s.ref());
    if (source == sid) return; // already showing it — nothing to switch or tear down

    if (spaceArray(sid)) |dest_arr| {
        defer foundation.CFRelease(dest_arr);
        sl.SLSShowSpaces(cid, dest_arr);
    }
    if (spaceArray(source)) |src_arr| {
        defer foundation.CFRelease(src_arr);
        sl.SLSHideSpaces(cid, src_arr);
    }
    sl.SLSManagedDisplaySetCurrentSpace(cid, s.ref(), sid);
}

/// Switch the display whose stable key is `monitor_key` (currently showing
/// `current_sid`) to Space `sid` using the Dock-swipe gesture. Unlike
/// `switchToSpaceId`, which only ever drives the menu-bar display, this computes
/// the swipe count from the *target* display's own Space order — so it works on a
/// secondary monitor once the caller has warped the cursor onto it (the synthetic
/// swipe acts on the display under the cursor). Mirrors yabai's
/// `space_manager_focus_space_using_gesture`: a real gesture is the one path that
/// keeps the menu bar coherent (no doubled app menus), where the silent SkyLight
/// `setDisplaySpace` does not. No-op if `sid` isn't on that display or is shown.
pub fn switchToSpaceIdOnDisplay(alloc: Allocator, cid: sl.ConnectionID, monitor_key: u64, current_sid: u64, sid: u64) !void {
    if (current_sid == sid) return;
    const order = (try displayOrder(alloc, cid, monitor_key, current_sid)) orelse return;
    defer alloc.free(order.spaces);
    for (order.spaces, 0..) |sp, i| {
        if (sp.id == sid) {
            swipeToPos(order, i);
            return;
        }
    }
}

/// The Spaces on the display with stable key `monitor_key`, in Mission Control
/// order, with `active_pos` at the Space `current_sid` (that display's visible
/// one). The display-specific counterpart of `focusedDisplayOrder`. Null if the
/// display has no Spaces. Caller owns `.spaces`.
fn displayOrder(alloc: Allocator, cid: sl.ConnectionID, monitor_key: u64, current_sid: u64) !?Order {
    const all = try allSpaces(alloc, cid);
    defer alloc.free(all);

    var list: std.ArrayList(Space) = .empty;
    errdefer list.deinit(alloc);
    var active_pos: usize = 0;
    for (all) |sp| {
        if (sp.monitor_key != monitor_key) continue;
        if (sp.id == current_sid) active_pos = list.items.len;
        try list.append(alloc, sp);
    }
    if (list.items.len == 0) {
        list.deinit(alloc);
        return null;
    }
    return .{ .spaces = try list.toOwnedSlice(alloc), .active_pos = active_pos };
}

/// Hand menu-bar ownership to the display identified by `uuid`. A Dock-swipe
/// gesture switches the *visible* Space of the display under the cursor but does
/// NOT update which display owns the menu bar, so after a cross-display switch the
/// previous display's menu bar lingers and overlaps the new app's — call this with
/// the now-focused display's UUID to fix it. `uuid` is a "Display Identifier".
pub fn setActiveMenuBarDisplay(cid: sl.ConnectionID, uuid: []const u8) void {
    const s = String.createUtf8(uuid) catch return;
    defer s.release();
    sl.SLSSetActiveMenuBarDisplayIdentifier(cid, s.ref(), s.ref());
}

/// The currently active Space id on the focused display (the one owning the
/// active menu bar). Null if it can't be determined.
pub fn activeSpace(cid: sl.ConnectionID) ?u64 {
    const uuid = sl.SLSCopyActiveMenuBarDisplayIdentifier(cid) orelse return null;
    defer foundation.CFRelease(uuid);
    return sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
}

/// The SkyLight space id that window `wid` currently lives on, or null. Works
/// for any window (not just tracked ones) via `SLSCopySpacesForWindows`.
///
/// `mask` selects which space categories to report (yabai/agate-wm `0x7` =
/// user+fullscreen+system). NOTE: `~0`/`0xFFFF…` is *wrong* for "which space is
/// this window on" — it returns the active space for any window. Use `0x7` to
/// detect a window on a *non-visible* space: it returns null for a window on the
/// currently visible space (an empty result), and the real space id otherwise.
pub fn spaceForWindow(cid: sl.ConnectionID, wid: u32, mask: u64) ?u64 {
    var id64: i64 = @intCast(wid);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &id64) orelse return null;
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    const wins = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse return null;
    defer foundation.CFRelease(wins);
    const spaces_arr = sl.SLSCopySpacesForWindows(cid, mask, wins) orelse return null;
    defer foundation.CFRelease(spaces_arr);
    if (c.CFArrayGetCount(spaces_arr) == 0) return null;
    var sid: i64 = 0;
    if (c.CFNumberGetValue(
        @ptrCast(c.CFArrayGetValueAtIndex(spaces_arr, 0)),
        c.kCFNumberSInt64Type,
        &sid,
    ) == 0) return null;
    return @intCast(sid);
}

/// Switch the focused display to the Space with id `sid` using the Dock-swipe
/// gesture — instant, and (unlike the SkyLight `SLSManagedDisplaySetCurrentSpace`
/// path, which is broken on current macOS) it keeps the menu bar correct. Steps
/// through Mission Control order from the active Space to `sid`. No-op if `sid`
/// isn't on the focused display or is already active.
pub fn switchToSpaceId(alloc: Allocator, cid: sl.ConnectionID, sid: u64) !void {
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    for (order.spaces, 0..) |sp, i| {
        if (sp.id == sid) {
            swipeToPos(order, i);
            return;
        }
    }
}

/// The spaces on the focused display in Mission Control order, plus the position
/// of the active space within that order. Caller owns `.spaces`.
const Order = struct { spaces: []Space, active_pos: usize };

fn focusedDisplayOrder(alloc: Allocator, cid: sl.ConnectionID) !?Order {
    const active = activeSpace(cid) orelse return null;
    const all = try allSpaces(alloc, cid);
    defer alloc.free(all);

    var display_idx: ?usize = null;
    for (all) |sp| if (sp.id == active) {
        display_idx = sp.display_index;
        break;
    };
    const didx = display_idx orelse return null;

    var list: std.ArrayList(Space) = .empty;
    errdefer list.deinit(alloc);
    var active_pos: usize = 0;
    for (all) |sp| {
        if (sp.display_index != didx) continue;
        if (sp.id == active) active_pos = list.items.len;
        try list.append(alloc, sp);
    }
    return .{ .spaces = try list.toOwnedSlice(alloc), .active_pos = active_pos };
}

/// Synthesize `|target_pos - active_pos|` Dock-swipe gestures to reach
/// `target_pos`. Each gesture sequence switches exactly one Space.
fn swipeToPos(order: Order, target_pos: usize) void {
    if (target_pos == order.active_pos) return;
    const dir: event_tap.SwipeDirection = if (target_pos > order.active_pos) .left else .right;
    const steps: usize = if (target_pos > order.active_pos)
        target_pos - order.active_pos
    else
        order.active_pos - target_pos;
    for (0..steps) |_| event_tap.performSwitchGesture(dir);
}

/// Switch the focused display to the 1-based Space index `n` — counting every
/// Space in Mission Control order, exactly as the swipe traverses them. This
/// INCLUDES native-fullscreen Spaces (e.g. a fullscreened Finder at position 7
/// is reached by `n == 7`), since the fake swipe can land on them. No-op if `n`
/// is past the strip.
pub fn switchToIndex(alloc: Allocator, cid: sl.ConnectionID, n: usize) !void {
    if (n == 0) return;
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    if (n - 1 < order.spaces.len) swipeToPos(order, n - 1);
}

/// Like `switchToIndex` but for the display with stable key `monitor_key` (shown
/// `current_sid`), not the menu-bar display. The synthetic swipe lands on the
/// display under the cursor, so when the caller drives the cursor's monitor the
/// step count must be computed for THAT display — else a swipe meant for the
/// hovered monitor uses the active monitor's order and lands wrong. No-op if `n`
/// is past that display's strip.
pub fn switchToIndexOnDisplay(alloc: Allocator, cid: sl.ConnectionID, monitor_key: u64, current_sid: u64, n: usize) !void {
    if (n == 0) return;
    const order = (try displayOrder(alloc, cid, monitor_key, current_sid)) orelse return;
    defer alloc.free(order.spaces);
    if (n - 1 < order.spaces.len) swipeToPos(order, n - 1);
}

/// Switch to the next Space on the focused display (any type — one swipe step,
/// no wrap).
pub fn switchNext(alloc: Allocator, cid: sl.ConnectionID) !void {
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    if (order.active_pos + 1 < order.spaces.len) swipeToPos(order, order.active_pos + 1);
}

/// Reassign window `wid` to managed space `space_id` on macOS 26+ Tahoe via
/// the bridged Obj-C path SkyLight requires: alloc
/// `SLSBridgedMoveWindowsToManagedSpaceOperation`, init with the CFArray and
/// target sid, then submit through `SLSPerformAsynchronousBridgedWindowManagementOperation`.
/// Mirrors yabai's `space_manager_move_window_to_space`
/// (koekeishiya/yabai, src/space_manager.c). Returns false if SkyLight isn't
/// loaded or the bridged class is missing — there is no legacy fallback.
pub fn moveWindowToSpace(wid: u32, space_id: u64) bool {
    // CGWindowID is uint32_t; SkyLight's CFArray must hold Int32 CFNumbers —
    // Int64 entries are silently dropped.
    var id32: i32 = @bitCast(wid);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &id32) orelse return false;
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    const arr = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse return false;
    defer foundation.CFRelease(arr);

    const perform = sl.slsPerformAsynchronousBridgedWindowManagementOperation() orelse return false;
    const cls = objc.getClass("SLSBridgedMoveWindowsToManagedSpaceOperation") orelse return false;
    const allocd = cls.msgSend(objc.Object, "alloc", .{});
    if (allocd.value == null) return false;
    const op = allocd.msgSend(objc.Object, "initWithWindows:spaceID:", .{ arr, space_id });
    if (op.value == null) return false;
    defer op.msgSend(void, "release", .{});
    perform(op.value);
    return true;
}

/// The SkyLight space id at the 1-based Mission Control position `n` on the
/// focused display (every Space counted, including fullscreen — matching
/// `switchToIndex`). Null if `n` is past the strip.
pub fn userSpaceIdAt(alloc: Allocator, cid: sl.ConnectionID, n: usize) !?u64 {
    if (n == 0) return null;
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return null;
    defer alloc.free(order.spaces);
    if (n - 1 >= order.spaces.len) return null;
    return order.spaces[n - 1].id;
}

/// The SkyLight space id at the 1-based Mission Control position `n` on the
/// display at `display_index` (every Space counted). Unlike `userSpaceIdAt`,
/// addresses any display — so a window can be assigned to a Space on another
/// monitor. Null if `n` is out of range on that display.
pub fn userSpaceIdOnDisplay(alloc: Allocator, cid: sl.ConnectionID, display_index: usize, n: usize) !?u64 {
    if (n == 0) return null;
    const all = try allSpaces(alloc, cid);
    defer alloc.free(all);
    var seen: usize = 0;
    for (all) |sp| {
        if (sp.display_index != display_index) continue;
        seen += 1;
        if (seen == n) return sp.id;
    }
    return null;
}

/// The `display_index` of Space `sid` within `all`, or null.
fn displayOfSpace(all: []const Space, sid: u64) ?usize {
    for (all) |sp| if (sp.id == sid) return sp.display_index;
    return null;
}

/// A resolved Space switch target: the Space id, plus whether the active
/// (menu-bar) Space is on that same display — i.e. whether the Dock-swipe
/// gesture, which only drives the active display, can reach it.
pub const SpaceTarget = struct { sid: u64, active_on_same_display: bool };

/// Resolve the 1-based position `n` on display `display_index` to its Space id
/// and whether that display is the active one, in a single `allSpaces` pass — so
/// a caller can pick the gesture (active display) over the direct SkyLight set
/// (secondary display) without a second query. Null if `n` is past the strip.
pub fn resolveSpaceTarget(alloc: Allocator, cid: sl.ConnectionID, display_index: usize, n: usize) !?SpaceTarget {
    if (n == 0) return null;
    const active = activeSpace(cid);
    const all = try allSpaces(alloc, cid);
    defer alloc.free(all);
    var sid: ?u64 = null;
    var active_di: ?usize = null;
    var seen: usize = 0;
    for (all) |sp| {
        if (active != null and sp.id == active.?) active_di = sp.display_index;
        if (sid == null and sp.display_index == display_index) {
            seen += 1;
            if (seen == n) sid = sp.id;
        }
    }
    return .{ .sid = sid orelse return null, .active_on_same_display = active_di != null and active_di.? == display_index };
}

/// Whether Space `sid` shares a display with the active (menu-bar) Space — i.e.
/// the gesture can reach it. The window-targeted counterpart of `resolveSpaceTarget`.
pub fn spaceOnActiveDisplay(alloc: Allocator, cid: sl.ConnectionID, sid: u64) bool {
    const active = activeSpace(cid) orelse return false;
    if (active == sid) return true;
    const all = allSpaces(alloc, cid) catch return false;
    defer alloc.free(all);
    const a = displayOfSpace(all, active) orelse return false;
    const s = displayOfSpace(all, sid) orelse return false;
    return a == s;
}

/// The 1-based Mission Control position of the currently active Space on the
/// focused display (every Space counted) — the number `agate.space(n)` reaches
/// it with, and what the menu-bar indicator shows. Null if it can't be resolved.
pub fn activeUserIndex(alloc: Allocator, cid: sl.ConnectionID) ?usize {
    const order = (focusedDisplayOrder(alloc, cid) catch return null) orelse return null;
    defer alloc.free(order.spaces);
    return order.active_pos + 1;
}

/// Switch to the previous Space on the focused display (any type — one swipe
/// step, no wrap).
pub fn switchPrev(alloc: Allocator, cid: sl.ConnectionID) !void {
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    if (order.active_pos > 0) swipeToPos(order, order.active_pos - 1);
}

/// Every Space across every display. Caller owns the slice (use an arena).
pub fn allSpaces(alloc: Allocator, cid: sl.ConnectionID) ![]Space {
    const displays = sl.SLSCopyManagedDisplaySpaces(cid) orelse return &.{};
    defer foundation.CFRelease(displays);

    const key_spaces = try String.createUtf8("Spaces");
    defer key_spaces.release();
    const key_id = try String.createUtf8("id64");
    defer key_id.release();
    const key_type = try String.createUtf8("type");
    defer key_type.release();
    const key_disp = try String.createUtf8("Display Identifier");
    defer key_disp.release();

    var list: std.ArrayList(Space) = .empty;
    errdefer list.deinit(alloc);

    const ndisp: usize = @intCast(c.CFArrayGetCount(displays));
    var di: usize = 0;
    while (di < ndisp) : (di += 1) {
        const ddict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(displays, @intCast(di)));

        // Resolve this display's stable UUID once for every Space on it, applying
        // the same "Main" → canonical-UUID substitution as `managedDisplays`.
        var disp_uuid: [64]u8 = undefined;
        var disp_uuid_len: usize = 0;
        if (c.CFDictionaryGetValue(ddict, key_disp.ref())) |v| {
            if (String.fromRef(@ptrCast(v))) |s| {
                if (s.cstring(&disp_uuid)) |slice| disp_uuid_len = slice.len;
            }
        }
        if (!looksLikeUUID(disp_uuid[0..disp_uuid_len])) {
            disp_uuid_len = if (display.mainDisplayUUID(&disp_uuid)) |slice| slice.len else 0;
        }
        const disp_key = display.keyForUUID(disp_uuid[0..disp_uuid_len]);

        const spaces_arr: c.CFArrayRef = @ptrCast(c.CFDictionaryGetValue(ddict, key_spaces.ref()) orelse continue);
        const nsp: usize = @intCast(c.CFArrayGetCount(spaces_arr));
        var si: usize = 0;
        while (si < nsp) : (si += 1) {
            const sdict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(spaces_arr, @intCast(si)));
            const sid = foundation.dictI64(sdict, key_id.ref()) orelse continue;
            var sp = Space{
                .id = @intCast(sid),
                .type = foundation.dictI64(sdict, key_type.ref()) orelse 0,
                .display_index = di,
                .monitor_key = disp_key,
                .uuid_len = disp_uuid_len,
            };
            @memcpy(sp.uuid[0..disp_uuid_len], disp_uuid[0..disp_uuid_len]);
            try list.append(alloc, sp);
        }
    }
    return list.toOwnedSlice(alloc);
}

/// The window ids on `space_id`. `all` uses option mask 0x7 which returns every
/// window assigned to the space (including those on inactive/off-screen spaces);
/// false uses 0x2 which returns only currently on-screen windows. Pass true
/// when enumerating spaces that are not currently visible. Caller owns the slice.
pub fn windowsOnSpace(
    alloc: Allocator,
    cid: sl.ConnectionID,
    space_id: u64,
    all: bool,
) ![]u32 {
    // Wrap the space id in a CFArray<CFNumber> as the API expects.
    var sid: i64 = @intCast(space_id);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &sid) orelse return &.{};
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    const space_arr = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse return &.{};
    defer foundation.CFRelease(space_arr);

    var set_tags: u64 = 0;
    var clear_tags: u64 = 0;
    const options: u32 = if (all) 0x7 else 0x2;
    const wins = sl.SLSCopyWindowsWithOptionsAndTags(
        cid,
        0, // any owner
        space_arr,
        options,
        &set_tags,
        &clear_tags,
    ) orelse return &.{};
    defer foundation.CFRelease(wins);

    const n: usize = @intCast(c.CFArrayGetCount(wins));
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);

    var count: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const numref = c.CFArrayGetValueAtIndex(wins, @intCast(i));
        var wid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(numref), c.kCFNumberSInt64Type, &wid) == 0) continue;
        out[count] = @intCast(wid);
        count += 1;
    }
    return out[0..count];
}

/// The *manageable* (tileable) window ids on `space_id`: real, top-level
/// application windows, with child windows (sheets/tabs/popovers), overlays and
/// non-standard windows excluded — using the window-server's own window
/// iterator, the way yabai does (koekeishiya/yabai, src/space.c:
/// `space_window_list_for_connection`). No Accessibility round-trip, so it works
/// for windows on inactive Spaces. Caller owns the slice.
pub fn manageableWindowsOnSpace(alloc: Allocator, cid: sl.ConnectionID, space_id: u64) ![]u32 {
    // Wrap the space id in a CFArray<CFNumber> as the API expects.
    var sid: i64 = @intCast(space_id);
    const num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &sid) orelse return &.{};
    defer foundation.CFRelease(num);
    var values = [_]?*const anyopaque{@ptrCast(num)};
    const space_arr = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse return &.{};
    defer foundation.CFRelease(space_arr);

    // 0x7 = every window assigned to the space (including minimized/off-screen).
    var set_tags: u64 = 0;
    var clear_tags: u64 = 0;
    const wins = sl.SLSCopyWindowsWithOptionsAndTags(cid, 0, space_arr, 0x7, &set_tags, &clear_tags) orelse return &.{};
    defer foundation.CFRelease(wins);

    const n: usize = @intCast(c.CFArrayGetCount(wins));
    if (n == 0) return &.{};

    // Run the ids through the window-server query to recover per-window tags,
    // attributes and parent id, then keep only the manageable ones.
    const query = sl.SLSWindowQueryWindows(cid, wins, @intCast(n)) orelse return &.{};
    defer foundation.CFRelease(query);
    const iterator = sl.SLSWindowQueryResultCopyWindows(query) orelse return &.{};
    defer foundation.CFRelease(iterator);

    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(alloc);

    while (sl.SLSWindowIteratorAdvance(iterator)) {
        const tags = sl.SLSWindowIteratorGetTags(iterator);
        const attributes = sl.SLSWindowIteratorGetAttributes(iterator);
        const parent_wid = sl.SLSWindowIteratorGetParentID(iterator);
        if (isManageable(parent_wid, attributes, tags)) {
            try list.append(alloc, sl.SLSWindowIteratorGetWindowID(iterator));
        }
    }
    return list.toOwnedSlice(alloc);
}

/// The window-server tag/attribute predicate yabai uses to decide whether a
/// window is a real, tileable, top-level window. Ported from
/// `space_window_list_for_connection` (koekeishiya/yabai, src/space.c), including
/// the exact bitmasks. Two accepting shapes: a normal top-level window (branch
/// A), or a special window that reports no attributes but carries the right tags
/// (branch B). Both require the window to be "visible" per its tag bits.
fn isManageable(parent_wid: u32, attributes: u64, tags: u64) bool {
    const visible = (tags & 0x1) != 0 or ((tags & 0x2) != 0 and (tags & 0x80000000) != 0);
    const branch_a = parent_wid == 0 and
        ((attributes & 0x2) != 0 or (tags & 0x0400000000000000) != 0) and
        visible;
    const branch_b = attributes == 0x0 and
        ((tags & 0x1000000000000000) != 0 or (tags & 0x0300000000000000) != 0) and
        visible;
    return branch_a or branch_b;
}

test "isManageable accepts yabai's two window shapes and rejects the rest" {
    // Branch A: top-level (no parent), standard attribute bit, visible tag.
    try std.testing.expect(isManageable(0, 0x2, 0x1));
    // Alternate visibility form: tag 0x2 requires the 0x80000000 companion bit.
    try std.testing.expect(isManageable(0, 0x2, 0x2 | 0x80000000));
    try std.testing.expect(!isManageable(0, 0x2, 0x2)); // companion bit missing
    // A child window (sheet/tab/popover) is rejected even with the right bits.
    try std.testing.expect(!isManageable(42, 0x2, 0x1));
    // Branch B: no attributes, but the special tag bits plus visibility.
    try std.testing.expect(isManageable(0, 0x0, 0x1000000000000000 | 0x1));
    // Invisible windows never pass.
    try std.testing.expect(!isManageable(0, 0x2, 0x0));
}
