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
const regexp = @import("../lib/regexp.zig");

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

/// A window assignment rule (`agate.rule{...}`), modelled on yabai's rules
/// (koekeishiya/yabai, src/rule.c): regexes select windows, the effect sends
/// them to a Space. Matching is AND across the present matchers; a rule with
/// neither matcher is rejected at registration.
pub const Rule = struct {
    /// Matches the owning application's name (POSIX extended regex).
    app: ?regexp.Regex = null,
    /// Matches the window title (POSIX extended regex).
    title: ?regexp.Regex = null,
    /// 1-based user-space index to send matched windows to (0 = unset/invalid).
    space: usize = 0,
    /// Switch to the Space the window was sent to (the default: opening an
    /// assigned app takes the user along). `follow = false` routes the window
    /// in the background instead.
    follow: bool = true,
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    gaps: f64,
    outer_gaps: f64,
    /// Accordion/stack peek inset (px): how far each stacked window is fanned
    /// past the one in front. See `data.gaps.accordion`.
    accordion_padding: f64,
    /// CGEventFlag mask for the "hyper" macro key.
    hyper_mods: u64,
    /// Virtual keycode of a physical key whose held state means "hyper". Needed
    /// when a remapper (lazykeys, Karabiner) turns e.g. Caps Lock into F18 and
    /// applies the real modifiers downstream of our event tap, where we can't see
    /// them: we instead watch this key go down/up and synthesize `hyper_mods`.
    /// Default 79 = kVK_F18. 0 disables the feature.
    hyper_key: u16,
    bindings: std.ArrayList(Binding),
    /// Window assignment rules in registration order. All matching rules
    /// combine; the last match wins (yabai's `rule_combine_effects` order).
    rules: std.ArrayList(Rule),
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

/// Read the numeric field `name` from the config table (stack index 1) into
/// `dst`. Returns whether the field was present and numeric; `dst` is left
/// unchanged otherwise.
fn numberField(lua: *Lua, name: [:0]const u8, dst: *f64) bool {
    _ = lua.getField(1, name);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) return false;
    dst.* = lua.toNumber(-1) catch return false;
    return true;
}

fn agateConfig(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    if (!lua.isTable(1)) return 0;
    _ = numberField(lua, "gaps", &cfg.gaps);
    _ = numberField(lua, "outer_gaps", &cfg.outer_gaps);
    // accept "accordion_padding" or the shorter "accordion"
    if (!numberField(lua, "accordion_padding", &cfg.accordion_padding))
        _ = numberField(lua, "accordion", &cfg.accordion_padding);
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
    if (g_appstate) |app| if (app.tree) |root| applyGapsToTree(root, cfg.gaps, cfg.outer_gaps, cfg.accordion_padding);
    return 0;
}

fn applyGapsToTree(con: *data.Con, gaps: f64, outer_gaps: f64, accordion: f64) void {
    // Workspaces and nested split containers (a Container with no window) carry
    // the gaps the layout reads; leaf cons (Container with a window) don't.
    if (con.con_type == .Workspace or (con.con_type == .Container and con.window == null)) {
        con.gaps = .{
            .inner = @intFromFloat(@max(0, gaps)),
            .outer = @intFromFloat(@max(0, outer_gaps)),
            .top = 0, .bottom = 0, .left = 0, .right = 0,
            .accordion = @intFromFloat(@max(0, accordion)),
        };
    }
    for (con.children.items) |child| applyGapsToTree(child, gaps, outer_gaps, accordion);
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
    setActiveLayout(app, std.mem.sliceTo(name_z, 0));
    return 0;
}

/// Map a layout name to a tiling mode. Accepts AeroSpace-ish synonyms.
/// "toggle" is handled by `setActiveLayout` (it needs the current layout).
fn layoutFromName(name: []const u8) ?data.Layout {
    const eql = std.mem.eql;
    if (eql(u8, name, "h_tiles") or eql(u8, name, "h_split") or eql(u8, name, "horizontal")) return .H_SPLIT;
    if (eql(u8, name, "v_tiles") or eql(u8, name, "v_split") or eql(u8, name, "vertical")) return .V_SPLIT;
    if (eql(u8, name, "h_stack") or eql(u8, name, "h_accordion")) return .H_STACK;
    if (eql(u8, name, "v_stack") or eql(u8, name, "v_accordion") or
        eql(u8, name, "accordion") or eql(u8, name, "stacking") or eql(u8, name, "stacked")) return .V_STACK;
    if (eql(u8, name, "float") or eql(u8, name, "floating")) return .FLOAT;
    return null;
}

