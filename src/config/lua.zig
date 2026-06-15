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
const window = @import("../wm/window.zig");
const regexp = @import("../lib/regexp.zig");
const gestures = @import("../wm/gestures.zig");
const wm_layout = @import("../wm/layout.zig");
const wm_animate = @import("../wm/animate.zig");

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

/// A trackpad gesture binding (`agate.gesture("3:left", fn)`): an N-finger
/// swipe step in a direction, recognized by `wm/gestures.zig`.
pub const GestureBinding = struct {
    fingers: u8,
    dir: gestures.Swipe,
    action: BindingAction,
};

/// A modal keybind group (`agate.mode(name, {...})`), modelled on Hyprland's
/// submaps: while the mode is active it owns the keyboard — only its bindings
/// fire, global binds are suppressed, and unbound keys pass through to the app.
/// Enter with `agate.enter_mode(name)` (or `"mode <name>"`), leave with
/// `agate.exit_mode()` — typically bound to `escape` inside the mode.
pub const Mode = struct {
    name: []const u8, // owned by Config.alloc
    bindings: std.ArrayList(Binding),
};

/// A window assignment rule (`agate.rule{...}`), modelled on yabai's rules
/// (koekeishiya/yabai, src/rule.c): regexes select windows, the effect sends
/// them to a Space. Matching is AND across the present matchers; a rule with
/// neither matcher is rejected at registration.
pub const Rule = struct {
    /// Matches the owning application's name (POSIX extended regex).
    // @doc SR|app|string|true|POSIX extended regex matched against the owning application's name, e.g. `"^Music$"`.
    app: ?regexp.Regex = null,
    /// Matches the window title (POSIX extended regex).
    // @doc SR|title|string|true|POSIX extended regex matched against the window title.
    title: ?regexp.Regex = null,
    /// 1-based user-space index to send matched windows to (0 = unset/invalid).
    // @doc SR|space|integer|true|1-based Space position (Mission Control order, fullscreen included) matched windows are sent to. Required unless `monitor` is given (then it defaults to that monitor's first Space).
    space: usize = 0,
    /// 1-based monitor (display order) the `space` index counts on. 0 = the
    /// focused display (the original behaviour). Set it to pin an app to a
    /// specific display; combined with `space` to pick which Space on it
    /// (defaults to the monitor's first user Space when only `monitor` is given).
    // @doc SR|monitor|integer|true|1-based monitor (display order) the `space` position counts on; pins the app to that display. Omit for the focused display.
    monitor: usize = 0,
    /// Switch to the Space the window was sent to (the default: opening an
    /// assigned app takes the user along). `follow = false` routes the window
    /// in the background instead.
    // @doc SR|follow|boolean|true|Switch to that space along with the window (default `true`). Set `false` to route the window in the background — usually what you want when pinning to a monitor.
    follow: bool = true,
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    // @doc S|gaps|number|8|Pixels between adjacent tiles.
    gaps: f64,
    // @doc S|outer_gaps|number|8|Pixels inset from the screen edge.
    outer_gaps: f64,
    /// Accordion/stack peek inset (px): how far each stacked window is fanned
    /// past the one in front. See `data.gaps.accordion`.
    // @doc S|accordion_padding|number|40|Stacked-window "peek": how far each window in a stack/accordion fans past the one in front. Alias: `accordion`.
    accordion_padding: f64,
    /// CGEventFlag mask for the "hyper" macro key.
    // @doc S|hyper|string[]|{"ctrl","alt","cmd","shift"}|Modifier set the `hyper` macro in key specs expands to. Any of: `ctrl`/`control`, `alt`/`opt`, `cmd`/`command`, `shift`.
    hyper_mods: u64,
    /// Virtual keycode of a physical key whose held state means "hyper". Needed
    /// when a remapper (lazykeys, Karabiner) turns e.g. Caps Lock into F18 and
    /// applies the real modifiers downstream of our event tap, where we can't see
    /// them: we instead watch this key go down/up and synthesize `hyper_mods`.
    /// Default 79 = kVK_F18. 0 disables the feature.
    // @doc S|hyper_key|string|"f18"|Physical key whose held state is treated as `hyper`, for remappers (lazykeys/Karabiner) that hide the real modifiers from the event tap. A key name like `"f18"`; empty disables.
    hyper_key: u16,
    /// Small Screen Mode: on a small main display (the built-in panel, or any
    /// display at or under `small_screen_max_width` points), workspaces still
    /// on the default split layout are switched to `small_screen_layout`
    /// (an accordion/stack suits a screen too tiny to split), and back when a
    /// big display takes over. See `applySmallScreenMode`.
    // @doc S|small_screen|agate.SmallScreen|{ enabled = true, layout = "h_accordion", max_width = 0 }|Small Screen Mode (see agate.SmallScreen): workspaces on a small main display trade the split layout for an accordion, and back when a big display takes over.
    small_screen_enabled: bool,
    /// Width threshold (points) for "small" — 0 means "built-in display only".
    small_screen_max_width: f64,
    /// The layout small workspaces get. Default `.H_STACK` (horizontal accordion).
    small_screen_layout: data.Layout,
    /// "tabs" variant: the small-screen stack gets zero accordion peek, so every
    /// window is full-area and swipes/cycling flip between them like tabs.
    small_screen_tabs: bool,
    /// Animate AX-driven frame changes (AppKit's window slide) instead of
    /// snapping. Mirrored into `wm_layout.animate` on config load.
    // @doc S|animations|boolean|false|Animate tiling frame changes instead of snapping: the final size applies instantly, the position glides over (60 Hz, ease-out, capped at 8 windows per flush with an automatic snap when an app is too busy to keep up). Speed via `animation_duration`.
    animations: bool,
    /// Show the active space number as a menu-bar status item.
    // @doc S|space_indicator|boolean|true|Show the active space's number as a menu-bar status item.
    space_indicator: bool,
    /// Show the translucent target-slot overlay while dragging a window.
    // @doc S|drag_preview|boolean|true|While dragging a window, highlight the tile it will swap into on drop with a translucent overlay.
    drag_preview: bool,
    /// Drop the outer gap when a workspace holds a single window (Hyprland's
    /// `no_gaps_when_only`). Mirrored into `wm_layout.smart_gaps` on config load.
    // @doc S|smart_gaps|boolean|false|When a workspace holds a single window, drop the outer gap so it fills the display edge-to-edge (Hyprland's `no_gaps_when_only`).
    smart_gaps: bool,
    bindings: std.ArrayList(Binding),
    gesture_bindings: std.ArrayList(GestureBinding),
    /// Registered modal keybind groups (`agate.mode`). Indexed by `active_mode`.
    modes: std.ArrayList(Mode),
    /// Index into `modes` of the currently active modal group, or null when in
    /// the normal (global-bind) keymap. Toggled by `enter_mode` / `exit_mode`.
    active_mode: ?usize = null,
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
    .{ .name = "comma", .code = 43 }, .{ .name = "period", .code = 47 },
    .{ .name = "slash", .code = 44 }, .{ .name = "semicolon", .code = 41 },
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

/// Read the boolean field `name` from the table at `idx` into `dst` (left
/// unchanged when absent or non-boolean).
fn boolField(lua: *Lua, idx: i32, name: [:0]const u8, dst: *bool) void {
    _ = lua.getField(idx, name);
    defer lua.pop(1);
    if (lua.isBoolean(-1)) dst.* = lua.toBoolean(-1);
}

// @doc F|config|Apply global configuration. Call once near the top of init.lua.
// @doc FP|config|config|agate.Config|false|Settings table (see agate.Config).
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
    // small_screen: { enabled = bool, max_width = number, layout = string }.
    // `layout` accepts every layoutFromName name plus "tabs"/"tabbed" (a
    // zero-peek stack: full-area windows flipped through like tabs).
    // @doc SS|enabled|boolean|true|Master switch (default `true`).
    // @doc SS|layout|string|true|Layout small workspaces get: any layout name (default `"h_accordion"`), or `"tabs"` for a zero-peek stack — full-area windows flipped through like tabs.
    // @doc SS|max_width|number|true|Width (points) at or under which a display counts as small, in addition to the built-in panel. `0` (default) = built-in display detection only.
    _ = lua.getField(1, "small_screen");
    if (lua.isTable(-1)) {
        _ = lua.getField(-1, "enabled");
        if (lua.isBoolean(-1)) cfg.small_screen_enabled = lua.toBoolean(-1);
        lua.pop(1);
        _ = lua.getField(-1, "max_width");
        if (lua.isNumber(-1)) cfg.small_screen_max_width = lua.toNumber(-1) catch 0;
        lua.pop(1);
        _ = lua.getField(-1, "layout");
        if (lua.isString(-1)) {
            const s = std.mem.sliceTo(lua.toString(-1) catch "", 0);
            if (std.mem.eql(u8, s, "tabs") or std.mem.eql(u8, s, "tabbed")) {
                cfg.small_screen_layout = .H_STACK;
                cfg.small_screen_tabs = true;
            } else if (layoutFromName(s)) |l| {
                cfg.small_screen_layout = l;
                cfg.small_screen_tabs = false;
            } else {
                std.debug.print("[config] small_screen: unknown layout {s}\n", .{s});
            }
        }
        lua.pop(1);
    }
    lua.pop(1);
    // UX toggles.
    boolField(lua, 1, "animations", &cfg.animations);
    wm_layout.animate = cfg.animations;
    // animation_duration: milliseconds per frame animation — the speed knob.
    // @doc S|animation_duration|number|150|Length of the frame animation in **milliseconds** (lower = faster; `0` disables). Only meaningful with `animations = true`.
    var anim_dur: f64 = wm_animate.duration_ms;
    if (numberField(lua, "animation_duration", &anim_dur)) {
        // The knob used to be seconds; a sub-5 value can only be the old unit
        // (a 5 ms animation is invisible) — convert instead of silently
        // disabling animations for configs written against the old docs.
        if (anim_dur > 0 and anim_dur < 5) {
            std.debug.print("[config] animation_duration is in milliseconds now; treating {d} as {d} ms\n", .{ anim_dur, anim_dur * 1000 });
            anim_dur *= 1000;
        }
        wm_animate.duration_ms = @max(0, anim_dur);
    }
    boolField(lua, 1, "space_indicator", &cfg.space_indicator);
    boolField(lua, 1, "drag_preview", &cfg.drag_preview);
    boolField(lua, 1, "smart_gaps", &cfg.smart_gaps);
    wm_layout.smart_gaps = cfg.smart_gaps;
    // space_animation: how much of the Space-switch transition plays.
    // TODO: Remove this option
    // @doc S|space_animation|string|"instant"|How much of the Space-switch transition plays: `"fast"`, `"very_fast"`, or `"instant"` (no perceptible animation).
    _ = lua.getField(1, "space_animation");
    if (lua.isString(-1)) {
        const s = std.mem.sliceTo(lua.toString(-1) catch "", 0);
        if (std.mem.eql(u8, s, "fast")) {
            macos.event_tap.switch_speed = .fast;
        } else if (std.mem.eql(u8, s, "very_fast")) {
            macos.event_tap.switch_speed = .very_fast;
        } else if (std.mem.eql(u8, s, "instant")) {
            macos.event_tap.switch_speed = .instant;
        } else {
            std.debug.print("[config] space_animation: unknown speed {s}\n", .{s});
        }
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

// @doc F|bind|Bind a key chord to an action.
// @doc FP|bind|spec|string|false|Key chord, e.g. `"hyper+shift+l"`.
// @doc FP|bind|action|fun()|string|false|A Lua callback, or a string command (see Commands below).
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

/// Parse a gesture spec like `"3:left"` / `"swipe+3+up"`: a finger count
/// (3 or 4) and a direction, in any order, separated by `:`, `+` or `-`.
/// A literal `swipe` token is allowed and ignored. Null if either is missing.
fn parseGestureSpec(spec: []const u8) ?struct { fingers: u8, dir: gestures.Swipe } {
    var fingers: u8 = 0;
    var dir: ?gestures.Swipe = null;
    var it = std.mem.splitAny(u8, spec, ":+-");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "swipe")) continue;
        if (part.len == 1 and part[0] >= '0' and part[0] <= '9') {
            fingers = part[0] - '0';
        } else if (std.mem.eql(u8, part, "left")) {
            dir = .left;
        } else if (std.mem.eql(u8, part, "right")) {
            dir = .right;
        } else if (std.mem.eql(u8, part, "up")) {
            dir = .up;
        } else if (std.mem.eql(u8, part, "down")) {
            dir = .down;
        } else {
            return null;
        }
    }
    if (fingers < 3 or fingers > 4) return null;
    return .{ .fingers = fingers, .dir = dir orelse return null };
}

