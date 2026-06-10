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
    pub fn createApplication(process_id: c.pid_t) ?*Element {
        return fromRef(ax.AXUIElementCreateApplication(process_id));
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

    /// Force lazy-accessibility apps to expose their AX hierarchy (including
    /// AXWindows). Chromium/Electron/Firefox-based apps (e.g. Zen) report an
    /// empty AXWindows list until `AXManualAccessibility` is enabled. Call on
    /// the application element. The app populates its tree asynchronously, so a
    /// follow-up query may need a brief retry. We deliberately avoid
    /// `AXEnhancedUserInterface`, which can make apps reposition their windows.
    pub fn enableManualAccessibility(self: *Element) void {
        _ = self.setAttribute("AXManualAccessibility", @ptrCast(c.kCFBooleanTrue));
    }

    /// Read this application's `AXEnhancedUserInterface` flag. When true, AppKit
    /// animates AX-driven frame changes (the slow window slide). macOS enables it
    /// automatically while an assistive client — like us — is attached, so native
    /// Cocoa apps end up animating; Electron/Chromium apps ignore it. Mirrors
    /// yabai's `ax_enhanced_userinterface` (koekeishiya/yabai, src/misc/helpers.h).
    pub fn enhancedUserInterface(self: *Element) bool {
        const v = self.copyAttribute("AXEnhancedUserInterface") orelse return false;
        defer foundation.CFRelease(v);
        return c.CFBooleanGetValue(@ptrCast(v)) != 0;
    }

    pub fn setEnhancedUserInterface(self: *Element, on: bool) void {
        _ = self.setAttribute("AXEnhancedUserInterface", @ptrCast(if (on) c.kCFBooleanTrue else c.kCFBooleanFalse));
    }

    /// Set a boolean AX attribute (e.g. "AXMain", "AXFocused", "AXFrontmost").
    /// Returns true if the app accepted it.
    pub fn setBool(self: *Element, name: []const u8, on: bool) bool {
        return self.setAttribute(name, @ptrCast(if (on) c.kCFBooleanTrue else c.kCFBooleanFalse));
    }

    /// Read a boolean AX attribute (e.g. "AXEnabled"). Null if the attribute is
    /// absent. Used by the dialog heuristic to test a button's enabled state.
    pub fn getBool(self: *Element, name: []const u8) ?bool {
        const v = self.copyAttribute(name) orelse return null;
        defer foundation.CFRelease(v);
        return c.CFBooleanGetValue(@ptrCast(v)) != 0;
    }

    /// Perform a named AX action (e.g. "AXRaise"). Returns true on success.
    pub fn performAction(self: *Element, name: []const u8) bool {
        const a = String.createUtf8(name) catch return false;
        defer a.release();
        return ax.AXUIElementPerformAction(self.ref(), a.ref()) == ax.kAXErrorSuccess;
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

    /// This element's CGWindowID (for a window element), or null.
    pub fn windowId(self: *Element) ?u32 {
        var wid: u32 = 0;
        if (ax._AXUIElementGetWindow(self.ref(), &wid) != ax.kAXErrorSuccess) return null;
        return wid;
    }

    /// The pid that owns this element, or null.
    pub fn pid(self: *Element) ?c.pid_t {
        var p: c.pid_t = 0;
        if (ax.AXUIElementGetPid(self.ref(), &p) != ax.kAXErrorSuccess) return null;
        return p;
    }

    /// Retain this element (CoreFoundation +1). Pair with `release`.
    pub fn retain(self: *Element) void {
        foundation.CFRetain(self);
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

    /// Find an AX window element belonging to this app whose frame matches
    /// `frame` (within `eps`), excluding window id `exclude`. Used to locate the
    /// surviving sibling tab after the front tab of a native macOS tab group is
    /// closed: every window in a tab group shares one frame, and the window
    /// server has no tab concept (confirmed by a dyld-cache symbol search: no
    /// `CGS*`/`SLS*` tab API exists, and the AppKit `AXTabbedWindows` attribute
    /// some WMs assume does not exist on macOS 26 either), so a same-app window
    /// still sitting at the closed tab's exact frame is the tab that was just
    /// promoted to front. Returns a retained reference — caller must release.
    pub fn windowMatchingFrame(self: *Element, frame: Rect, eps: f64, exclude: u32) ?*Element {
        const v = self.copyAttribute("AXWindows") orelse return null;
        defer foundation.CFRelease(v);
        const arr: c.CFArrayRef = @ptrCast(v);
        const n: usize = @intCast(c.CFArrayGetCount(arr));
        for (0..n) |i| {
            const elem_ref: ax.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(arr, @intCast(i)));
            var window_id: u32 = 0;
            if (ax._AXUIElementGetWindow(elem_ref, &window_id) != ax.kAXErrorSuccess) continue;
            if (window_id == exclude) continue;
            const elem = fromRef(elem_ref) orelse continue;
            const pos = elem.position() orelse continue;
            const sz = elem.size() orelse continue;
            if (@abs(pos.x - frame.origin.x) < eps and
                @abs(pos.y - frame.origin.y) < eps and
                @abs(sz.width - frame.size.width) < eps and
                @abs(sz.height - frame.size.height) < eps)
            {
                foundation.CFRetain(elem_ref);
                return elem;
            }
        }
        return null;
    }
};

/// Token magic used by `_AXUIElementCreateWithRemoteToken` (ASCII "coco").
const remote_token_magic: u32 = 0x636f636f;
/// Upper bound on the per-application AX element id scan (matches yabai).
const remote_token_scan_limit: u64 = 0x7fff;

/// Resolve the AX window element for `wid` belonging to `pid`, even when the
/// window is on an inactive Space and therefore absent from the app's
/// `AXWindows` list. Mirrors yabai (koekeishiya/yabai, src/window_manager.c):
/// build a 20-byte remote token of {pid, magic, element_id} and scan element
/// ids, fabricating AX elements via `_AXUIElementCreateWithRemoteToken` until
/// one resolves to the target CGWindowID. Returns a retained element (caller
/// releases) or null.
pub fn windowForIdViaRemoteToken(pid: c.pid_t, wid: u32) ?*Element {
    const data = c.CFDataCreateMutable(null, 0x14) orelse return null;
    defer foundation.CFRelease(data);
    c.CFDataIncreaseLength(data, 0x14);

    const buf: [*]u8 = @ptrCast(c.CFDataGetMutableBytePtr(data));
    @memset(buf[0..0x14], 0);
    std.mem.writeInt(u32, buf[0..4], @intCast(pid), .little);
    std.mem.writeInt(u32, buf[8..12], remote_token_magic, .little);

    var element_id: u64 = 0;
    while (element_id < remote_token_scan_limit) : (element_id += 1) {
        std.mem.writeInt(u64, buf[0xc..0x14], element_id, .little);
        const elem_ref = ax._AXUIElementCreateWithRemoteToken(@ptrCast(data)) orelse continue;
        const elem = Element.fromRef(elem_ref) orelse continue;
        var got: u32 = 0;
        if (ax._AXUIElementGetWindow(elem_ref, &got) == ax.kAXErrorSuccess and got == wid) {
            return elem; // already owned (created), hand off to caller
        }
        elem.release();
    }
    return null;
}
