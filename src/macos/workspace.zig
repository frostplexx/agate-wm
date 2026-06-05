//! Wrappers over AppKit's `NSWorkspace`, driven through the Objective-C
//! runtime via mitchellh/zig-objc. This is the second half of Ghostty's
//! strategy: pure-C frameworks go through `@cImport` (see `accessibility.zig`),
//! while Objective-C classes are reached with `objc_msgSend` from the `objc`
//! package.
const std = @import("std");
const objc = @import("objc");

/// Copy the localized name of the frontmost application into `buf`, returning
/// the written slice (or null if unavailable / it didn't fit).
pub fn frontmostAppName(buf: []u8) ?[]const u8 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return null;
    const shared = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const app = shared.msgSend(objc.Object, "frontmostApplication", .{});
    if (app.value == null) return null;

    const name = app.msgSend(objc.Object, "localizedName", .{}); // NSString*
    if (name.value == null) return null;

    return nsStringToBuf(name, buf);
}

/// The pid of the frontmost application, or null.
pub fn frontmostAppPid() ?i32 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return null;
    const shared = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const app = shared.msgSend(objc.Object, "frontmostApplication", .{});
    if (app.value == null) return null;
    return app.msgSend(i32, "processIdentifier", .{});
}

/// Copy an `NSString`'s UTF-8 bytes into `buf`.
fn nsStringToBuf(str: objc.Object, buf: []u8) ?[]const u8 {
    const cstr = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    const slice = std.mem.sliceTo(cstr, 0);
    if (slice.len > buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    return buf[0..slice.len];
}