/// `agate.gesture(spec, action)` — bind an N-finger trackpad swipe (e.g.
/// `"3:left"`) to a Lua function or string command, like `agate.bind` does for
/// key chords. The swipe tracks continuously with a Liquid Glass HUD and the
/// action commits once on lift — either by dragging far enough or by flicking
/// fast, like native macOS space switching.
// @doc F|gesture|Bind a trackpad swipe to an action. The swipe tracks live with a Liquid Glass HUD and fires once when you lift — drag far enough or flick fast, like native macOS. The system gestures on the same finger count must be off or moved to the other count in Trackpad settings.
// @doc FP|gesture|spec|string|false|Finger count (3 or 4) and direction, e.g. `"3:left"` or `"4:up"`.
// @doc FP|gesture|action|fun()|string|false|A Lua callback, or a string command (see Commands below).
fn agateGesture(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    const spec_z = lua.toString(1) catch return 0;
    const spec = std.mem.sliceTo(spec_z, 0);

    const parsed = parseGestureSpec(spec) orelse {
        std.debug.print("[config] bad gesture spec: {s} (want e.g. \"3:left\")\n", .{spec});
        return 0;
    };

    // Arm the scroll-blocking tap: now that a gesture is bound, an in-progress
    // swipe should swallow the scroll the app below would otherwise receive.
    gestures.g_enabled.store(true, .release);

    if (lua.isFunction(2)) {
        lua.pushValue(2);
        const fn_ref = lua.ref(zlua.registry_index);
        cfg.gesture_bindings.append(cfg.alloc, .{
            .fingers = parsed.fingers,
            .dir = parsed.dir,
            .action = .{ .lua_fn = fn_ref },
        }) catch {};
    } else if (lua.isString(2)) {
        const cmd_z = lua.toString(2) catch return 0;
        const cmd = cfg.alloc.dupe(u8, std.mem.sliceTo(cmd_z, 0)) catch return 0;
        cfg.gesture_bindings.append(cfg.alloc, .{
            .fingers = parsed.fingers,
            .dir = parsed.dir,
            .action = .{ .cmd = cmd },
        }) catch {
            cfg.alloc.free(cmd);
        };
    }
    return 0;
}

