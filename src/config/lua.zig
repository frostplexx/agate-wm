//! Lua configuration layer: loads `init.lua`, registers the `agate.*` Lua API,
//! and manages keybindings. Each `agate.bind(keyspec, fn)` call stores a
//! Lua function reference that is invoked from the keyboard event tap whenever
//! the matching key combination is pressed.
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const macos = @import("macos");
const state = @import("../state.zig");
const focus = @import("../wm/focus/focus.zig");
const tree = @import("../wm/tree.zig");
const data = @import("../wm/data.zig");

// CGEventFlag modifier bits.
pub const MOD_SHIFT: u64 = 0x0002_0000;
pub const MOD_CTRL: u64 = 0x0004_0000;
pub const MOD_ALT: u64 = 0x0008_0000;
pub const MOD_CMD: u64 = 0x0010_0000;
pub const MOD_MASK: u64 = MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_CMD;

pub const BindingAction = union(enum) {
    lua_fn: i32,     // Lua registry reference; call with protectedCall
    cmd: []const u8, // pre-parsed string command, owned by Config.alloc
};

pub const Binding = struct {
    keycode: u16,
    modifiers: u64,
    action: BindingAction,
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    gaps: f64,
    outer_gaps: f64,
    /// CGEventFlag mask for the "hyper" macro key.
    hyper_mods: u64,
    /// Virtual keycode of a physical key whose held state means "hyper". Needed
    /// when a remapper (lazykeys, Karabiner) turns e.g. Caps Lock into F18 and
    /// applies the real modifiers downstream of our event tap, where we can't see
    /// them: we instead watch this key go down/up and synthesize `hyper_mods`.
    /// Default 79 = kVK_F18. 0 disables the feature.
    hyper_key: u16,
    bindings: std.ArrayList(Binding),
    lua: *Lua,
};

var g_config: ?*Config = null;
var g_appstate: ?*state.AppState = null;

// ---------------------------------------------------------------------------
// Mac Virtual Key Codes (kVK_* from HIToolbox/Events.h)
// ---------------------------------------------------------------------------

const KeyEntry = struct { name: []const u8, code: u16 };
const key_table = [_]KeyEntry{
    .{ .name = "a", .code = 0 },    .{ .name = "s", .code = 1 },
    .{ .name = "d", .code = 2 },    .{ .name = "f", .code = 3 },
    .{ .name = "h", .code = 4 },    .{ .name = "g", .code = 5 },
    .{ .name = "z", .code = 6 },    .{ .name = "x", .code = 7 },
    .{ .name = "c", .code = 8 },    .{ .name = "v", .code = 9 },
    .{ .name = "b", .code = 11 },   .{ .name = "q", .code = 12 },
    .{ .name = "w", .code = 13 },   .{ .name = "e", .code = 14 },
    .{ .name = "r", .code = 15 },   .{ .name = "y", .code = 16 },
    .{ .name = "t", .code = 17 },   .{ .name = "1", .code = 18 },
    .{ .name = "2", .code = 19 },   .{ .name = "3", .code = 20 },
    .{ .name = "4", .code = 21 },   .{ .name = "6", .code = 22 },
    .{ .name = "5", .code = 23 },   .{ .name = "equal", .code = 24 },
    .{ .name = "9", .code = 25 },   .{ .name = "7", .code = 26 },
    .{ .name = "minus", .code = 27 }, .{ .name = "8", .code = 28 },
    .{ .name = "0", .code = 29 },   .{ .name = "o", .code = 31 },
    .{ .name = "u", .code = 32 },   .{ .name = "i", .code = 34 },
    .{ .name = "p", .code = 35 },   .{ .name = "return", .code = 36 },
    .{ .name = "l", .code = 37 },   .{ .name = "j", .code = 38 },
    .{ .name = "k", .code = 40 },   .{ .name = "n", .code = 45 },
    .{ .name = "m", .code = 46 },   .{ .name = "tab", .code = 48 },
    .{ .name = "space", .code = 49 }, .{ .name = "grave", .code = 50 },
    .{ .name = "delete", .code = 51 }, .{ .name = "escape", .code = 53 },
    .{ .name = "left", .code = 123 }, .{ .name = "right", .code = 124 },
    .{ .name = "down", .code = 125 }, .{ .name = "up", .code = 126 },
    // Function keys commonly used as a remapped "hyper" trigger.
    .{ .name = "f13", .code = 105 }, .{ .name = "f14", .code = 107 },
    .{ .name = "f15", .code = 113 }, .{ .name = "f16", .code = 106 },
    .{ .name = "f17", .code = 64 },  .{ .name = "f18", .code = 79 },
    .{ .name = "f19", .code = 80 },  .{ .name = "f20", .code = 90 },
};

