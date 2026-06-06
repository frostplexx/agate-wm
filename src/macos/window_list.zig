//! Wrapper over CoreGraphics' window-server query (`CGWindowListCopyWindowInfo`).
//! This is the "ground truth" list of on-screen windows agate reconciles its
//! tiling tree against.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const cg = @import("cg.zig");
const foundation = @import("foundation.zig");

pub const Rect = c.CGRect;

pub const WindowInfo = struct {
    id: u32,
    pid: i32,
    /// Window-server layer; 0 is the normal layer for app windows.
    layer: i32,
    bounds: Rect,
    /// Owning app name, allocated with the allocator passed to `listOnScreen`.
    owner: []const u8,
};

/// Return every on-screen window (excluding desktop elements), newest first.
/// Caller owns the slice and each `owner` string; freeing is simplest via an
/// arena.
pub fn listOnScreen(alloc: Allocator) ![]WindowInfo {
    return list(alloc, cg.kCGWindowListOptionOnScreenOnly | cg.kCGWindowListExcludeDesktopElements);
}

/// Return descriptions for *all* windows in the session, including those on
/// other Spaces and off-screen. Useful as a `wid -> metadata` lookup to enrich
/// SkyLight's per-space window ids (which carry no owner/title/bounds).
pub fn listAll(alloc: Allocator) ![]WindowInfo {
    return list(alloc, cg.kCGWindowListOptionAll);
}

/// Run `CGWindowListCopyWindowInfo` with the given option flags.
pub fn list(alloc: Allocator, option: cg.WindowListOption) ![]WindowInfo {
    const arr = cg.CGWindowListCopyWindowInfo(option, cg.kCGNullWindowID) orelse return &.{};
    defer foundation.CFRelease(arr);

    const n: usize = @intCast(c.CFArrayGetCount(arr));
    const out = try alloc.alloc(WindowInfo, n);
    errdefer alloc.free(out);

    var count: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(arr, @intCast(i)));
        const owner = dictString(dict, cg.kCGWindowOwnerName, alloc) orelse try alloc.dupe(u8, "");
        out[count] = .{
            .id = @intCast(foundation.dictI64(dict, cg.kCGWindowNumber) orelse 0),
            .pid = @intCast(foundation.dictI64(dict, cg.kCGWindowOwnerPID) orelse 0),
            .layer = @intCast(foundation.dictI64(dict, cg.kCGWindowLayer) orelse 0),
            .bounds = dictBounds(dict),
            .owner = owner,
        };
        count += 1;
    }
    return out[0..count];
}

/// Metadata for a single window id (owner/pid/bounds), via CoreGraphics. The
/// `owner` is allocated with `alloc`. Null if the window no longer exists.
pub fn infoForId(alloc: Allocator, wid: u32) ?WindowInfo {
    const arr = cg.CGWindowListCopyWindowInfo(cg.kCGWindowListOptionIncludingWindow, wid) orelse return null;
    defer foundation.CFRelease(arr);
    if (c.CFArrayGetCount(arr) == 0) return null;

    const dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(arr, 0));
    const owner = dictString(dict, cg.kCGWindowOwnerName, alloc) orelse (alloc.dupe(u8, "") catch return null);
    return .{
        .id = @intCast(foundation.dictI64(dict, cg.kCGWindowNumber) orelse 0),
        .pid = @intCast(foundation.dictI64(dict, cg.kCGWindowOwnerPID) orelse 0),
        .layer = @intCast(foundation.dictI64(dict, cg.kCGWindowLayer) orelse 0),
        .bounds = dictBounds(dict),
        .owner = owner,
    };
}

fn dictString(dict: c.CFDictionaryRef, key: c.CFStringRef, alloc: Allocator) ?[]const u8 {
    const v = c.CFDictionaryGetValue(dict, key) orelse return null;
    const s = foundation.String.fromRef(@ptrCast(v)) orelse return null;
    return s.toOwnedUtf8(alloc) catch null;
}

fn dictBounds(dict: c.CFDictionaryRef) Rect {
    var bounds: Rect = std.mem.zeroes(Rect);
    if (c.CFDictionaryGetValue(dict, cg.kCGWindowBounds)) |bv| {
        _ = c.CGRectMakeWithDictionaryRepresentation(@ptrCast(bv), &bounds);
    }
    return bounds;
}