/// `agate.mode(name, { keyspec = action, ... })` — define a modal keybind group
/// (Hyprland-style submap). Each entry binds a key chord (same syntax as
/// `agate.bind`) to a Lua function or string command, but only while the mode is
/// active. Enter it with `agate.enter_mode(name)`; leave with `agate.exit_mode()`
/// — bind that to `escape` inside the mode so there's always a way out.
// @doc F|mode|Define a modal keybind group (Hyprland-style submap): a named table of `keyspec = action` entries that are live only while the mode is active. Enter with `agate.enter_mode(name)`, leave with `agate.exit_mode()`. While a mode is active only its bindings fire — global binds are suppressed and unbound keys pass through to the focused app. Bind `escape` to `agate.exit_mode` so there's always a way out.
// @doc FP|mode|name|string|false|Mode name, referenced by `enter_mode`/`exit_mode` and the `mode <name>` command.
// @doc FP|mode|bindings|table|false|Table mapping a key chord (e.g. `"h"`, `"shift+l"`) to a Lua function or string command.
fn agateMode(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    const name = std.mem.sliceTo(name_z, 0);
    if (!lua.isTable(2)) {
        std.debug.print("[config] mode '{s}': second argument must be a {{ key = action }} table\n", .{name});
        return 0;
    }

    var mode: Mode = .{ .name = cfg.alloc.dupe(u8, name) catch return 0, .bindings = .empty };

    // Walk the table: keys are keyspec strings, values are functions or commands
    // (same forms `agate.bind` accepts). `lua.next` pops the value each turn and
    // leaves the key for the following iteration; we guard `isString` on the key
    // so coercion never mutates a live key and breaks the traversal.
    lua.pushNil();
    while (lua.next(2)) {
        if (!lua.isString(-2)) { lua.pop(1); continue; }
        const spec = std.mem.sliceTo(lua.toString(-2) catch {
            lua.pop(1);
            continue;
        }, 0);
        const parsed = parseKeySpec(spec, cfg.hyper_mods) orelse {
            std.debug.print("[config] mode '{s}': unknown key '{s}'\n", .{ name, spec });
            lua.pop(1);
            continue;
        };
        if (lua.isFunction(-1)) {
            lua.pushValue(-1);
            const fn_ref = lua.ref(zlua.registry_index);
            mode.bindings.append(cfg.alloc, .{
                .keycode = parsed.keycode,
                .modifiers = parsed.mods,
                .action = .{ .lua_fn = fn_ref },
            }) catch {};
        } else if (lua.isString(-1)) {
            const cmd_z = lua.toString(-1) catch {
                lua.pop(1);
                continue;
            };
            const cmd = cfg.alloc.dupe(u8, std.mem.sliceTo(cmd_z, 0)) catch {
                lua.pop(1);
                continue;
            };
            mode.bindings.append(cfg.alloc, .{
                .keycode = parsed.keycode,
                .modifiers = parsed.mods,
                .action = .{ .cmd = cmd },
            }) catch cfg.alloc.free(cmd);
        }
        lua.pop(1); // drop value; keep key for the next `lua.next`
    }

    cfg.modes.append(cfg.alloc, mode) catch {
        cfg.alloc.free(mode.name);
        mode.bindings.deinit(cfg.alloc);
    };
    return 0;
}

/// Activate the named mode by index (shared by `agate.enter_mode` and the
/// `mode <name>` command). Updates the menu-bar indicator if it's present.
fn enterModeByName(cfg: *Config, name: []const u8) void {
    for (cfg.modes.items, 0..) |m, i| {
        if (!std.mem.eql(u8, m.name, name)) continue;
        cfg.active_mode = i;
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "◆ {s}", .{name})) |label| {
            macos.statusbar.setText(label);
        } else |_| {}
        return;
    }
    std.debug.print("[config] enter_mode: no mode named '{s}'\n", .{name});
}

/// Leave any active mode and restore the normal keymap (and the Space indicator).
fn exitActiveMode(cfg: *Config) void {
    if (cfg.active_mode == null) return;
    cfg.active_mode = null;
    // Restore the menu-bar item to the Space number the indicator normally shows.
    if (g_appstate) |app| {
        macos.statusbar.setSpaceNumber(macos.spaces.activeUserIndex(app.gpa, app.skylight_cid));
    }
}

/// `agate.enter_mode(name)` — switch into a mode defined with `agate.mode`.
// @doc F|enter_mode|Activate a mode defined with `agate.mode`. While active, only that mode's bindings fire; global binds are suppressed and unbound keys pass through. The active mode name shows in the menu-bar indicator.
// @doc FP|enter_mode|name|string|false|Name of a mode registered with `agate.mode`.
fn agateEnterMode(lua: *Lua) i32 {
    const cfg = g_config orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    enterModeByName(cfg, std.mem.sliceTo(name_z, 0));
    return 0;
}

/// `agate.exit_mode()` — leave the active mode, back to the normal keymap.
// @doc F|exit_mode|Leave the active mode and return to the normal keymap. Bind this to `escape` inside a mode so there's always a way out.
fn agateExitMode(_: *Lua) i32 {
    if (g_config) |cfg| exitActiveMode(cfg);
    return 0;
}

/// `agate.cycle("next"|"prev")` — focus the next/previous window among the
/// focused window's siblings, wrapping at the edges. The accordion motion:
/// on a small screen every window is one cycle step away.
// @doc F|cycle|Focus the next/previous window among the focused window's siblings, wrapping at the edges — the natural motion through an accordion/stack (Small Screen Mode), bindable to a swipe or a key.
// @doc FP|cycle|dir|"next"|"prev"|false|Cycle direction.
fn agateCycle(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = std.mem.sliceTo(dir_z, 0);
    const forward = !(std.mem.eql(u8, dir, "prev") or std.mem.eql(u8, dir, "previous") or
        std.mem.eql(u8, dir, "back") or std.mem.eql(u8, dir, "backward"));
    _ = focus.cycleFocus(app, forward);
    return 0;
}

// @doc F|focus|Move focus to the nearest window in a direction, descending into and ascending out of nested containers (i3-style). Left/right traverse horizontal splits/stacks; up/down vertical ones.
// @doc FP|focus|dir|agate.Direction|false|Direction to move focus.
fn agateFocus(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    _ = focus.focusDirection(app, dir);
    return 0;
}

// @doc F|layout|Set the focused container's layout (the focused window's parent), falling back to the workspace for top-level windows.
// @doc FP|layout|mode|agate.Layout|false|Layout mode to apply.
fn agateLayout(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    setActiveLayout(app, std.mem.sliceTo(name_z, 0));
    return 0;
}

/// Map a layout name to a tiling mode. Accepts AeroSpace-ish synonyms.
/// "toggle" is handled by `setActiveLayout` (it needs the current layout).
// @doc A|agate.Layout|A layout mode. Synonyms: `h_split`/`horizontal` = `h_tiles`; `v_split`/`vertical` = `v_tiles`; `v_accordion`/`stacking`/`stacked` = `v_stack`/`accordion`; `floating` = `float`. `toggle` flips the split orientation.
// @doc AV|agate.Layout|h_tiles
// @doc AV|agate.Layout|v_tiles
// @doc AV|agate.Layout|h_stack
// @doc AV|agate.Layout|v_stack
// @doc AV|agate.Layout|accordion
// @doc AV|agate.Layout|float
// @doc AV|agate.Layout|toggle
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
    target.auto_small = false; // an explicit choice — Small Screen Mode keeps off it
    tree.flushActive(app);
}

