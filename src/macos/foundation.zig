//! Idiomatic wrappers over the CoreFoundation types agate uses. Follows the
//! Ghostty pattern: `opaque` handles with methods, conversions done with
//! `@ptrCast`/`@intCast` against the raw `c` decls, ownership made explicit
//! through `release`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub fn CFRelease(ref: ?*const anyopaque) void {
    c.CFRelease(ref);
}

/// Read a `CFNumber` dictionary value as an i64. Returns null if absent or not
/// a number. Shared by the CoreGraphics and SkyLight enumeration paths.
pub fn dictI64(dict: c.CFDictionaryRef, key: c.CFStringRef) ?i64 {
    const v = c.CFDictionaryGetValue(dict, key) orelse return null;
    var out: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(v), c.kCFNumberSInt64Type, &out) == 0) return null;
    return out;
}

pub fn CFRetain(ref: ?*const anyopaque) void {
    _ = c.CFRetain(ref);
}

/// A CoreFoundation string (`CFStringRef`). Toll-free bridged with `NSString`.
pub const String = opaque {
    /// Wrap a raw `CFStringRef`. Returns null if the ref is null.
    pub fn fromRef(r: c.CFStringRef) ?*String {
        return @ptrCast(@constCast(r));
    }

    pub fn ref(self: *String) c.CFStringRef {
        return @ptrCast(self);
    }

    /// Create a CFString from a UTF-8 slice. Caller owns the result and must
    /// call `release`.
    pub fn createUtf8(bytes: []const u8) Allocator.Error!*String {
        const r = c.CFStringCreateWithBytes(
            null,
            bytes.ptr,
            @intCast(bytes.len),
            c.kCFStringEncodingUTF8,
            0,
        );
        return fromRef(r) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *String) void {
        CFRelease(self);
    }

    pub fn length(self: *String) usize {
        return @intCast(c.CFStringGetLength(self.ref()));
    }

    /// Copy the string into `buf` as UTF-8. Returns the written slice, or null
    /// if it didn't fit / couldn't be encoded.
    pub fn cstring(self: *String, buf: []u8) ?[]const u8 {
        if (c.CFStringGetCString(
            self.ref(),
            buf.ptr,
            @intCast(buf.len),
            c.kCFStringEncodingUTF8,
        ) == 0) return null;
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf.ptr)), 0);
    }

    /// Allocate the UTF-8 contents using `alloc`. Caller owns the returned
    /// slice.
    pub fn toOwnedUtf8(self: *String, alloc: Allocator) Allocator.Error![]u8 {
        // Worst case 4 UTF-8 bytes per UTF-16 unit, plus a NUL.
        const cap = self.length() * 4 + 1;
        const buf = try alloc.alloc(u8, cap);
        errdefer alloc.free(buf);
        const slice = self.cstring(buf) orelse return Allocator.Error.OutOfMemory;
        return try alloc.realloc(buf, slice.len);
    }
};
