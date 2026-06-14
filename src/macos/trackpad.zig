//! Detect (read-only) whether the native 4-finger horizontal swipe ("Swipe
//! between full-screen applications") is still enabled and, if so, warn the user
//! to turn it off so it doesn't fight agate's own 4-finger Space switch.
//!
//! macOS recognizes that swipe in the window server, ahead of any CGEventTap, so
//! it can't be swallowed at runtime — and writing the trackpad preference +
//! reloading input settings ourselves proved disruptive. So we only *read* the
//! preference here and leave the toggle to the user.
const std = @import("std");
const c = @import("c.zig").c;
const foundation = @import("foundation.zig");
const String = foundation.String;

/// Per-host preference key for the 4-finger horizontal swipe (0 = off, 2 = on).
const pref_key = "TrackpadFourFingerHorizSwipeGesture";

/// Both trackpad domains: the built-in/USB Multitouch driver and the Bluetooth
/// Magic Trackpad. Either being on is enough to conflict.
const domains = [_][]const u8{
    "com.apple.AppleMultitouchTrackpad",
    "com.apple.driver.AppleBluetoothMultitouch.trackpad",
};

// CFPreferences at the ByHost scope (current user + current host), where the
// multitouch driver stores these keys. Read-only use.
extern "c" fn CFPreferencesCopyValue(key: c.CFStringRef, appID: c.CFStringRef, userName: c.CFStringRef, hostName: c.CFStringRef) ?*const anyopaque;
extern "c" const kCFPreferencesCurrentUser: c.CFStringRef;
extern "c" const kCFPreferencesCurrentHost: c.CFStringRef;

/// The pref value for `domain`, or null if the key is absent / not a number.
fn readValue(domain: []const u8, key_ref: c.CFStringRef) ?i32 {
    const dref = String.createUtf8(domain) catch return null;
    defer dref.release();
    const v = CFPreferencesCopyValue(key_ref, dref.ref(), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) orelse return null;
    defer foundation.CFRelease(v);
    var out: i32 = 0;
    if (c.CFNumberGetValue(@ptrCast(v), c.kCFNumberSInt32Type, &out) != 0) return out;
    return null;
}

/// If the native 4-finger swipe is (or might be) on, print a one-line warning
/// telling the user to disable it. Quiet only when both domains explicitly say
/// off — an absent key is treated as possibly-on, since the default varies.
pub fn warnIfNativeSwipeEnabled() void {
    const key = String.createUtf8(pref_key) catch return;
    defer key.release();

    var explicitly_off = true;
    for (domains) |dom| {
        if (readValue(dom, key.ref())) |val| {
            if (val != 0) explicitly_off = false;
        } else {
            explicitly_off = false; // absent: default is on, can't assume off
        }
    }
    if (explicitly_off) return;

    std.debug.print(
        \\[trackpad] The native macOS 4-finger swipe is enabled and will fight agate's
        \\           4-finger Space switch. Disable it in System Settings > Trackpad >
        \\           More Gestures > "Swipe between full-screen applications" (set it to
        \\           Off, or to three fingers).
        \\
    , .{});
}