fn lookupKeycode(name: []const u8) ?u16 {
    for (key_table) |e| if (std.mem.eql(u8, e.name, name)) return e.code;
    return null;
}

/// Parse a keyspec like `"hyper+shift+h"` into a modifiers bitmask and
/// virtual keycode. The last `+`-separated token that isn't a modifier name
/// is treated as the key. Returns null if the key name is not recognised.
fn parseKeySpec(spec: []const u8, hyper_mods: u64) ?struct { mods: u64, keycode: u16 } {
    var mods: u64 = 0;
    var key: []const u8 = "";
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control")) {
            mods |= MOD_CTRL;
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "opt") or std.mem.eql(u8, part, "option")) {
            mods |= MOD_ALT;
        } else if (std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "command")) {
            mods |= MOD_CMD;
        } else if (std.mem.eql(u8, part, "shift")) {
            mods |= MOD_SHIFT;
        } else if (std.mem.eql(u8, part, "hyper")) {
            mods |= hyper_mods;
        } else {
            key = part;
        }
    }
    const code = lookupKeycode(key) orelse return null;
    return .{ .mods = mods, .keycode = code };
}

// ---------------------------------------------------------------------------
// Lua C functions exposed as the `agate` global table
// ---------------------------------------------------------------------------

fn agateConfig(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    if (!lua.isTable(1)) return 0;
    // gaps
    _ = lua.getField(1, "gaps");
    if (lua.isNumber(-1)) cfg.gaps = lua.toNumber(-1) catch cfg.gaps;
    lua.pop(1);
    // outer_gaps
    _ = lua.getField(1, "outer_gaps");
    if (lua.isNumber(-1)) cfg.outer_gaps = lua.toNumber(-1) catch cfg.outer_gaps;
    lua.pop(1);
    // hyper: array of modifier strings {"ctrl","alt","cmd","shift"}
    _ = lua.getField(1, "hyper");
    if (lua.isTable(-1)) {
        cfg.hyper_mods = 0;
        var i: zlua.Integer = 1;
        while (true) {
            _ = lua.getIndex(-1, i);
            if (lua.isNil(-1)) { lua.pop(1); break; }
            if (lua.isString(-1)) {
                const s = lua.toString(-1) catch "";
                if (std.mem.eql(u8, s, "ctrl") or std.mem.eql(u8, s, "control")) cfg.hyper_mods |= MOD_CTRL;
                if (std.mem.eql(u8, s, "alt") or std.mem.eql(u8, s, "opt")) cfg.hyper_mods |= MOD_ALT;
                if (std.mem.eql(u8, s, "cmd") or std.mem.eql(u8, s, "command")) cfg.hyper_mods |= MOD_CMD;
                if (std.mem.eql(u8, s, "shift")) cfg.hyper_mods |= MOD_SHIFT;
            }
            lua.pop(1);
            i += 1;
        }
    }
    lua.pop(1);
    // hyper_key: name of the physical key whose held state means "hyper" (for
    // remappers that hide the real modifiers from our tap). e.g. "f18".
    _ = lua.getField(1, "hyper_key");
    if (lua.isString(-1)) {
        const s = lua.toString(-1) catch "";
        if (lookupKeycode(std.mem.sliceTo(s, 0))) |code| cfg.hyper_key = code;
    }
    lua.pop(1);
    // Apply gaps to every workspace in the tree
    if (g_appstate) |app| if (app.tree) |root| applyGapsToTree(root, cfg.gaps, cfg.outer_gaps);
    return 0;
}

fn applyGapsToTree(con: *data.Con, gaps: f64, outer_gaps: f64) void {
    if (con.con_type == .Workspace) {
        con.gaps = .{
            .inner = @intFromFloat(@max(0, gaps)),
            .outer = @intFromFloat(@max(0, outer_gaps)),
            .top = 0, .bottom = 0, .left = 0, .right = 0,
        };
    }
    for (con.children.items) |child| applyGapsToTree(child, gaps, outer_gaps);
}

