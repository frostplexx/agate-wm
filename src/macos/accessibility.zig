//! Idiomatic wrappers over the macOS Accessibility (AX) API — the mechanism
//! agate uses to inspect and move windows it does not own. Built on the
//! hand-written `extern` decls in `ax.zig` plus the CoreFoundation/CoreGraphics
//! `@cImport` in `c.zig`.
//!
//! Note on attribute constants: the SDK exposes `kAXPositionAttribute` &c. as
//! `CFSTR(...)` macros, which can't be referenced from Zig. So we build the
//! attribute CFStrings from their string values ("AXPosition", ...) at call
//! time instead.
const std = @import("std");
const c = @import("c.zig").c;
const ax = @import("ax.zig");
const foundation = @import("foundation.zig");
const String = foundation.String;

pub const Point = c.CGPoint;
pub const Size = c.CGSize;
pub const Rect = c.CGRect;

/// Whether the process is trusted for Accessibility. agate cannot manage
/// windows without this (System Settings → Privacy → Accessibility).
pub fn isProcessTrusted() bool {
    return ax.AXIsProcessTrusted() != 0;
}

/// Like `isProcessTrusted`, but raises the system permission prompt if access
/// has not been granted yet.
pub fn isProcessTrustedPrompt() bool {
    var keys = [_]?*const anyopaque{@ptrCast(ax.kAXTrustedCheckOptionPrompt)};
    var vals = [_]?*const anyopaque{@ptrCast(c.kCFBooleanTrue)};
    const opts = c.CFDictionaryCreate(
        null,
        @ptrCast(&keys),
        @ptrCast(&vals),
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer if (opts != null) foundation.CFRelease(opts);
    return ax.AXIsProcessTrustedWithOptions(@ptrCast(opts)) != 0;
}

/// An `AXUIElementRef`: an application, window, or other accessible UI object.
pub const Element = opaque {
    pub fn fromRef(r: ax.AXUIElementRef) ?*Element {
        return @ptrCast(@constCast(r));
    }

    pub fn ref(self: *Element) ax.AXUIElementRef {
        return @ptrCast(self);
    }

    /// The top-level accessibility object for the app with the given pid.
    pub fn createApplication(pid: c.pid_t) ?*Element {
        return fromRef(ax.AXUIElementCreateApplication(pid));
    }

    /// The system-wide accessibility object (used to reach the focused app).
    pub fn createSystemWide() ?*Element {
        return fromRef(ax.AXUIElementCreateSystemWide());
    }

    pub fn release(self: *Element) void {
        foundation.CFRelease(self);
    }

    /// Copy a raw attribute value by AX attribute name (e.g. "AXFocusedWindow").
    /// Caller owns the returned CF object and must `CFRelease` it.
    pub fn copyAttribute(self: *Element, name: []const u8) ?c.CFTypeRef {
        const attr = String.createUtf8(name) catch return null;
        defer attr.release();
        var value: c.CFTypeRef = null;
        if (ax.AXUIElementCopyAttributeValue(self.ref(), attr.ref(), &value) != ax.kAXErrorSuccess)
            return null;
        return value;
    }

    fn setAttribute(self: *Element, name: []const u8, value: c.CFTypeRef) bool {
        const attr = String.createUtf8(name) catch return false;
        defer attr.release();
        return ax.AXUIElementSetAttributeValue(self.ref(), attr.ref(), value) == ax.kAXErrorSuccess;
    }

    /// Copy a child AXUIElement attribute (e.g. "AXFocusedWindow", "AXMainWindow").
    pub fn copyElement(self: *Element, name: []const u8) ?*Element {
        const v = self.copyAttribute(name) orelse return null;
        return fromRef(@ptrCast(v));
    }

    /// Copy a string attribute (e.g. "AXTitle"). Caller owns the result.
    pub fn copyString(self: *Element, name: []const u8) ?*String {
        const v = self.copyAttribute(name) orelse return null;
        return String.fromRef(@ptrCast(v));
    }

    pub fn position(self: *Element) ?Point {
        const v = self.copyAttribute("AXPosition") orelse return null;
        defer foundation.CFRelease(v);
        var p: Point = undefined;
        if (ax.AXValueGetValue(@ptrCast(v), .cg_point, &p) == 0) return null;
        return p;
    }

    pub fn size(self: *Element) ?Size {
        const v = self.copyAttribute("AXSize") orelse return null;
        defer foundation.CFRelease(v);
        var s: Size = undefined;
        if (ax.AXValueGetValue(@ptrCast(v), .cg_size, &s) == 0) return null;
        return s;
    }

    pub fn setPosition(self: *Element, p: Point) bool {
        var pt = p;
        const v = ax.AXValueCreate(.cg_point, &pt) orelse return false;
        defer foundation.CFRelease(v);
        return self.setAttribute("AXPosition", @ptrCast(v));
    }

    pub fn setSize(self: *Element, s: Size) bool {
        var sz = s;
        const v = ax.AXValueCreate(.cg_size, &sz) orelse return false;
        defer foundation.CFRelease(v);
        return self.setAttribute("AXSize", @ptrCast(v));
    }

    /// Move and resize the window in one call (AX top-left coordinates).
    pub fn setFrame(self: *Element, frame: Rect) bool {
        const ok_pos = self.setPosition(frame.origin);
        const ok_size = self.setSize(frame.size);
        return ok_pos and ok_size;
    }

    /// Find the AX window element matching `wid` (a CGWindowID) among this
    /// app's `AXWindows`. Returns a retained reference — caller must release.
    pub fn windowForId(self: *Element, wid: u32) ?*Element {
        const v = self.copyAttribute("AXWindows") orelse return null;
        defer foundation.CFRelease(v);
        const arr: c.CFArrayRef = @ptrCast(v);
        const n: usize = @intCast(c.CFArrayGetCount(arr));
        for (0..n) |i| {
            const elem_ref: ax.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(arr, @intCast(i)));
            var window_id: u32 = 0;
            if (ax._AXUIElementGetWindow(elem_ref, &window_id) != ax.kAXErrorSuccess) continue;
            if (window_id == wid) {
                foundation.CFRetain(elem_ref);
                return fromRef(elem_ref);
            }
        }
        return null;
    }
};