/// Combine the focused window with an adjacent one into a nested container,
/// giving the workspace a mixed layout. `agate.join(dir [, layout])`: `dir` is
/// the neighbour to absorb ("left"/"right"/"up"/"down"); `layout` is the new
/// container's mode (default "v_stack" — a vertical stack).
// @doc F|join|Combine the focused window with its neighbour into a nested container, for mixed layouts (e.g. a row whose one slot is a stack of two windows).
// @doc FP|join|dir|agate.Direction|false|Neighbour to combine with.
// @doc FP|join|mode|agate.Layout|true|Layout of the new container. Default `v_stack`.
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

/// Toggle "zoom fullscreen" for the focused window: flip its `fake_full_screen`
/// flag and re-tile. Layout (`place`) hands a flagged leaf the whole workspace
/// area instead of its tiled slot, so the window overlays the others until it's
/// toggled off; the tiling underneath is preserved. Direct port of yabai's
/// `window --toggle zoom-fullscreen` (not native macOS fullscreen — no separate
/// Space, no transition animation).
// @doc F|zoom_fullscreen|Toggle "zoom fullscreen" for the focused window (yabai's `window --toggle zoom-fullscreen`): the window fills the whole space, overlapping the other tiles; toggle again to drop it back into the tiling. Not native macOS fullscreen — it stays on the same Space with no transition.
fn agateZoomFullscreen(lua: *Lua) i32 {
    _ = lua;
    toggleZoomFullscreen(g_appstate orelse return 0);
    return 0;
}

// @doc F|exec|Run a shell command in the background, like skhd's `:` commands. The command line is handed to `$SHELL -c` (falling back to `/bin/sh -c`), so pipes, globs, and `&&` all work. agate does not wait for it — use it to launch apps or scripts from a keybind.
// @doc FP|exec|cmd|string|false|The shell command line to run.
fn agateExec(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const cmd_z = lua.toString(1) catch return 0;
    spawnShell(app.gpa, cmd_z);
    return 0;
}

// `fork` isn't exposed by the Zig 0.16 std (it's a private extern in std.c), but
// `execve`/`waitpid`/`setsid`/`environ`/`_exit` are — declare just `fork`.
extern "c" fn fork() std.c.pid_t;

/// Launch `cmd` through the user's shell without blocking the WM or leaving a
/// zombie behind. Modelled on skhd's `fork_exec` (koekeishiya/skhd): a
/// double-fork daemonizes the worker — the grandchild execs the shell and, once
/// the intermediate child exits, is reparented to launchd, which reaps it; we
/// wait out the intermediate child here so nothing lingers.
///
/// All allocation and env lookup happen in the parent *before* `fork`, because
/// the process is multithreaded (the multitouch thread) and only
/// async-signal-safe calls are legal between `fork` and `execve` in the child.
fn spawnShell(alloc: std.mem.Allocator, cmd: []const u8) void {
    if (cmd.len == 0) return;
    const cmdz = alloc.dupeZ(u8, cmd) catch return;
    defer alloc.free(cmdz);

    const shell: [*:0]const u8 = blk: {
        if (std.c.getenv("SHELL")) |s| {
            if (s[0] != 0) break :blk s;
        }
        break :blk "/bin/sh";
    };

    const pid = fork();
    if (pid < 0) {
        std.debug.print("[exec] fork failed for: {s}\n", .{cmd});
        return;
    }
    if (pid == 0) {
        // Intermediate child: detach into its own session, fork the worker, leave.
        _ = std.c.setsid();
        if (fork() == 0) {
            const argv = [_:null]?[*:0]const u8{ shell, "-c", cmdz.ptr };
            _ = std.c.execve(shell, &argv, @ptrCast(std.c.environ));
            std.c._exit(127); // execve only returns on failure
        }
        std.c._exit(0); // orphan the worker so launchd adopts (and reaps) it
    }
    // Parent: the intermediate child exits at once — reap it so it's no zombie.
    _ = std.c.waitpid(pid, null, 0);
}

/// Shared by `agate.zoom_fullscreen()` and the `zoom_fullscreen` string command.
fn toggleZoomFullscreen(app: *state.AppState) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    if (leaf.window == null) return;
    const win = &leaf.window.?;
    win.fake_full_screen = !win.fake_full_screen;
    tree.flushActive(app);
    // While zoomed the window overlaps its siblings — keep it raised on top.
    if (win.fake_full_screen) _ = focus.focusLeaf(leaf);
}

// @doc F|space|Switch to the Nth Space on the focused display. Counts every Space the swipe passes through, in Mission Control order — including native-fullscreen Spaces (so a fullscreened app at strip position N is reached by N).
// @doc FP|space|n|integer|false|1-based Space position on the focused display, in Mission Control order (fullscreen Spaces included).
fn agateSpace(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    macos.spaces.switchToIndex(app.gpa, app.skylight_cid, @intCast(n)) catch {};
    return 0;
}

// @doc F|space_next|Switch to the next Space on the focused display (one step in Mission Control order, fullscreen Spaces included).
fn agateSpaceNext(lua: *Lua) i32 {
    _ = lua;
    const app = g_appstate orelse return 0;
    macos.spaces.switchNext(app.gpa, app.skylight_cid) catch {};
    return 0;
}

// @doc F|space_prev|Switch to the previous Space on the focused display (one step in Mission Control order, fullscreen Spaces included).
fn agateSpacePrev(lua: *Lua) i32 {
    _ = lua;
    const app = g_appstate orelse return 0;
    macos.spaces.switchPrev(app.gpa, app.skylight_cid) catch {};
    return 0;
}

// @doc F|resize|Resize the focused tile, transferring the delta to its neighbour.
// @doc FP|resize|dir|agate.Direction|false|Edge to grow toward.
// @doc FP|resize|amount|number|true|Pixels to resize by. Default 50.
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

// @doc F|move|Swap the focused window with its neighbour in a direction. Works across nested containers.
// @doc FP|move|dir|agate.Direction|false|Direction to move the window.
fn agateMove(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.swapLeaf(leaf, forward)) tree.flushActive(app);
    return 0;
}

/// `agate.move_to_space(n [, monitor])`: send the focused window to user space
/// `n`. With a second argument it targets space `n` on monitor `monitor`
/// (1-based, in display order) — so a window can be assigned to a Space on
/// another display; without it, the focused display.
// @doc F|move_to_space|Send the focused window to user space N (does not follow focus). With a monitor argument, the space on that display.
// @doc FP|move_to_space|n|integer|false|1-based Space position (Mission Control order, fullscreen included) to send the window to.
// @doc FP|move_to_space|monitor|integer|true|1-based monitor (display order) the position counts on. Omit for the focused display — pass it to assign the window to a Space on another monitor.
fn agateMoveToSpace(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    if (lua.isNumber(2)) {
        const mon = lua.toInteger(2) catch 0;
        if (mon >= 1) {
            moveFocusedToSpaceOnMonitor(app, @intCast(mon), @intCast(n));
            return 0;
        }
    }
    moveFocusedToSpace(app, @intCast(n));
    return 0;
}

/// Move the focused window to the Nth user space on the focused display.
fn moveFocusedToSpace(app: *state.AppState, n: usize) void {
    const target_sid = (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, n) catch return) orelse return;
    moveFocusedToSpaceId(app, target_sid);
}

/// Move the focused window to user space `n` on the display at `monitor`
/// (1-based, display order). Lets the window land on another monitor's Space.
fn moveFocusedToSpaceOnMonitor(app: *state.AppState, monitor: usize, n: usize) void {
    if (monitor < 1) return;
    const target_sid = (macos.spaces.userSpaceIdOnDisplay(app.gpa, app.skylight_cid, monitor - 1, n) catch return) orelse return;
    moveFocusedToSpaceId(app, target_sid);
}