fn agateBind(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    const spec_z = lua.toString(1) catch return 0;
    const spec = std.mem.sliceTo(spec_z, 0);

    const parsed = parseKeySpec(spec, cfg.hyper_mods) orelse {
        std.debug.print("[config] unknown key: {s}\n", .{spec});
        return 0;
    };

    if (lua.isFunction(2)) {
        lua.pushValue(2);
        const fn_ref = lua.ref(zlua.registry_index);
        cfg.bindings.append(cfg.alloc, .{
            .keycode = parsed.keycode,
            .modifiers = parsed.mods,
            .action = .{ .lua_fn = fn_ref },
        }) catch {};
    } else if (lua.isString(2)) {
        const cmd_z = lua.toString(2) catch return 0;
        const cmd = cfg.alloc.dupe(u8, std.mem.sliceTo(cmd_z, 0)) catch return 0;
        cfg.bindings.append(cfg.alloc, .{
            .keycode = parsed.keycode,
            .modifiers = parsed.mods,
            .action = .{ .cmd = cmd },
        }) catch { cfg.alloc.free(cmd); };
    }
    return 0;
}

fn agateFocus(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    _ = focus.focusDirection(app, dir);
    return 0;
}

fn agateLayout(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    const name = std.mem.sliceTo(name_z, 0);
    const layout: data.layouts = if (std.mem.eql(u8, name, "h_tiles") or std.mem.eql(u8, name, "h_split"))
        .H_SPLIT
    else if (std.mem.eql(u8, name, "v_tiles") or std.mem.eql(u8, name, "v_split"))
        .V_SPLIT
    else return 0;
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return 0;
    const ws = tree.findWorkspace(app.tree orelse return 0, sid) orelse return 0;
    ws.layout = layout;
    tree.flushActive(app);
    return 0;
}

fn agateSpace(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    macos.spaces.switchToIndex(app.gpa, app.skylight_cid, @intCast(n)) catch {};
    return 0;
}

fn agateSpaceNext(lua: *Lua) i32 {
    _ = lua;
    const app = g_appstate orelse return 0;
    macos.spaces.switchNext(app.gpa, app.skylight_cid) catch {};
    return 0;
}

fn agateSpacePrev(lua: *Lua) i32 {
    _ = lua;
    const app = g_appstate orelse return 0;
    macos.spaces.switchPrev(app.gpa, app.skylight_cid) catch {};
    return 0;
}

fn agateResize(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const amount = lua.toNumber(2) catch 50.0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const grow = dir == .right or dir == .down;
    if (tree.resizeLeaf(leaf, grow, @floatCast(amount))) tree.flushActive(app);
    return 0;
}

fn agateMove(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.swapLeaf(leaf, forward)) tree.flushActive(app);
    return 0;
}

const agate_fns = [_]zlua.FnReg{
    .{ .name = "config",      .func = zlua.wrap(agateConfig) },
    .{ .name = "bind",        .func = zlua.wrap(agateBind) },
    .{ .name = "focus",       .func = zlua.wrap(agateFocus) },
    .{ .name = "layout",      .func = zlua.wrap(agateLayout) },
    .{ .name = "space",       .func = zlua.wrap(agateSpace) },
    .{ .name = "space_next",  .func = zlua.wrap(agateSpaceNext) },
    .{ .name = "space_prev",  .func = zlua.wrap(agateSpacePrev) },
    .{ .name = "resize",      .func = zlua.wrap(agateResize) },
    .{ .name = "move",        .func = zlua.wrap(agateMove) },
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn init(gpa: std.mem.Allocator, app: *state.AppState) !*Config {
    g_appstate = app;

    const cfg = try gpa.create(Config);
    cfg.* = .{
        .alloc = gpa,
        .gaps = 8,
        .outer_gaps = 8,
        .hyper_mods = MOD_CTRL | MOD_ALT | MOD_CMD | MOD_SHIFT,
        .hyper_key = 79, // kVK_F18 — common remapped-hyper trigger
        .bindings = .empty,
        .lua = try Lua.init(gpa),
    };
    g_config = cfg;

    cfg.lua.openLibs();
    cfg.lua.newLib(&agate_fns);
    cfg.lua.setGlobal("agate");

    const config_path = findConfigPath(gpa) orelse {
        std.debug.print("[config] no init.lua found; using defaults\n", .{});
        return cfg;
    };
    defer gpa.free(config_path);

    const path_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{config_path}, 0);
    defer gpa.free(path_z);

    cfg.lua.doFile(path_z) catch {
        const msg = cfg.lua.toString(-1) catch "unknown error";
        std.debug.print("[config] error in {s}: {s}\n", .{ config_path, msg });
        cfg.lua.pop(1);
    };

    return cfg;
}

