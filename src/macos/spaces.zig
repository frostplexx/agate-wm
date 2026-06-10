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

pub const Space = struct {
    /// The window-server space id ("id64").
    id: u64,
    /// Space type: 0 = user, 2 = fullscreen, 4 = system (per observation).
    type: i64,
    /// Index into the managed-display list this space belongs to.
    display_index: usize,
};

/// The currently active Space id on the focused display (the one owning the
/// active menu bar). Null if it can't be determined.
pub fn activeSpace(cid: sl.ConnectionID) ?u64 {
    const uuid = sl.SLSCopyActiveMenuBarDisplayIdentifier(cid) orelse return null;
    defer foundation.CFRelease(uuid);
    return sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
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

/// Switch the focused display to the 1-based user-space index `n`
/// (counting only `type == 0` user Spaces, stepping past fullscreen ones).
pub fn switchToIndex(alloc: Allocator, cid: sl.ConnectionID, n: usize) !void {
    if (n == 0) return;
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);

    var seen: usize = 0;
    for (order.spaces, 0..) |sp, i| {
        if (sp.type != 0) continue;
        seen += 1;
        if (seen == n) {
            swipeToPos(order, i);
            return;
        }
    }
}

/// Switch to the next user Space on the focused display (no wrap).
pub fn switchNext(alloc: Allocator, cid: sl.ConnectionID) !void {
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    var i: usize = order.active_pos + 1;
    while (i < order.spaces.len) : (i += 1) {
        if (order.spaces[i].type == 0) {
            swipeToPos(order, i);
            return;
        }
    }
}

/// Switch to the previous user Space on the focused display (no wrap).
pub fn switchPrev(alloc: Allocator, cid: sl.ConnectionID) !void {
    const order = (try focusedDisplayOrder(alloc, cid)) orelse return;
    defer alloc.free(order.spaces);
    var i: usize = order.active_pos;
    while (i > 0) {
        i -= 1;
        if (order.spaces[i].type == 0) {
            swipeToPos(order, i);
            return;
        }
    }
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

    var list: std.ArrayList(Space) = .empty;
    errdefer list.deinit(alloc);

    const ndisp: usize = @intCast(c.CFArrayGetCount(displays));
    var di: usize = 0;
    while (di < ndisp) : (di += 1) {
        const ddict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(displays, @intCast(di)));
        const spaces_arr: c.CFArrayRef = @ptrCast(c.CFDictionaryGetValue(ddict, key_spaces.ref()) orelse continue);
        const nsp: usize = @intCast(c.CFArrayGetCount(spaces_arr));
        var si: usize = 0;
        while (si < nsp) : (si += 1) {
            const sdict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(spaces_arr, @intCast(si)));
            const sid = foundation.dictI64(sdict, key_id.ref()) orelse continue;
            try list.append(alloc, .{
                .id = @intCast(sid),
                .type = foundation.dictI64(sdict, key_type.ref()) orelse 0,
                .display_index = di,
            });
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
