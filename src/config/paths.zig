//! init.lua discovery — shared by the config loader (`lua.init`) and the CLI
//! (`agate config` / `agate config-show`), which resolves the path without
//! booting the Lua VM.
const std = @import("std");

// `std.Io.Dir.access` needs the `Io` handle from main; plain `access(2)` is
// enough for an existence probe and keeps this layer Io-free.
pub fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0; // F_OK = 0
}

/// The init.lua agate will load, searched in priority order, or null if none
/// exists. Caller owns the returned slice.
pub fn findConfigPath(alloc: std.mem.Allocator) ?[]u8 {
    // 1. $WM_CONFIG
    if (std.c.getenv("WM_CONFIG")) |raw| {
        const s = std.mem.span(raw);
        if (fileExists(s)) return alloc.dupe(u8, s) catch null;
    }
    // 2. $XDG_CONFIG_HOME/agate/init.lua
    if (std.c.getenv("XDG_CONFIG_HOME")) |raw| {
        const base = std.mem.span(raw);
        const p = std.fmt.allocPrint(alloc, "{s}/agate/init.lua", .{base}) catch return null;
        if (fileExists(p)) return p;
        alloc.free(p);
    }
    // 3. ~/.config/agate/init.lua
    if (std.c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        const p = std.fmt.allocPrint(alloc, "{s}/.config/agate/init.lua", .{home}) catch return null;
        if (fileExists(p)) return p;
        alloc.free(p);
    }
    // 4. ./init.lua (development fallback)
    const p = alloc.dupe(u8, "init.lua") catch return null;
    if (fileExists(p)) return p;
    alloc.free(p);
    return null;
}