/// Reassign the focused window to space `target_sid` via the SkyLight SPI, then
/// sync our tree by relocating the leaf into the destination workspace and
/// relaying out both the (now-shrunk) source and the destination — within each
/// one's own display frame. No-op when the window is already there.
fn moveFocusedToSpaceId(app: *state.AppState, target_sid: u64) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    const win = if (leaf.window) |w| w else return;
    const cur_ws = leaf.parent orelse return; // Workspace Con; .id == SkyLight sid
    if (target_sid == cur_ws.id) return; // already there — don't issue the SPI
    // A native-fullscreen window can't be sent to a regular Space while it's
    // fullscreen — exit fullscreen first, then finish the move once it lands on
    // a user Space (see `runPendingMove`).
    if (deferIfFullscreen(app, leaf, win.id, target_sid)) return;
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    // The tree's children lists are arena-allocated — growing them with any
    // other allocator would free arena memory through it (undefined behavior).
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
    tree.flushActive(app); // re-tile the source we just shrank
    tree.flushWorkspace(app, dst_ws); // and slot the moved window into the destination's row

    // Keep the moved window selected once its Space is shown (yabai-style): the
    // space-change handler blanket-focuses a tile to pull the menu bar over, so
    // arm a pending focus on this window for the destination Space instead.
    app.pending_focus = .{ .wid = win.id, .sid = target_sid };
}

/// `agate.focus_monitor(dir)`: move keyboard focus to another display
/// (`next`/`prev`, or `left`/`right`/`up`/`down`).
// @doc F|focus_monitor|Move keyboard focus to another display, raising its most-recently-used window (or warping the cursor to an empty display). No-op with a single display.
// @doc FP|focus_monitor|dir|agate.MonitorDir|false|Which display to focus.
fn agateFocusMonitor(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseMonitorDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    _ = focus.focusMonitor(app, dir);
    return 0;
}

/// `agate.move_to_monitor(dir)`: move the focused window to the visible Space
/// of an adjacent display and tile it there, following it over.
// @doc F|move_to_monitor|Move the focused window to an adjacent display's visible space, tile it there, and follow focus to it.
// @doc FP|move_to_monitor|dir|agate.MonitorDir|false|Which display to move the window to.
fn agateMoveToMonitor(lua: *Lua) i32 {
    const app = g_appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parseMonitorDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    moveFocusedToMonitor(app, dir);
    return 0;
}

/// Move the focused window to the visible Space of the display `dir` selects,
/// re-tile both displays, and follow focus to the window on its new monitor.
/// Because the destination Space is already on-screen there, the window appears
/// and can be focused immediately (no deferred `pending_focus`).
fn moveFocusedToMonitor(app: *state.AppState, dir: focus.MonitorDir) void {
    const leaf = focus.currentFocusedLeaf(app) orelse return;
    const win = if (leaf.window) |w| w else return;

    var buf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const count = tree.collectMonitors(app, &buf);
    if (count < 2) return;
    const mons = buf[0..count];

    const cur_mon = tree.monitorOf(leaf) orelse (focus.currentMonitor(app) orelse return);
    var ci: usize = 0;
    for (mons, 0..) |m, i| if (m.con == cur_mon) {
        ci = i;
        break;
    };
    const ti = focus.monitorTarget(mons, ci, dir) orelse return;
    if (ti == ci) return;

    const target_sid = mons[ti].current_space;
    if (target_sid == 0) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    if (dst_ws == leaf.parent) return;
    // Native fullscreen: exit it first, then finish the move (see runPendingMove).
    if (deferIfFullscreen(app, leaf, win.id, target_sid)) return;
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;

    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws);
    tree.flushActive(app); // re-tile the source we shrank
    tree.flushWorkspace(app, dst_ws); // tile the destination
    _ = focus.focusLeaf(leaf); // the window is visible there now — follow it
}

/// If `leaf`'s window is on a native-fullscreen Space, leave fullscreen and
/// record the move to finish once it returns to a user Space. Returns true when
/// it deferred (the caller must not proceed with the move this turn).
fn deferIfFullscreen(app: *state.AppState, leaf: *data.Con, wid: u32, target_sid: u64) bool {
    const ws = tree.workspaceOf(leaf) orelse return false;
    if (ws.space_type == 0) return false; // a normal window — move it directly
    const win = if (leaf.window) |*w| w else return false;
    const el = window.resolveElement(win) orelse return false;
    if (!el.setBool("AXFullScreen", false)) return false; // couldn't exit — let caller try
    app.pending_move = .{ .wid = wid, .target_sid = target_sid };
    std.debug.print("[move] #{d} leaving fullscreen; move to {d} deferred\n", .{ wid, target_sid });
    return true;
}

/// Carry out a move deferred by `deferIfFullscreen`, once the window has left
/// the fullscreen Space and is back on a user Space. Called from the
/// space-change handler. No-op while the window is still transitioning.
pub fn runPendingMove(app: *state.AppState) void {
    const pm = app.pending_move orelse return;
    const root = app.tree orelse return;
    const leaf = tree.findLeaf(root, pm.wid) orelse {
        app.pending_move = null; // window gone
        return;
    };
    const src_ws = tree.workspaceOf(leaf) orelse return;
    if (src_ws.space_type != 0) return; // still on a fullscreen/transition Space — wait
    app.pending_move = null;
    if (src_ws.id == pm.target_sid) return; // already landed on the target
    if (!macos.spaces.moveWindowToSpace(pm.wid, pm.target_sid)) return;
    const dst = tree.findWorkspace(root, pm.target_sid) orelse return;
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst);
    tree.flushWorkspace(app, src_ws); // re-tile the Space it returned to
    tree.flushWorkspace(app, dst); // tile the destination
    app.pending_focus = .{ .wid = pm.wid, .sid = pm.target_sid };
    std.debug.print("[move] fullscreen exited; #{d} -> space {d}\n", .{ pm.wid, pm.target_sid });
}

