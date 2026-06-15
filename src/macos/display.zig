//! Display geometry via AppKit's `NSScreen` (through the Objective-C runtime).
//! The window-server / AX coordinate space is top-left origin, but AppKit is
//! bottom-left, so the visible frame is flipped here before it's handed out.
const std = @import("std");
const c = @import("c.zig").c;
const objc = @import("objc");
const foundation = @import("foundation.zig");

pub const Rect = c.CGRect;

/// The usable frame of the main display in top-left (AX/CG) coordinates —
/// `NSScreen.visibleFrame`, which already excludes the menu bar and the Dock,
/// flipped from AppKit's bottom-left origin. Null if AppKit is unavailable.
pub fn mainVisibleFrame() ?Rect {
    const NSScreen = objc.getClass("NSScreen") orelse return null;
    const screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (screen.value == null) return null;

    const full = screen.msgSend(c.CGRect, "frame", .{});
    const vis = screen.msgSend(c.CGRect, "visibleFrame", .{});
    return .{
        .origin = .{
            .x = vis.origin.x,
            // Flip: AppKit measures y from the bottom of the primary screen.
            .y = full.size.height - (vis.origin.y + vis.size.height),
        },
        .size = vis.size,
    };
}

// --- Per-display geometry (keyed by display UUID) ---------------------------
//
// Tiling spans every display, so the layout engine needs each display's usable
// frame, not just the main one. `SLSCopyManagedDisplaySpaces` identifies a
// display by its UUID string; AppKit identifies an `NSScreen` by its
// `NSScreenNumber` (a `CGDirectDisplayID`). `CGDisplayCreateUUIDFromDisplayID`
// bridges the two, so we tag each screen's visible frame with its UUID and the
// tree matches a Monitor Con to its frame by that UUID.

/// CoreGraphics: the UUID of a display id (caller owns the returned CFUUIDRef).
extern fn CGDisplayCreateUUIDFromDisplayID(display: u32) ?*anyopaque;
/// CoreFoundation: a CFString from a CFUUID (caller owns the result).
extern fn CFUUIDCreateString(alloc: ?*anyopaque, uuid: ?*anyopaque) c.CFStringRef;

/// A display's usable area tagged with its window-server UUID, so a Monitor in
/// the tree (identified by the SkyLight UUID) can be matched to its geometry.
pub const DisplayFrame = struct {
    /// The CGDisplay UUID string (matches `SLSCopyManagedDisplaySpaces`'s
    /// "Display Identifier"). NUL-free; `uuid_len` is the valid length.
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    /// Visible frame (menu bar / Dock excluded) in top-left AX coordinates.
    frame: Rect,

    pub fn uuidSlice(self: *const DisplayFrame) []const u8 {
        return self.uuid[0..self.uuid_len];
    }
};

/// Every active display's visible frame, each tagged with its UUID, written into
/// `buf` (a caller-owned, typically stack, buffer — displays are few, so no heap
/// allocation is needed on this per-flush path). Returns the filled prefix.
/// Frames are in top-left AX coordinates (flipped from AppKit's bottom-left
/// origin, which is anchored to the *primary* screen `NSScreen.screens[0]`).
pub fn displayFrames(buf: []DisplayFrame) []DisplayFrame {
    const NSScreen = objc.getClass("NSScreen") orelse return buf[0..0];
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    if (screens.value == null) return buf[0..0];
    const count = screens.msgSend(usize, "count", .{});
    if (count == 0) return buf[0..0];

    // The flip constant is the primary screen's height (AppKit's global origin).
    const first = screens.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)});
    if (first.value == null) return buf[0..0];
    const primary_h = first.msgSend(c.CGRect, "frame", .{}).size.height;

    const key = foundation.String.createUtf8("NSScreenNumber") catch return buf[0..0];
    defer key.release();

    var n: usize = 0;
    var i: usize = 0;
    while (i < count and n < buf.len) : (i += 1) {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        if (screen.value == null) continue;
        const vis = screen.msgSend(c.CGRect, "visibleFrame", .{});

        var df = DisplayFrame{ .frame = .{
            .origin = .{ .x = vis.origin.x, .y = primary_h - (vis.origin.y + vis.size.height) },
            .size = vis.size,
        } };

        // NSScreenNumber → CGDirectDisplayID → UUID string.
        const dd = screen.msgSend(objc.Object, "deviceDescription", .{});
        if (dd.value != null) {
            const num = dd.msgSend(objc.Object, "objectForKey:", .{key.ref()});
            if (num.value != null) {
                const display_id = num.msgSend(u32, "unsignedIntValue", .{});
                if (CGDisplayCreateUUIDFromDisplayID(display_id)) |uuid| {
                    defer foundation.CFRelease(uuid);
                    if (foundation.String.fromRef(CFUUIDCreateString(null, uuid))) |s| {
                        defer s.release();
                        if (s.cstring(&df.uuid)) |slice| df.uuid_len = slice.len;
                    }
                }
            }
        }
        buf[n] = df;
        n += 1;
    }
    return buf[0..n];
}