/// Set a layout by name and re-tile. Targets the *focused container* (the
/// focused leaf's parent) so a nested sub-container can be restyled on its own —
/// e.g. flip just the left stack to a split — falling back to the workspace when
/// focus can't be resolved. "toggle" flips the split orientation (H_SPLIT ↔
/// V_SPLIT); anything else maps via `layoutFromName`.
fn setActiveLayout(app: *state.AppState, name: []const u8) void {
    const sid = macos.spaces.activeSpace(app.skylight_cid) orelse return;
    const ws = tree.findWorkspace(app.tree orelse return, sid) orelse return;
    const target = if (focus.currentFocusedLeaf(app)) |leaf| (leaf.parent orelse ws) else ws;
    if (std.mem.eql(u8, name, "toggle")) {
        target.layout = switch (target.layout) {
            .H_SPLIT => .V_SPLIT,
            .V_SPLIT => .H_SPLIT,
            else => .H_SPLIT, // from a stack/float, toggle returns to horizontal tiling
        };
    } else {
        target.layout = layoutFromName(name) orelse return;
    }
    tree.flushActive(app);
}

/// Combine the focused window with an adjacent one into a nested container,
/// giving the workspace a mixed layout. `agate.join(dir [, layout])`: `dir` is
/// the neighbour to absorb ("left"/"right"/"up"/"down"); `layout` is the new
/// container's mode (default "v_stack" — a vertical stack).
fn agateJoin(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    var layout: data.Layout = .V_STACK;
    if (lua.isString(2)) {
        const lz = lua.toString(2) catch "";
        if (layoutFromName(std.mem.sliceTo(lz, 0))) |l| layout = l;
    }
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.joinWithNeighbor(app.arena, leaf, forward, layout)) |_| {
        tree.flushActive(app);
        _ = focus.focusLeaf(leaf); // keep the joined window focused and raised
    }
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

fn agateMoveToSpace(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    moveFocusedToSpace(app, @intCast(n));
    return 0;
}

/// Move the focused window to the Nth user space on the focused display via
/// the SkyLight reassignment SPI, then sync our tree by relocating the leaf
/// into the destination workspace and relaying out the (now-shrunk) source.
/// No-op when the window is already on the target space.
fn moveFocusedToSpace(app: *state.AppState, n: usize) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    const win = if (leaf.window) |w| w else return;
    const cur_ws = leaf.parent orelse return; // Workspace Con; .id == SkyLight sid
    const target_sid = (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, n) catch return) orelse return;
    if (target_sid == cur_ws.id) return; // already there — don't issue the SPI
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    // The tree's children lists are arena-allocated — growing them with any
    // other allocator would free arena memory through it (undefined behavior).
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
    tree.flushActive(app); // re-tile the source we just shrank
    tree.flushWorkspace(dst_ws); // and slot the moved window into the destination's row

    // Keep the moved window selected once its Space is shown (yabai-style): the
    // space-change handler blanket-focuses a tile to pull the menu bar over, so
    // arm a pending focus on this window for the destination Space instead.
    app.pending_focus = .{ .wid = win.id, .sid = target_sid };
}