/// `agate.rule{ app = "...", title = "...", space = N, follow = bool }`
/// Register a window assignment rule (yabai's `yabai -m rule --add app=...
/// space=N`). `app`/`title` are POSIX extended regexes; at least one must be
/// given. Matched windows are sent to user space N when they appear.
// @doc F|rule|Register a window assignment rule, like yabai's `rule --add`: windows whose app name/title match the given regexes are sent to a space (and optionally a specific monitor) when they appear. At least one of `app`/`title` is required; both must match when both are given. Give `space`, `monitor`, or both. When several rules match a window, the last registered one wins.
// @doc FP|rule|rule|agate.Rule|false|Rule table (see agate.Rule).
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

    _ = lua.getField(1, "monitor");
    if (lua.isNumber(-1)) {
        const m = lua.toInteger(-1) catch 0;
        if (m >= 1) rule.monitor = @intCast(m);
    }
    lua.pop(1);
    // `monitor` alone pins to that display's first user Space.
    if (rule.monitor >= 1 and rule.space == 0) rule.space = 1;

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
        std.debug.print("[config] rule needs a space or monitor, and an app or title matcher; ignored\n", .{});
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
fn matchRules(app_name: []const u8, title: []const u8) ?struct { space: usize, monitor: usize, follow: bool } {
    const cfg = g_config orelse return null;
    var space: usize = 0;
    var monitor: usize = 0;
    var follow = false;
    for (cfg.rules.items) |r| {
        if (r.app) |re| {
            if (!regexMatches(re, app_name)) continue;
        }
        if (r.title) |re| {
            if (!regexMatches(re, title)) continue;
        }
        space = r.space;
        monitor = r.monitor;
        follow = r.follow;
    }
    if (space == 0) return null;
    return .{ .space = space, .monitor = monitor, .follow = follow };
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
    // A `monitor` makes `space` count on that display (1-based); else the
    // focused display, the original behaviour.
    const target_sid = blk: {
        if (eff.monitor >= 1) {
            break :blk (macos.spaces.userSpaceIdOnDisplay(app.gpa, app.skylight_cid, eff.monitor - 1, eff.space) catch return) orelse return;
        }
        break :blk (macos.spaces.userSpaceIdAt(app.gpa, app.skylight_cid, eff.space) catch return) orelse return;
    };
    if (target_sid == cur_ws.id) return; // already on the assigned space
    if (!macos.spaces.moveWindowToSpace(win.id, target_sid)) return;
    const root = app.tree orelse return;
    const dst_ws = tree.findWorkspace(root, target_sid) orelse return;
    _ = tree.moveLeafToWorkspace(app.arena, leaf, dst_ws); // arena: see moveFocusedToSpace
    tree.flushWorkspace(app, dst_ws);
    std.debug.print("[rule] {s} #{d} -> space {d} (monitor {d})\n", .{ win.owner, win.id, eff.space, eff.monitor });
    // Mute activation-follow for this window either way: the app activates
    // around its own launch, and the follow chasing the window we just routed
    // would switch the user a second time (racing the gesture below and able to
    // overshoot) — or, for a follow-less rule, switch them against its intent.
    app.rule_moved = .{ .wid = win.id, .at = macos.c.CFAbsoluteTimeGetCurrent() };
    if (eff.follow) {
        // The window is already moved and tiled (flushed above), so the user
        // lands on a settled Space. Keep the window selected once it's shown.
        app.pending_focus = .{ .wid = win.id, .sid = target_sid };
        if (eff.monitor >= 1) {
            // `switchToSpaceId` only drives the *focused* display. For a
            // monitor-targeted rule, focus the window directly — when that
            // display already shows the target Space it's on-screen, so focus
            // (and the menu bar) move there; otherwise `pending_focus` keeps it
            // selected for when the Space is next shown.
            _ = focus.focusLeaf(leaf);
        } else {
            macos.spaces.switchToSpaceId(app.gpa, app.skylight_cid, target_sid) catch {};
        }
    }
}

// How `// @doc` annotations work: tools/gen_docs.zig scans this file for lines
// beginning `// @doc ` and renders types/agate.lua plus the wiki's
// Configuration reference from them (run `zig build docs`). Each annotation lives directly above the code it
// documents. Field separator is '|'; the FP/C type/form fields may contain '|'.

const agate_fns = [_]zlua.FnReg{
    .{ .name = "config",      .func = zlua.wrap(agateConfig) },
    .{ .name = "bind",        .func = zlua.wrap(agateBind) },
    .{ .name = "gesture",     .func = zlua.wrap(agateGesture) },
    .{ .name = "mode",        .func = zlua.wrap(agateMode) },
    .{ .name = "enter_mode",  .func = zlua.wrap(agateEnterMode) },
    .{ .name = "exit_mode",   .func = zlua.wrap(agateExitMode) },
    .{ .name = "cycle",       .func = zlua.wrap(agateCycle) },
    .{ .name = "focus",       .func = zlua.wrap(agateFocus) },
    .{ .name = "layout",      .func = zlua.wrap(agateLayout) },
    .{ .name = "space",       .func = zlua.wrap(agateSpace) },
    .{ .name = "space_next",  .func = zlua.wrap(agateSpaceNext) },
    .{ .name = "space_prev",  .func = zlua.wrap(agateSpacePrev) },
    .{ .name = "resize",      .func = zlua.wrap(agateResize) },
    .{ .name = "move",        .func = zlua.wrap(agateMove) },
    .{ .name = "move_to_space", .func = zlua.wrap(agateMoveToSpace) },
    .{ .name = "focus_monitor", .func = zlua.wrap(agateFocusMonitor) },
    .{ .name = "move_to_monitor", .func = zlua.wrap(agateMoveToMonitor) },
    .{ .name = "join",        .func = zlua.wrap(agateJoin) },
    .{ .name = "zoom_fullscreen", .func = zlua.wrap(agateZoomFullscreen) },
    .{ .name = "exec",        .func = zlua.wrap(agateExec) },
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
        .small_screen_enabled = true,
        .small_screen_max_width = 0, // built-in display detection only
        .small_screen_layout = .H_STACK,
        .small_screen_tabs = false,
        .animations = false,
        .space_indicator = true,
        .drag_preview = true,
        .smart_gaps = false,
        .bindings = .empty,
        .gesture_bindings = .empty,
        .modes = .empty,
        .rules = .empty,
        .lua = try Lua.init(gpa),
    };
    g_config = cfg;

    cfg.lua.openLibs();
    cfg.lua.newLib(&agate_fns);
    cfg.lua.setGlobal("agate");

    const config_path = findConfigPath(gpa) orelse {
        std.debug.print("[config] no init.lua found; using defaults\n", .{});
        // Small Screen Mode is on by default, so it applies config or not.
        if (applySmallScreenMode(app)) tree.flushAllVisible(app);
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

    // With the config settled, put workspaces into (or out of) Small Screen
    // Mode for the current display and re-tile so it shows immediately.
    if (applySmallScreenMode(app)) tree.flushAllVisible(app);

    return cfg;
}

// ---------------------------------------------------------------------------
// Small Screen Mode
// ---------------------------------------------------------------------------

/// Whether the screen being worked on counts as "small": the built-in panel
/// is the *only* display (a MacBook on the go — the case the mode exists for),
/// or the visible frame is at or under the configured width threshold (for
/// users who call e.g. a 13" external small). The only-display test matters:
/// keying on "is the primary display built-in" while an external monitor is
/// attached used to flip the accordion on for the big screen too.
fn isSmallScreen(cfg: *const Config) bool {
    if (macos.display.builtinIsOnlyDisplay()) return true;
    if (cfg.small_screen_max_width > 0) {
        if (macos.display.mainVisibleFrame()) |frame| {
            return frame.size.width <= cfg.small_screen_max_width;
        }
    }
    return false;
}

/// Re-evaluate Small Screen Mode against the current display and rewrite
/// workspace layouts accordingly. Returns true if any workspace changed (the
/// caller re-flushes). Called after config load and on every display
/// reconfiguration (clamshell, dock/undock) — the moments "which screen am I
/// on" can change.
pub fn applySmallScreenMode(app: *state.AppState) bool {
    const cfg = g_config orelse return false;
    if (!cfg.small_screen_enabled) return false;
    const root = app.tree orelse return false;
    const peek: u32 = if (cfg.small_screen_tabs) 0 else @intFromFloat(@max(0, cfg.accordion_padding));
    const normal_peek: u32 = @intFromFloat(@max(0, cfg.accordion_padding));
    return applySmallLayoutToTree(root, isSmallScreen(cfg), cfg.small_screen_layout, peek, normal_peek);
}

