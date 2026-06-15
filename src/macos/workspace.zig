//! Wrappers over AppKit's `NSWorkspace`, driven through the Objective-C
//! runtime via mitchellh/zig-objc. This is the second half of Ghostty's
//! strategy: pure-C frameworks go through `@cImport` (see `accessibility.zig`),
//! while Objective-C classes are reached with `objc_msgSend` from the `objc`
//! package.
const std = @import("std");
const objc = @import("objc");


/// The pids of all running "regular" applications — those with a normal
/// activation policy (Dock icon, can own standard windows). Excludes
/// accessory/background agents. Caller owns the slice.
pub fn regularAppPids(alloc: std.mem.Allocator) ![]i32 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return &.{};
    const shared = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const apps = shared.msgSend(objc.Object, "runningApplications", .{}); // NSArray*
    if (apps.value == null) return &.{};

    const count = apps.msgSend(usize, "count", .{});
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(alloc);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const app = apps.msgSend(objc.Object, "objectAtIndex:", .{i});
        if (app.value == null) continue;
        // 0 == NSApplicationActivationPolicyRegular.
        if (app.msgSend(i64, "activationPolicy", .{}) != 0) continue;
        const pid = app.msgSend(i32, "processIdentifier", .{});
        if (pid > 0) try list.append(alloc, pid);
    }
    return list.toOwnedSlice(alloc);
}

/// The pid of the frontmost application, or null.
pub fn frontmostAppPid() ?i32 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return null;
    const shared = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const app = shared.msgSend(objc.Object, "frontmostApplication", .{});
    if (app.value == null) return null;
    return app.msgSend(i32, "processIdentifier", .{});
}

/// The localized name of the app with `pid`, copied into `buf`. Null if there
/// is no such running application.
pub fn appName(pid: i32, buf: []u8) ?[]const u8 {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return null;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return null;
    const name = app.msgSend(objc.Object, "localizedName", .{});
    if (name.value == null) return null;
    return nsStringToBuf(name, buf);
}

/// The bundle identifier (e.g. `"com.apple.Safari"`) of the app with `pid`,
/// copied into `buf`. Null if there is no such running application or it has no
/// bundle identifier (some processes — command-line tools, certain helpers — do
/// not).
pub fn bundleId(pid: i32, buf: []u8) ?[]const u8 {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return null;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return null;
    const bid = app.msgSend(objc.Object, "bundleIdentifier", .{}); // NSString*
    if (bid.value == null) return null;
    return nsStringToBuf(bid, buf);
}

/// Copy an `NSString`'s UTF-8 bytes into `buf`.
fn nsStringToBuf(str: objc.Object, buf: []u8) ?[]const u8 {
    const cstr = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    const slice = std.mem.sliceTo(cstr, 0);
    if (slice.len > buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    return buf[0..slice.len];
}