/// The visible frame of the display whose UUID is `uuid`, searched in `frames`
/// (from `displayFrames`). Null if no display matches.
pub fn frameForUUID(frames: []const DisplayFrame, uuid: []const u8) ?Rect {
    if (uuid.len == 0) return null;
    for (frames) |f| {
        if (std.mem.eql(u8, f.uuidSlice(), uuid)) return f.frame;
    }
    return null;
}

/// The main display's canonical UUID string, copied into `buf`. SkyLight's
/// `SLSCopyManagedDisplaySpaces` sometimes labels the main display "Main"
/// instead of a UUID; this resolves the UUID that the NSScreen-derived
/// `DisplayFrame`s are keyed by, so the two can still be matched.
pub fn mainDisplayUUID(buf: []u8) ?[]const u8 {
    const uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) orelse return null;
    defer foundation.CFRelease(uuid);
    const s = foundation.String.fromRef(CFUUIDCreateString(null, uuid)) orelse return null;
    defer s.release();
    return s.cstring(buf);
}

// --- Small-screen detection -------------------------------------------------

extern fn CGMainDisplayID() u32;
extern fn CGDisplayIsBuiltin(display: u32) i32;
extern fn CGGetActiveDisplayList(maxDisplays: u32, activeDisplays: ?[*]u32, displayCount: *u32) i32;

/// Whether the built-in panel is the *only* active display — the actual
/// "working on the MacBook screen" situation Small Screen Mode is for.
///
/// Deliberately NOT "is the main display built-in": `CGMainDisplayID` is the
/// arrangement-primary display, which often stays the built-in panel while the
/// user works on an external monitor beside it — keying on it put every
/// workspace into the accordion on a big screen. With one display there is no
/// ambiguity.
pub fn builtinIsOnlyDisplay() bool {
    var count: u32 = 0;
    if (CGGetActiveDisplayList(0, null, &count) != 0) return false;
    if (count != 1) return false;
    return CGDisplayIsBuiltin(CGMainDisplayID()) != 0;
}

// --- Display reconfiguration (clamshell, dock/undock, resolution change) ---
//
// CoreGraphics posts a reconfiguration callback whenever the display layout
// changes: a display is added/removed (lid close in clamshell, plugging in an
// external monitor), the main display moves, or a mode (resolution) changes.
// The visible frame the WM tiles to changes with it, but no window event fires,
// so without this hook the layout would keep using the *old* screen geometry
// until the next create/destroy/drag. See `<CoreGraphics/CGDisplayConfiguration.h>`.

pub const CGDirectDisplayID = u32;
pub const CGDisplayChangeSummaryFlags = u32;

/// Fired *before* the configuration changes — the new geometry is not valid yet,
/// so callers should ignore this pass and act on the settled (no-begin) pass.
pub const kCGDisplayBeginConfigurationFlag: CGDisplayChangeSummaryFlags = 1 << 0;

pub const CGDisplayReconfigurationCallBack = *const fn (
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: ?*anyopaque,
) callconv(.c) void;

/// Register `callback` for display-layout changes. Returns a `CGError` (0 =
/// success). The callback fires once per affected display, in two passes (a
/// "begin" pass with `kCGDisplayBeginConfigurationFlag`, then a settled pass).
pub extern fn CGDisplayRegisterReconfigurationCallback(
    callback: CGDisplayReconfigurationCallBack,
    userInfo: ?*anyopaque,
) i32;