/// `agate.rule{ app = "...", title = "...", space = N, follow = bool }`
/// Register a window assignment rule (yabai's `yabai -m rule --add app=...
/// space=N`). `app`/`title` are POSIX extended regexes; at least one must be
/// given. Matched windows are sent to user space N when they appear.
fn agateRule(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    if (!lua.isTable(1)) return 0;

    var rule = Rule{};

    _ = lua.getField(1, "space");
    if (lua.isNumber(-1)) {
        const n = lua.toInteger(-1) catch 0;
        if (n >= 1) rule.space = @intCast(n);
    }
    lua.pop(1);

    _ = lua.getField(1, "follow");
    if (lua.isBoolean(-1)) rule.follow = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(1, "app");
    if (lua.isString(-1)) {
        const pat = lua.toString(-1) catch "";
        rule.app = regexp.Regex.init(pat) catch blk: {
            std.debug.print("[config] rule: bad app regex: {s}\n", .{pat});
            break :blk null;
        };
    }
    lua.pop(1);

    _ = lua.getField(1, "title");
    if (lua.isString(-1)) {
        const pat = lua.toString(-1) catch "";
        rule.title = regexp.Regex.init(pat) catch blk: {
            std.debug.print("[config] rule: bad title regex: {s}\n", .{pat});
            break :blk null;
        };
    }
    lua.pop(1);

    if (rule.space == 0 or (rule.app == null and rule.title == null)) {
        std.debug.print("[config] rule needs a space >= 1 and an app or title matcher; ignored\n", .{});
        freeRule(rule);
        return 0;
    }
    cfg.rules.append(cfg.alloc, rule) catch freeRule(rule);
    return 0;
}

fn freeRule(rule: Rule) void {
    if (rule.app) |re| re.deinit();
    if (rule.title) |re| re.deinit();
}

/// Match `re` against a non-sentinel slice by copying it into a stack buffer
/// with a NUL (regexec wants a C string). Over-long input is truncated, which
/// can only affect `$`-anchored patterns on pathological titles.
fn regexMatches(re: regexp.Regex, s: []const u8) bool {
    var buf: [512]u8 = undefined;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return re.matches(buf[0..len :0]);
}

/// The combined effect of every rule matching this window, or null if none
/// does. Later rules override earlier ones, like yabai's effect combining.
fn matchRules(app_name: []const u8, title: []const u8) ?struct { space: usize, follow: bool } {
    const cfg = g_config orelse return null;
    var space: usize = 0;
    var follow = false;
    for (cfg.rules.items) |r| {
        if (r.app) |re| {
            if (!regexMatches(re, app_name)) continue;
        }
        if (r.title) |re| {
            if (!regexMatches(re, title)) continue;
        }
        space = r.space;
        follow = r.follow;
    }
    if (space == 0) return null;
    return .{ .space = space, .follow = follow };
}

/// Apply assignment rules to a freshly tracked window: if a rule matches, send
/// the window to the rule's Space (same SPI path as `moveFocusedToSpace`) and
/// relocate its leaf into the destination workspace. The caller is expected to
/// re-flush the source workspace afterwards (the observer's create paths always
/// do). `title` is the window's AX title at detection time.
pub fn applyRulesToLeaf(app: *state.AppState, leaf: *data.Con, title: []const u8) void {
    const win = if (leaf.window) |w| w else return;
    const eff = matchRules(win.owner, title) orelse return;
    const cur_ws = leaf.parent orelse return; // new leaves sit directly under their Workspace
    const target_sid = (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, eff.space) catch return) orelse return;
    if (target_sid == cur_ws.id) return; // already on the assigned space
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws); // arena: see moveFocusedToSpace
    tree.flushWorkspace(dst_ws);
    std.debug.print("[rule] {s} #{d} -> space {d}\n", .{ win.owner, win.id, eff.space });
    // Mute activation-follow for this window either way: the app activates
    // around its own launch, and the follow chasing the window we just routed
    // would switch the user a second time (racing the gesture below and able to
    // overshoot) — or, for a follow-less rule, switch them against its intent.
    app.rule_moved = .{ .wid = win.id, .at = macos.c.CFAbsoluteTimeGetCurrent() };
    if (eff.follow) {
        // The window is already moved and tiled (flushed above), so the user
        // lands on a settled Space. Keep the window selected once it's shown.
        app.pending_focus = .{ .wid = win.id, .sid = target_sid };
        macos.spaces.switchToSpaceId(app.gpa, app.skylight_cid, target_sid) catch {};
    }
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
    .{ .name = "move_to_space", .func = zlua.wrap(agateMoveToSpace) },
    .{ .name = "join",        .func = zlua.wrap(agateJoin) },
    .{ .name = "rule",        .func = zlua.wrap(agateRule) },
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
        .accordion_padding = 40,
        .hyper_mods = MOD_CTRL | MOD_ALT | MOD_CMD | MOD_SHIFT,
        .hyper_key = 79, // kVK_F18 — common remapped-hyper trigger
        .bindings = .empty,
        .rules = .empty,
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
    for (cfg.rules.items) |r| freeRule(r);
    cfg.rules.deinit(cfg.alloc);
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
        const leaf = focus.currentFocusedLeaf(app) orelse {
            std.debug.print("[move] no focused leaf — nothing to swap\n", .{});
            return;
        };
        const forward = dir == .right or dir == .down;
        // swapLeaf swaps the window *payloads*, so the moved window keeps OS
        // focus where it is — no re-focus needed.
        if (tree.swapLeaf(leaf, forward)) {
            tree.flushActive(app);
            std.debug.print("[move] swapped {s}\n", .{cmd});
        } else {
            std.debug.print("[move] #{d} has no neighbour for {s}\n", .{ leaf.id, cmd });
        }
    } else if (std.mem.startsWith(u8, cmd, "focus ")) {
        const dir = parseDir(cmd[6..]) orelse return;
        _ = focus.focusDirection(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "layout ")) {
        setActiveLayout(app, cmd[7..]);
    } else if (std.mem.startsWith(u8, cmd, "space ")) {
        const n = std.fmt.parseInt(usize, cmd[6..], 10) catch return;
        macos.spaces.switchToIndex(app.gpa, app.skylight_cid, n) catch {};
    } else if (std.mem.startsWith(u8, cmd, "move_to_space ")) {
        const n = std.fmt.parseInt(usize, cmd[14..], 10) catch return;
        moveFocusedToSpace(app, n);
    }
}