/// The tree rewrite behind `applySmallScreenMode`, OS-free for testability.
/// Entering small mode moves workspaces from the stock `.H_SPLIT` to `layout`
/// (with `small_peek` as the accordion fan — 0 for the tabs variant), marking
/// them `auto_small`; leaving it reverts exactly the marked ones. A layout the
/// user picked by hand (float, v_split, a manual accordion — anything via
/// `agate.layout`, which clears the mark) survives mode flips. Returns true if
/// anything changed.
fn applySmallLayoutToTree(con: *data.Con, small: bool, layout: data.Layout, small_peek: u32, normal_peek: u32) bool {
    var changed = false;
    if (con.con_type == .Workspace) {
        if (small and con.layout == .H_SPLIT) {
            con.layout = layout;
            con.gaps.accordion = small_peek;
            con.auto_small = true;
            changed = true;
        } else if (!small and con.auto_small) {
            con.layout = .H_SPLIT;
            con.gaps.accordion = normal_peek;
            con.auto_small = false;
            changed = true;
        }
    }
    for (con.children.items) |child| {
        if (applySmallLayoutToTree(child, small, layout, small_peek, normal_peek)) changed = true;
    }
    return changed;
}

/// State for the in-progress swipe's Liquid Glass arrow (the browser-style
/// back/forward affordance). The arrow only appears once the swipe has travelled
/// far enough to commit, and only for a direction the user actually bound.
var g_gesture_fingers: u8 = 0;
var g_gesture_axis: gestures.Axis = .horizontal;
var g_arrow_dir: ?gestures.Swipe = null;

/// Progress (normalized so ±1 == "far enough to commit") at which the arrow
/// appears, and the lower point at which it retracts — a little hysteresis so it
/// can't flicker when you hover right on the line.
const arrow_reveal: f32 = 1.0;
const arrow_conceal: f32 = 0.85;

/// True if a binding matches `fingers` + `dir` exactly.
fn gestureDirBound(cfg: *Config, fingers: u8, dir: gestures.Swipe) bool {
    for (cfg.gesture_bindings.items) |b| {
        if (b.fingers == fingers and b.dir == dir) return true;
    }
    return false;
}

/// Whether any 4-finger swipe is bound, used to decide whether to warn about the
/// conflicting native macOS gesture (see `wm/observer.zig`).
pub fn hasFourFingerGesture() bool {
    const cfg = g_config orelse return false;
    for (cfg.gesture_bindings.items) |b| if (b.fingers == 4) return true;
    return false;
}

/// The swipe direction for an axis + sign (progress is +right/+up).
fn dirOf(axis: gestures.Axis, positive: bool) gestures.Swipe {
    return switch (axis) {
        .horizontal => if (positive) .right else .left,
        .vertical => if (positive) .up else .down,
    };
}

/// Map a recognizer direction to the HUD's arrow direction. The arrow points
/// *against* the swipe and hugs the opposite edge — swipe right, a back-chevron
/// appears on the left, like Safari/Chrome's two-finger back/forward affordance.
fn hudDir(d: gestures.Swipe) macos.glass_hud.Dir {
    return switch (d) {
        .left => .right,
        .right => .left,
        .up => .down,
        .down => .up,
    };
}

/// Gesture lifecycle (main run loop; see `wm/gestures.zig`). A swipe begins once
/// it clears the deadzone; we just remember its axis and finger count. On
/// `update` we show or hide the edge arrow as the swipe crosses the commit
/// threshold, and on `end` we tear the arrow down and — if the swipe committed —
/// fire the bound action exactly once.
pub fn gestureBegin(fingers: u8, axis: gestures.Axis) void {
    g_gesture_fingers = fingers;
    g_gesture_axis = axis;
    g_arrow_dir = null;
}

pub fn gestureUpdate(fingers: u8, progress: f32) void {
    const cfg = g_config orelse return;
    // The peak finger count can climb after `begin` (a 4-finger swipe that
    // started as 3), so keep the HUD's notion of it current each frame.
    g_gesture_fingers = fingers;
    const mag = @abs(progress);
    const positive = progress >= 0;

    if (g_arrow_dir) |cur| {
        // Retract if we've fallen back under the threshold or reversed past
        // center — then fall through so a reversal can re-show the other way.
        const cur_positive = cur == .right or cur == .up;
        if (mag < arrow_conceal or positive != cur_positive) {
            macos.glass_hud.hide();
            g_arrow_dir = null;
        } else return;
    }
    if (mag >= arrow_reveal) {
        const dir = dirOf(g_gesture_axis, positive);
        if (gestureDirBound(cfg, g_gesture_fingers, dir)) {
            macos.glass_hud.show(hudDir(dir));
            g_arrow_dir = dir;
        }
    }
}

pub fn gestureEnd(fingers: u8, dir: ?gestures.Swipe) void {
    if (g_arrow_dir != null) macos.glass_hud.hide();
    g_arrow_dir = null;
    if (dir) |d| _ = handleGesture(fingers, d);
}

/// Dispatch a committed trackpad swipe against the registered gesture bindings
/// (`agate.gesture`). Runs on the main run loop (see `wm/gestures.zig` for the
/// marshalling) — safe to call Lua and the tree. Returns true if a binding
/// matched.
pub fn handleGesture(fingers: u8, dir: gestures.Swipe) bool {
    const cfg = g_config orelse return false;
    for (cfg.gesture_bindings.items) |b| {
        if (b.fingers != fingers or b.dir != dir) continue;
        switch (b.action) {
            .lua_fn => |r| {
                _ = cfg.lua.getIndexRaw(zlua.registry_index, r);
                cfg.lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
                    std.debug.print("[config] gesture binding error: {}\n", .{err});
                };
            },
            .cmd => |cmd| executeCommand(cmd),
        }
        return true;
    }
    return false;
}

pub fn deinit(cfg: *Config) void {
    for (cfg.bindings.items) |b| {
        switch (b.action) {
            .lua_fn => |r| cfg.lua.unref(zlua.registry_index, r),
            .cmd => |s| cfg.alloc.free(s),
        }
    }
    cfg.bindings.deinit(cfg.alloc);
    for (cfg.gesture_bindings.items) |b| {
        switch (b.action) {
            .lua_fn => |r| cfg.lua.unref(zlua.registry_index, r),
            .cmd => |s| cfg.alloc.free(s),
        }
    }
    cfg.gesture_bindings.deinit(cfg.alloc);
    for (cfg.modes.items) |*m| {
        for (m.bindings.items) |b| {
            switch (b.action) {
                .lua_fn => |r| cfg.lua.unref(zlua.registry_index, r),
                .cmd => |s| cfg.alloc.free(s),
            }
        }
        m.bindings.deinit(cfg.alloc);
        cfg.alloc.free(m.name);
    }
    cfg.modes.deinit(cfg.alloc);
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

/// Whether the menu-bar space indicator is enabled (config `space_indicator`).
pub fn spaceIndicatorEnabled() bool {
    const cfg = g_config orelse return true;
    return cfg.space_indicator;
}

/// Whether the drag-preview overlay is enabled (config `drag_preview`).
pub fn dragPreviewEnabled() bool {
    const cfg = g_config orelse return true;
    return cfg.drag_preview;
}

/// Cheap test: does any registered binding match this chord? Called from inside
/// the keyboard event tap to decide whether to swallow the keystroke, without
/// running the (slow) action — the action runs deferred via `handleKey`.
pub fn matchBinding(keycode: u16, raw_flags: u64) bool {
    const cfg = g_config orelse return false;
    const mods = raw_flags & MOD_MASK;
    // In a mode the global keymap is suppressed: only the mode's own chords are
    // swallowed; anything else falls through to the focused app (Hyprland submap).
    const set = if (cfg.active_mode) |mi| cfg.modes.items[mi].bindings.items else cfg.bindings.items;
    for (set) |b| {
        if (b.keycode == keycode and b.modifiers == mods) return true;
    }
    return false;
}

/// Run a binding's action: call its Lua function or execute its string command.
fn runAction(cfg: *Config, action: BindingAction) void {
    switch (action) {
        .lua_fn => |r| {
            _ = cfg.lua.getIndexRaw(zlua.registry_index, r);
            cfg.lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
                std.debug.print("[config] keybinding error: {}\n", .{err});
            };
        },
        .cmd => |cmd| executeCommand(cmd),
    }
}