pub fn deinit(cfg: *Config) void {
    for (cfg.bindings.items) |b| {
        switch (b.action) {
            .lua_fn => |r| cfg.lua.unref(zlua.registry_index, r),
            .cmd => |s| cfg.alloc.free(s),
        }
    }
    cfg.bindings.deinit(cfg.alloc);
    cfg.lua.deinit();
    cfg.alloc.destroy(cfg);
    g_config = null;
    g_appstate = null;
}

/// The CGEventFlag bits to synthesize when the hyper key is held (see
/// `Config.hyper_key`). Used by the event tap to fake the modifiers a remapper
/// hides from it.
pub fn hyperMods() u64 {
    const cfg = g_config orelse return 0;
    return cfg.hyper_mods;
}

/// The virtual keycode whose held state means "hyper" (0 = feature disabled).
pub fn hyperKey() u16 {
    const cfg = g_config orelse return 0;
    return cfg.hyper_key;
}

/// Cheap test: does any registered binding match this chord? Called from inside
/// the keyboard event tap to decide whether to swallow the keystroke, without
/// running the (slow) action — the action runs deferred via `handleKey`.
pub fn matchBinding(keycode: u16, raw_flags: u64) bool {
    const cfg = g_config orelse return false;
    const mods = raw_flags & MOD_MASK;
    for (cfg.bindings.items) |b| {
        if (b.keycode == keycode and b.modifiers == mods) return true;
    }
    return false;
}

/// Dispatch a key event against registered bindings. Returns true if the
/// event was handled and should be swallowed. Call from the keyboard event tap.
pub fn handleKey(keycode: u16, raw_flags: u64) bool {
    const cfg = g_config orelse return false;
    const mods = raw_flags & MOD_MASK;
    for (cfg.bindings.items) |b| {
        if (b.keycode != keycode or b.modifiers != mods) continue;
        switch (b.action) {
            .lua_fn => |r| {
                _ = cfg.lua.getIndexRaw(zlua.registry_index, r);
                cfg.lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
                    std.debug.print("[config] keybinding error: {}\n", .{err});
                };
            },
            .cmd => |cmd| executeCommand(cmd),
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn parseDir(s: []const u8) ?focus.Direction {
    if (std.mem.eql(u8, s, "left"))  return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up"))    return .up;
    if (std.mem.eql(u8, s, "down"))  return .down;
    return null;
}

fn executeCommand(cmd: []const u8) void {
    const app = g_appstate orelse return;
    if (std.mem.startsWith(u8, cmd, "move ")) {
        const dir = parseDir(cmd[5..]) orelse return;
        const leaf = focus.currentFocusedLeaf(app) orelse return;
        const forward = dir == .right or dir == .down;
        if (tree.swapLeaf(leaf, forward)) tree.flushActive(app);
    } else if (std.mem.startsWith(u8, cmd, "focus ")) {
        const dir = parseDir(cmd[6..]) orelse return;
        _ = focus.focusDirection(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "layout ")) {
        const name = cmd[7..];
        const layout: data.layouts = if (std.mem.eql(u8, name, "h_tiles") or std.mem.eql(u8, name, "h_split"))
            .H_SPLIT
        else if (std.mem.eql(u8, name, "v_tiles") or std.mem.eql(u8, name, "v_split"))
            .V_SPLIT
        else return;
        const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
        const ws = tree.findWorkspace(app.tree orelse return, sid) orelse return;
        ws.layout = layout;
        tree.flushActive(app);
    } else if (std.mem.startsWith(u8, cmd, "space ")) {
        const n = std.fmt.parseInt(usize, cmd[6..], 10) catch return;
        macos.spaces.switchToIndex(app.gpa, app.skylight_cid, n) catch {};
    }
}

fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0; // F_OK = 0
}

fn findConfigPath(alloc: std.mem.Allocator) ?[]u8 {
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