// `std.Io.Dir.access` needs the `Io` handle from main; plain `access(2)` is
// enough for an existence probe and keeps the config layer Io-free.
fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0; // F_OK = 0
}

// ---------------------------------------------------------------------------
// Tests (pure parsing helpers — no Lua state or OS interaction)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseKeySpec parses modifiers and key" {
    const p = parseKeySpec("ctrl+shift+h", 0).?;
    try testing.expectEqual(MOD_CTRL | MOD_SHIFT, p.mods);
    try testing.expectEqual(@as(u16, 4), p.keycode); // kVK_ANSI_H

    const plain = parseKeySpec("space", 0).?;
    try testing.expectEqual(@as(u64, 0), plain.mods);
    try testing.expectEqual(@as(u16, 49), plain.keycode);
}

test "parseKeySpec expands hyper to the configured modifier set" {
    const hyper = MOD_CMD | MOD_ALT;
    const p = parseKeySpec("hyper+l", hyper).?;
    try testing.expectEqual(hyper, p.mods);
    try testing.expectEqual(@as(u16, 37), p.keycode); // kVK_ANSI_L
}

test "parseKeySpec rejects unknown or missing keys" {
    try testing.expect(parseKeySpec("ctrl+notakey", 0) == null);
    try testing.expect(parseKeySpec("ctrl+shift", 0) == null); // modifiers only
}

test "layoutFromName maps names and synonyms" {
    try testing.expectEqual(data.Layout.H_SPLIT, layoutFromName("h_tiles").?);
    try testing.expectEqual(data.Layout.H_SPLIT, layoutFromName("horizontal").?);
    try testing.expectEqual(data.Layout.V_SPLIT, layoutFromName("vertical").?);
    try testing.expectEqual(data.Layout.H_STACK, layoutFromName("h_accordion").?);
    try testing.expectEqual(data.Layout.V_STACK, layoutFromName("accordion").?);
    try testing.expectEqual(data.Layout.V_STACK, layoutFromName("stacking").?);
    try testing.expectEqual(data.Layout.FLOAT, layoutFromName("floating").?);
    try testing.expect(layoutFromName("bogus") == null);
}

test "parseDir maps direction names" {
    try testing.expectEqual(focus.Direction.left, parseDir("left").?);
    try testing.expectEqual(focus.Direction.down, parseDir("down").?);
    try testing.expect(parseDir("sideways") == null);
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