/// Dispatch a key event against registered bindings. Returns true if the
/// event was handled and should be swallowed. Call from the keyboard event tap.
/// While a mode is active only its bindings are consulted (see `matchBinding`).
pub fn handleKey(keycode: u16, raw_flags: u64) bool {
    const cfg = g_config orelse return false;
    const mods = raw_flags & MOD_MASK;
    const set = if (cfg.active_mode) |mi| cfg.modes.items[mi].bindings.items else cfg.bindings.items;
    for (set) |b| {
        if (b.keycode != keycode or b.modifiers != mods) continue;
        runAction(cfg, b.action);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// @doc A|agate.Direction|A focus/move/resize direction.
// @doc AV|agate.Direction|left
// @doc AV|agate.Direction|right
// @doc AV|agate.Direction|up
// @doc AV|agate.Direction|down
fn parseDir(s: []const u8) ?focus.Direction {
    if (std.mem.eql(u8, s, "left"))  return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up"))    return .up;
    if (std.mem.eql(u8, s, "down"))  return .down;
    return null;
}

// @doc A|agate.MonitorDir|A monitor selector: `next`/`prev` cycle displays in window-server order; `left`/`right`/`up`/`down` step to the physically adjacent display.
// @doc AV|agate.MonitorDir|next
// @doc AV|agate.MonitorDir|prev
// @doc AV|agate.MonitorDir|left
// @doc AV|agate.MonitorDir|right
// @doc AV|agate.MonitorDir|up
// @doc AV|agate.MonitorDir|down
fn parseMonitorDir(s: []const u8) ?focus.MonitorDir {
    if (std.mem.eql(u8, s, "next")) return .next;
    if (std.mem.eql(u8, s, "prev") or std.mem.eql(u8, s, "previous")) return .prev;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "down")) return .down;
    return null;
}

// String commands accepted as the second argument of `agate.bind`.
// @doc C|move <dir>|Same as `agate.move(dir)`.
// @doc C|focus <dir>|Same as `agate.focus(dir)`.
// @doc C|cycle <next|prev>|Same as `agate.cycle(dir)`.
// @doc C|layout <mode>|Same as `agate.layout(mode)`.
// @doc C|space <n>|Same as `agate.space(n)`.
// @doc C|move_to_space <n>|Same as `agate.move_to_space(n)`.
// @doc C|focus_monitor <dir>|Same as `agate.focus_monitor(dir)`.
// @doc C|move_to_monitor <dir>|Same as `agate.move_to_monitor(dir)`.
// @doc C|exec <cmd>|Run a shell command in the background through `$SHELL -c`. Same as `agate.exec(cmd)`.
// @doc C|zoom_fullscreen|Same as `agate.zoom_fullscreen()`.
// @doc C|mode <name>|Same as `agate.enter_mode(name)`.
// @doc C|exit_mode|Same as `agate.exit_mode()`.
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
    } else if (std.mem.startsWith(u8, cmd, "cycle ")) {
        const arg = cmd[6..];
        const forward = !(std.mem.eql(u8, arg, "prev") or std.mem.eql(u8, arg, "previous") or
            std.mem.eql(u8, arg, "back") or std.mem.eql(u8, arg, "backward"));
        _ = focus.cycleFocus(app, forward);
    } else if (std.mem.startsWith(u8, cmd, "layout ")) {
        setActiveLayout(app, cmd[7..]);
    } else if (std.mem.startsWith(u8, cmd, "space ")) {
        const n = std.fmt.parseInt(usize, cmd[6..], 10) catch return;
        macos.spaces.switchToIndex(app.gpa, app.skylight_cid, n) catch {};
    } else if (std.mem.startsWith(u8, cmd, "move_to_space ")) {
        const n = std.fmt.parseInt(usize, cmd[14..], 10) catch return;
        moveFocusedToSpace(app, n);
    } else if (std.mem.startsWith(u8, cmd, "focus_monitor ")) {
        const dir = parseMonitorDir(cmd[14..]) orelse return;
        _ = focus.focusMonitor(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "move_to_monitor ")) {
        const dir = parseMonitorDir(cmd[16..]) orelse return;
        moveFocusedToMonitor(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "mode ")) {
        if (g_config) |cfg| enterModeByName(cfg, cmd[5..]);
    } else if (std.mem.eql(u8, cmd, "exit_mode")) {
        if (g_config) |cfg| exitActiveMode(cfg);
    } else if (std.mem.eql(u8, cmd, "zoom_fullscreen")) {
        toggleZoomFullscreen(app);
    } else if (std.mem.startsWith(u8, cmd, "exec ")) {
        spawnShell(app.gpa, cmd[5..]);
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

test "parseGestureSpec parses finger count and direction" {
    const p = parseGestureSpec("3:left").?;
    try testing.expectEqual(@as(u8, 3), p.fingers);
    try testing.expectEqual(gestures.Swipe.left, p.dir);

    const q = parseGestureSpec("swipe+4+up").?; // alternate separators, swipe token
    try testing.expectEqual(@as(u8, 4), q.fingers);
    try testing.expectEqual(gestures.Swipe.up, q.dir);

    const r = parseGestureSpec("right:3").? ; // order-insensitive
    try testing.expectEqual(gestures.Swipe.right, r.dir);

    try testing.expect(parseGestureSpec("2:left") == null); // 2 fingers is scrolling
    try testing.expect(parseGestureSpec("5:left") == null); // unsupported count
    try testing.expect(parseGestureSpec("3") == null); // no direction
    try testing.expect(parseGestureSpec("3:sideways") == null); // bad direction
}

test "applySmallLayoutToTree flips default workspaces in and out of small mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try alloc.create(data.Con);
    root.* = .{ .id = 0, .con_type = .Root };
    const ws_default = try alloc.create(data.Con);
    ws_default.* = .{ .id = 1, .con_type = .Workspace, .parent = root };
    ws_default.gaps.accordion = 40;
    const ws_manual = try alloc.create(data.Con);
    ws_manual.* = .{ .id = 2, .con_type = .Workspace, .parent = root, .layout = .FLOAT };
    try root.children.append(alloc, ws_default);
    try root.children.append(alloc, ws_manual);

    // Enter small mode (tabs variant: zero peek): only the default ws changes.
    try testing.expect(applySmallLayoutToTree(root, true, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_STACK, ws_default.layout);
    try testing.expect(ws_default.auto_small);
    try testing.expectEqual(@as(u32, 0), ws_default.gaps.accordion);
    try testing.expectEqual(data.Layout.FLOAT, ws_manual.layout);

    // Already small — applying again is a no-op.
    try testing.expect(!applySmallLayoutToTree(root, true, .H_STACK, 0, 40));

    // Leave small mode: the auto-set workspace reverts, peek restored.
    try testing.expect(applySmallLayoutToTree(root, false, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_SPLIT, ws_default.layout);
    try testing.expect(!ws_default.auto_small);
    try testing.expectEqual(@as(u32, 40), ws_default.gaps.accordion);

    // A user-chosen H_STACK (no auto_small mark) is never reverted.
    ws_manual.layout = .H_STACK;
    try testing.expect(!applySmallLayoutToTree(root, false, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_STACK, ws_manual.layout);
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
