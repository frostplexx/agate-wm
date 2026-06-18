//! The `agate.*` Lua API: one Zig C-function per call the user makes in
//! init.lua. Each function does Lua-stack ⇆ Zig marshalling and then delegates
//! to the business-logic modules (`actions`, `rules`, `keybind`, `exec`, …) —
//! it holds no window-management logic of its own. The `// @doc F|`/`FP|` lines
//! here (and `S|`/`SS|` inside `agateConfig`) generate the API reference.
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const macos = @import("macos");
const focus = @import("../wm/focus/focus.zig");
const tree = @import("../wm/tree.zig");
const data = @import("../wm/data.zig");
const regexp = @import("../lib/regexp.zig");
const gestures = @import("../wm/gestures.zig");
const wm_layout = @import("../wm/layout.zig");
const wm_animate = @import("../wm/animate.zig");

const types = @import("types.zig");
const ctx = @import("context.zig");
const parse = @import("parse.zig");
const actions = @import("actions.zig");
const rules = @import("rules.zig");
const keybind = @import("keybind.zig");
const exec = @import("exec.zig");
const events = @import("events.zig");

const Rule = types.Rule;
const Mode = types.Mode;
const MOD_SHIFT = types.MOD_SHIFT;
const MOD_CTRL = types.MOD_CTRL;
const MOD_ALT = types.MOD_ALT;
const MOD_CMD = types.MOD_CMD;

// ---------------------------------------------------------------------------
// Lua table-field readers
// ---------------------------------------------------------------------------

/// Read the numeric field `name` from the config table (stack index 1) into
/// `dst`. Returns whether the field was present and numeric; `dst` is left
/// unchanged otherwise.
fn numberField(lua: *Lua, name: [:0]const u8, dst: *f64) bool {
    return numberFieldAt(lua, 1, name, dst);
}

/// Like `numberField`, but reads the field from the table at stack index `idx`
/// (used for the grouped `gaps`/`columns` sub-tables).
fn numberFieldAt(lua: *Lua, idx: i32, name: [:0]const u8, dst: *f64) bool {
    _ = lua.getField(idx, name);
    defer lua.pop(1);
    if (!lua.isNumber(-1)) return false;
    dst.* = lua.toNumber(-1) catch return false;
    return true;
}

/// Normalise an animation duration to milliseconds. The knob used to be in
/// seconds; a sub-5 value can only be the old unit (a 5 ms animation is
/// invisible), so convert it instead of silently disabling animations for
/// configs written against the old docs.
fn normalizeAnimMs(v: f64) f64 {
    if (v > 0 and v < 5) {
        std.debug.print("[config] animation duration is in milliseconds now; treating {d} as {d} ms\n", .{ v, v * 1000 });
        return v * 1000;
    }
    return v;
}

/// Read the boolean field `name` from the table at `idx` into `dst` (left
/// unchanged when absent or non-boolean).
fn boolField(lua: *Lua, idx: i32, name: [:0]const u8, dst: *bool) void {
    _ = lua.getField(idx, name);
    defer lua.pop(1);
    if (lua.isBoolean(-1)) dst.* = lua.toBoolean(-1);
}

/// Replace `cfg.preset_column_widths` from the field `name` of the table at
/// stack index `idx` (an array of numbers, each a viewport fraction). Left
/// unchanged when absent; an empty or all-invalid list is rejected so
/// `agate.column_width` always has something to cycle. The old slice is freed
/// and a fresh one allocated from `cfg.alloc`.
fn parsePresetWidths(lua: *Lua, idx: i32, name: [:0]const u8, cfg: *types.Config) void {
    _ = lua.getField(idx, name);
    defer lua.pop(1);
    if (!lua.isTable(-1)) return;

    var vals: [16]f64 = undefined;
    var count: usize = 0;
    var i: zlua.Integer = 1;
    while (count < vals.len) : (i += 1) {
        _ = lua.getIndex(-1, i);
        defer lua.pop(1);
        if (lua.isNil(-1)) break;
        if (lua.isNumber(-1)) {
            const v = lua.toNumber(-1) catch continue;
            if (v > 0 and v <= 1.0) {
                vals[count] = v;
                count += 1;
            }
        }
    }
    if (count == 0) return; // keep the existing presets rather than empty them

    const slice = cfg.alloc.alloc(f64, count) catch return;
    @memcpy(slice, vals[0..count]);
    cfg.alloc.free(cfg.preset_column_widths);
    cfg.preset_column_widths = slice;
}

// ---------------------------------------------------------------------------
// agate.* functions
// ---------------------------------------------------------------------------

// @doc F|config|Apply global configuration. Call once near the top of init.lua.
// @doc FP|config|config|agate.Config|false|Settings table (see agate.Config).
fn agateConfig(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    if (!lua.isTable(1)) return 0;
    // gaps: a bare number sets both the inner and outer gap; a table
    // `{ inner, outer, smart }` sets each. The pre-grouping flat keys
    // (`outer_gaps`, `smart_gaps`) are still honoured below for back-compat.
    // @doc S|gaps|number\|table|8|Pixels between tiles. A number sets both the inner gap and the screen-edge inset; a table `{ inner, outer, smart }` sets them separately (`smart` drops the outer gap when a workspace holds a single window).
    _ = lua.getField(1, "gaps");
    if (lua.isNumber(-1)) {
        const g = lua.toNumber(-1) catch cfg.gaps;
        cfg.gaps = g;
        cfg.outer_gaps = g;
    } else if (lua.isTable(-1)) {
        const gi = lua.getTop();
        _ = numberFieldAt(lua, gi, "inner", &cfg.gaps);
        _ = numberFieldAt(lua, gi, "outer", &cfg.outer_gaps);
        boolField(lua, gi, "smart", &cfg.smart_gaps);
    }
    lua.pop(1);
    _ = numberField(lua, "outer_gaps", &cfg.outer_gaps); // back-compat flat key
    // Window peek: "peek" is the name; "accordion_padding"/"accordion" are kept as
    // back-compat aliases. Drives both the accordion fan and the strip edge peek.
    if (!numberField(lua, "peek", &cfg.peek)) {
        if (!numberField(lua, "accordion_padding", &cfg.peek)) {
            _ = numberField(lua, "accordion", &cfg.peek);
        }
    }
    // hyper_key: { enabled = bool, keys = {modifier strings} }. The built-in
    // hyper key (ported from LazyKeys): `enabled` toggles the Caps Lock → F18
    // remap, `keys` is the modifier set the held key (and the `hyper` macro)
    // expands to.
    // @doc HK|enabled|boolean|true|Master switch (default `true`). When on, agate remaps Caps Lock to F18 via `hidutil` and treats it as the hyper key; the remap is restored on exit. Turn it off to leave Caps Lock alone.
    // @doc HK|keys|string[]|true|Modifier set the held hyper key — and the `hyper` macro in key specs — expands to. Any of: `ctrl`/`control`, `alt`/`opt`, `cmd`/`command`, `shift`. Default `{"ctrl","alt","cmd","shift"}`.
    _ = lua.getField(1, "hyper_key");
    if (lua.isTable(-1)) {
        _ = lua.getField(-1, "enabled");
        if (lua.isBoolean(-1)) cfg.hyper_enabled = lua.toBoolean(-1);
        lua.pop(1);
        _ = lua.getField(-1, "keys");
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
        lua.pop(1); // keys
    }
    lua.pop(1); // hyper_key
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
            } else if (parse.layoutFromName(s)) |l| {
                cfg.small_screen_layout = l;
                cfg.small_screen_tabs = false;
            } else {
                std.debug.print("[config] small_screen: unknown layout {s}\n", .{s});
            }
        }
        lua.pop(1);
    }
    lua.pop(1);
    // animations: `true`/`false`, or a number giving the per-frame duration in
    // milliseconds (which also enables them). `animation_duration` is kept as a
    // back-compat key for the duration alone.
    // @doc S|animations|boolean\|number|false|Animate tiling frame changes instead of snapping (the size applies instantly, the position glides). `true`/`false` toggles it at the default speed; a number sets the per-frame duration in **milliseconds** and enables it (lower = snappier, `0` = off).
    _ = lua.getField(1, "animations");
    if (lua.isBoolean(-1)) {
        cfg.animations = lua.toBoolean(-1);
    } else if (lua.isNumber(-1)) {
        const d = normalizeAnimMs(lua.toNumber(-1) catch 0);
        cfg.animations = d > 0;
        wm_animate.duration_ms = @max(0, d);
    }
    lua.pop(1);
    var anim_dur: f64 = wm_animate.duration_ms;
    if (numberField(lua, "animation_duration", &anim_dur)) // back-compat key
        wm_animate.duration_ms = @max(0, normalizeAnimMs(anim_dur));
    wm_layout.animate = cfg.animations;
    boolField(lua, 1, "space_indicator", &cfg.space_indicator);
    boolField(lua, 1, "drag_preview", &cfg.drag_preview);
    boolField(lua, 1, "smart_gaps", &cfg.smart_gaps); // back-compat flat key
    wm_layout.smart_gaps = cfg.smart_gaps;
    // columns: Flow strip tuning grouped as `{ default_width, min_width, presets }`.
    // The pre-grouping flat keys (`default_column_width`, …) still work below.
    // @doc S|columns|table|{ default_width = 0.5, min_width = 0.22, presets = { 0.333, 0.5, 0.667, 1.0 } }|Flow strip tuning. `default_width` (0–1): the viewport fraction a freshly opened column targets. `min_width` (0–1): the soft bound — while every column fits at this width the strip tiles the whole screen, past that it scrolls (so it sets on-screen capacity, ≈`floor(1/min_width)`). `presets`: the widths `agate.column_width` cycles and the `"1/3"`/`"1/2"`/`"2/3"`/`"full"` names snap to.
    _ = lua.getField(1, "columns");
    if (lua.isTable(-1)) {
        const ci = lua.getTop();
        _ = numberFieldAt(lua, ci, "default_width", &cfg.default_column_width);
        _ = numberFieldAt(lua, ci, "min_width", &cfg.min_column_width);
        parsePresetWidths(lua, ci, "presets", cfg);
    }
    lua.pop(1);
    // Back-compat flat keys.
    _ = numberField(lua, "default_column_width", &cfg.default_column_width);
    _ = numberField(lua, "min_column_width", &cfg.min_column_width);
    parsePresetWidths(lua, 1, "preset_column_widths", cfg);
    // Clamp to sane ranges so a bad value can't wedge the layout (a 0 min width
    // would make capacity infinite again).
    cfg.default_column_width = std.math.clamp(cfg.default_column_width, 0.1, 1.0);
    cfg.min_column_width = std.math.clamp(cfg.min_column_width, 0.05, 1.0);
    var swipe_fingers: f64 = @floatFromInt(cfg.swipe_scroll_fingers);
    if (numberField(lua, "swipe_scroll_fingers", &swipe_fingers))
        cfg.swipe_scroll_fingers = @intFromFloat(std.math.clamp(swipe_fingers, 0, 5));
    wm_layout.default_column_width = cfg.default_column_width;
    wm_layout.min_column_width = cfg.min_column_width;
    // The strip's off-screen edge peek is the same "peek" as the accordion fan.
    wm_layout.scroll_sliver = cfg.peek;
    // Arm the gesture pipeline's scroll-swallowing when live strip scrolling is
    // on, so a swipe drag doesn't also scroll the window underneath — even when
    // the user has bound no `agate.gesture` (which is the usual trigger).
    if (cfg.swipe_scroll_fingers != 0) gestures.g_enabled.store(true, .release);
    // Apply gaps to every workspace in the tree
    if (ctx.appstate) |app| if (app.tree) |root| actions.applyGapsToTree(root, cfg.gaps, cfg.outer_gaps, cfg.peek);
    return 0;
}

// @doc F|bind|Bind a key chord to an action.
// @doc FP|bind|spec|string|false|Key chord, e.g. `"hyper+shift+l"`.
// @doc FP|bind|action|fun()|string|false|A Lua callback, or a string command (see Commands below).
fn agateBind(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    const spec_z = lua.toString(1) catch return 0;
    const spec = std.mem.sliceTo(spec_z, 0);

    const parsed = parse.parseKeySpec(spec, cfg.hyper_mods) orelse {
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

/// `agate.gesture(spec, action)` — bind an N-finger trackpad swipe (e.g.
/// `"3:left"`) to a Lua function or string command, like `agate.bind` does for
/// key chords. The swipe tracks continuously with a Liquid Glass HUD and the
/// action commits once on lift — either by dragging far enough or by flicking
/// fast, like native macOS space switching.
// @doc F|gesture|Bind a trackpad swipe to an action. The swipe tracks live with a Liquid Glass HUD and fires once when you lift — drag far enough or flick fast, like native macOS. The system gestures on the same finger count must be off or moved to the other count in Trackpad settings.
// @doc FP|gesture|spec|string|false|Finger count (3 or 4) and direction, e.g. `"3:left"` or `"4:up"`.
// @doc FP|gesture|action|fun()|string|false|A Lua callback, or a string command (see Commands below).
fn agateGesture(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    const spec_z = lua.toString(1) catch return 0;
    const spec = std.mem.sliceTo(spec_z, 0);

    const parsed = parse.parseGestureSpec(spec) orelse {
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

/// `agate.on(event, callback)` — run a Lua function whenever agate performs the
/// named action (a Space change, mode switch, window create/destroy). The
/// callback gets a single table argument describing the event (see the event
/// list in the doc comment). Unlike `agate.bind`, the trigger is a WM event, not
/// a key chord — so init.lua can react to things agate does on its own. Several
/// callbacks may be registered for the same event; all run, in registration order.
// @doc F|on|Run a Lua callback whenever agate performs an action. The callback receives a single table describing the event. Register more than one for the same event and they all run, in order. Events: `space_changed` (`{ space = N }` — the new 1-based Space position), `mode_changed` (`{ mode = "name" }` on enter, `{ mode = nil }` on exit), `window_created` / `window_destroyed` (`{ window = id }`). Use it to e.g. run a shell command on every Space switch via `agate.exec`.
// @doc FP|on|event|string|false|Event name: `"space_changed"`, `"mode_changed"`, `"window_created"`, or `"window_destroyed"`.
// @doc FP|on|callback|fun(event:table)|false|A Lua function called with a table of event data (fields depend on the event).
fn agateOn(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    const name = std.mem.sliceTo(name_z, 0);
    const event = events.Event.fromName(name) orelse {
        std.debug.print("[config] agate.on: unknown event '{s}'\n", .{name});
        return 0;
    };
    if (!lua.isFunction(2)) {
        std.debug.print("[config] agate.on('{s}', ...): second argument must be a function\n", .{name});
        return 0;
    }
    lua.pushValue(2);
    const fn_ref = lua.ref(zlua.registry_index);
    cfg.event_handlers.append(cfg.alloc, .{ .event = event, .lua_fn = fn_ref }) catch {
        lua.unref(zlua.registry_index, fn_ref);
    };
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
    const cfg = ctx.config orelse return 0;
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
        const parsed = parse.parseKeySpec(spec, cfg.hyper_mods) orelse {
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

/// `agate.enter_mode(name)` — switch into a mode defined with `agate.mode`.
// @doc F|enter_mode|Activate a mode defined with `agate.mode`. While active, only that mode's bindings fire; global binds are suppressed and unbound keys pass through. The active mode name shows in the menu-bar indicator.
// @doc FP|enter_mode|name|string|false|Name of a mode registered with `agate.mode`.
fn agateEnterMode(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    keybind.enterModeByName(cfg, std.mem.sliceTo(name_z, 0));
    return 0;
}

/// `agate.exit_mode()` — leave the active mode, back to the normal keymap.
// @doc F|exit_mode|Leave the active mode and return to the normal keymap. Bind this to `escape` inside a mode so there's always a way out.
fn agateExitMode(_: *Lua) i32 {
    if (ctx.config) |cfg| keybind.exitActiveMode(cfg);
    return 0;
}

// @doc F|focus|Move keyboard focus. A direction (`left`/`right`/`up`/`down`) moves to the nearest window that way, descending into and ascending out of nested containers (i3-style; left/right traverse horizontal splits/stacks, up/down vertical ones). `"next"`/`"prev"` instead cycle through the focused window's siblings, wrapping at the edges — the natural motion through an accordion/stack.
// @doc FP|focus|target|agate.Direction|string|false|A direction to move focus, or `"next"`/`"prev"` to cycle siblings.
fn agateFocus(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const s = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
    if (std.mem.eql(u8, s, "next") or std.mem.eql(u8, s, "prev") or std.mem.eql(u8, s, "previous")) {
        const forward = !(std.mem.eql(u8, s, "prev") or std.mem.eql(u8, s, "previous"));
        _ = focus.cycleFocus(app, forward);
        return 0;
    }
    const dir = parse.parseDir(s) orelse return 0;
    _ = focus.focusDirection(app, dir);
    return 0;
}

// @doc F|layout|Set the focused container's layout (the focused window's parent), falling back to the workspace for top-level windows.
// @doc FP|layout|mode|agate.Layout|false|Layout mode to apply.
fn agateLayout(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const name_z = lua.toString(1) catch return 0;
    actions.setActiveLayout(app, std.mem.sliceTo(name_z, 0));
    return 0;
}

/// Combine the focused window with an adjacent one into a nested container,
/// giving the workspace a mixed layout. `agate.join(dir [, layout])`: `dir` is
/// the neighbour to absorb ("left"/"right"/"up"/"down"); `layout` is the new
/// container's mode (default "v_stack" — a vertical stack).
// @doc F|join|Combine the focused window with its neighbour into a nested container, for mixed layouts (e.g. a row whose one slot is a stack of two windows).
// @doc FP|join|dir|agate.Direction|false|Neighbour to combine with.
// @doc FP|join|mode|agate.Layout|true|Layout of the new container. Default `v_stack`.
fn agateJoin(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    var layout: data.Layout = .V_STACK;
    if (lua.isString(2)) {
        const lz = lua.toString(2) catch "";
        if (parse.layoutFromName(std.mem.sliceTo(lz, 0))) |l| layout = l;
    }
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.joinWithNeighbor(app.arena, leaf, forward, layout)) |_| {
        tree.flushActive(app);
        _ = focus.focusLeaf(leaf); // keep the joined window focused and raised
    }
    return 0;
}

// @doc F|toggle|Toggle a state on the focused window. `"fullscreen"` (yabai's zoom-fullscreen) makes it fill the whole space over the other tiles, with no Space transition; `"float"` lifts it out of the tiling to keep its own free position and size on top while the rest reflow. Toggle again to undo; the window stays on the same Space, tracked and focusable, either way.
// @doc FP|toggle|what|string|false|`"fullscreen"` or `"float"`.
fn agateToggle(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const s = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
    if (std.mem.eql(u8, s, "fullscreen") or std.mem.eql(u8, s, "zoom") or std.mem.eql(u8, s, "zoom_fullscreen")) {
        actions.toggleZoomFullscreen(app);
    } else if (std.mem.eql(u8, s, "float") or std.mem.eql(u8, s, "floating")) {
        actions.toggleFloat(app);
    } else {
        std.debug.print("[config] toggle: unknown target '{s}' (want \"fullscreen\" or \"float\")\n", .{s});
    }
    return 0;
}

// @doc F|column_width|Flow strip: set or cycle the focused column's width. `"wider"`/`"narrower"` (aliases `"next"`/`"prev"`) step through the column presets; `"full"`, `"half"`, or a fraction like `"1/3"`/`"2/3"` set it directly; `"fit"` re-equalizes *every* column so they tile the viewport evenly (balanced classic tiling, undoing manual widths). Only `"fit"` touches the neighbours — the rest change just the focused column.
// @doc FP|column_width|target|string|false|`"wider"`/`"narrower"`/`"next"`/`"prev"`, `"fit"`, or a width: `"full"`, `"half"`, `"1/3"`, `"1/2"`, `"2/3"`, a fraction `"a/b"`, or a number (`0.4`, or `40` for 40%).
fn agateColumnWidth(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const t = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
    if (std.mem.eql(u8, t, "fit") or std.mem.eql(u8, t, "equal") or std.mem.eql(u8, t, "equalize")) {
        actions.fitColumns(app);
        return 0;
    }
    actions.cycleColumnWidth(app, t);
    return 0;
}

// @doc F|scroll|Flow strip: scroll or jump along the strip. `"left"`/`"right"` step focus to the adjacent column (auto-scrolling it into view), `"start"`/`"end"` focus the first/last column, `"center"` centers the focused column.
// @doc FP|scroll|target|"left"|"right"|"start"|"end"|"center"|false|Where to scroll.
fn agateScroll(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const t_z = lua.toString(1) catch return 0;
    actions.scrollStrip(app, std.mem.sliceTo(t_z, 0));
    return 0;
}

// @doc F|consume|Flow strip: pull the adjacent column into the focused column, merging the two into a single vertical split (niri's "consume into column"). The focused window stays focused.
// @doc FP|consume|dir|agate.Direction|false|Which neighbour column to absorb.
fn agateConsume(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    actions.consume(app, dir);
    return 0;
}

// @doc F|expel|Flow strip: eject the focused window out of its column into its own column on the strip (the inverse of `consume`).
// @doc FP|expel|dir|agate.Direction|false|`"left"` ejects before the column, otherwise after it.
fn agateExpel(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    actions.expel(app, dir);
    return 0;
}

// @doc F|exec|Run a shell command in the background, like skhd's `:` commands. The command line is handed to `$SHELL -c` (falling back to `/bin/sh -c`), so pipes, globs, and `&&` all work. agate does not wait for it — use it to launch apps or scripts from a keybind.
// @doc FP|exec|cmd|string|false|The shell command line to run.
fn agateExec(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const cmd_z = lua.toString(1) catch return 0;
    exec.spawnShell(app.gpa, cmd_z);
    return 0;
}

// @doc F|space|Switch Space on the focused display: a 1-based position jumps there directly, or `"next"`/`"prev"` step one Space over. Counts every Space in Mission Control order, including native-fullscreen Spaces (so a fullscreened app at strip position N is reached by N).
// @doc FP|space|target|integer|string|false|A 1-based Space position (Mission Control order, fullscreen Spaces included), or `"next"`/`"prev"` to step.
fn agateSpace(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    if (lua.isString(1)) {
        const s = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
        if (std.mem.eql(u8, s, "next")) {
            macos.spaces.switchNext(app.gpa, app.skylight_cid) catch {};
        } else if (std.mem.eql(u8, s, "prev") or std.mem.eql(u8, s, "previous")) {
            macos.spaces.switchPrev(app.gpa, app.skylight_cid) catch {};
        }
        return 0;
    }
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    macos.spaces.switchToIndex(app.gpa, app.skylight_cid, @intCast(n)) catch {};
    return 0;
}

// @doc F|resize|Resize the focused tile, transferring the delta to its neighbour. Pass `"smart"` (recommended) to resize along the focused window's container axis without picking an edge: a positive `amount` grows it, a negative one shrinks it, taking from whichever neighbour exists — so the same binding always enlarges/shrinks the focused window wherever it sits. A direction (`left`/`right`/`up`/`down`) instead grows the window toward that edge, by stealing from the neighbour there.
// @doc FP|resize|target|agate.Direction|string|false|`"smart"` to resize along the container axis, or an edge (`left`/`right`/`up`/`down`) to grow toward.
// @doc FP|resize|amount|number|true|Pixels to resize by. Default 50. With `"smart"`, a negative value shrinks.
fn agateResize(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const target_z = lua.toString(1) catch return 0;
    const target = std.mem.sliceTo(target_z, 0);
    const amount = lua.toNumber(2) catch 50.0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    if (std.mem.eql(u8, target, "smart")) {
        if (tree.resizeLeafSmart(leaf, @floatCast(amount))) tree.flushActive(app);
        return 0;
    }
    const dir = parse.parseDir(target) orelse return 0;
    const grow = dir == .right or dir == .down;
    if (tree.resizeLeaf(leaf, grow, @floatCast(amount))) tree.flushActive(app);
    return 0;
}

// @doc F|move|Move the focused window. A direction (`left`/`right`/`up`/`down`) swaps it with its neighbour that way (across nested containers). `move("space", n [, monitor])` sends it to Space `n` (optionally on a given 1-based monitor) without following focus. `move("monitor", dir)` moves it to an adjacent display's visible Space, tiles it there, and follows focus over.
// @doc FP|move|target|agate.Direction|string|false|A direction to swap toward, or `"space"`/`"monitor"` to relocate the window (see the extra args).
// @doc FP|move|arg|integer|agate.MonitorDir|true|With `"space"`: the 1-based Space position. With `"monitor"`: the display direction.
// @doc FP|move|monitor|integer|true|With `"space"`: an optional 1-based monitor the position counts on (omit for the focused display).
fn agateMove(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const s = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
    if (std.mem.eql(u8, s, "space")) {
        const n = lua.toInteger(2) catch return 0;
        if (n < 1) return 0;
        if (lua.isNumber(3)) {
            const mon = lua.toInteger(3) catch 0;
            if (mon >= 1) {
                actions.moveFocusedToSpaceOnMonitor(app, @intCast(mon), @intCast(n));
                return 0;
            }
        }
        actions.moveFocusedToSpace(app, @intCast(n));
        return 0;
    }
    if (std.mem.eql(u8, s, "monitor") or std.mem.eql(u8, s, "display")) {
        const dir = parse.parseMonitorDir(std.mem.sliceTo(lua.toString(2) catch return 0, 0)) orelse return 0;
        actions.moveFocusedToMonitor(app, dir);
        return 0;
    }
    const dir = parse.parseDir(s) orelse return 0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.swapLeaf(leaf, forward)) tree.flushActive(app);
    return 0;
}

/// `agate.focus_monitor(dir)`: move keyboard focus to another display
/// (`next`/`prev`, or `left`/`right`/`up`/`down`).
// @doc F|focus_monitor|Move keyboard focus to another display, raising its most-recently-used window (or warping the cursor to an empty display). No-op with a single display.
// @doc FP|focus_monitor|dir|agate.MonitorDir|false|Which display to focus.
fn agateFocusMonitor(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseMonitorDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    _ = focus.focusMonitor(app, dir);
    return 0;
}

/// `agate.rule{ app = "...", title = "...", space = N, follow = bool }`
/// Register a window assignment rule (yabai's `yabai -m rule --add app=...
/// space=N`). `app`/`title` are POSIX extended regexes; at least one must be
/// given. Matched windows are sent to user space N when they appear.
// @doc F|rule|Register a window assignment rule, like yabai's `rule --add`: windows whose app name/title match the given regexes are sent to a space (and optionally a specific monitor) and/or floated when they appear. At least one of `app`/`title` is required; both must match when both are given. Give `space`, `monitor`, `floating = true`, or a combination — a rule must have at least one effect. When several rules match a window, the last registered one wins.
// @doc FP|rule|rule|agate.Rule|false|Rule table (see agate.Rule).
fn agateRule(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
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

    _ = lua.getField(1, "floating");
    if (lua.isBoolean(-1)) rule.floating = lua.toBoolean(-1);
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

    if ((rule.app == null and rule.title == null) or (rule.space == 0 and !rule.floating)) {
        std.debug.print("[config] rule needs an app or title matcher, and a space/monitor or floating=true; ignored\n", .{});
        rules.freeRule(rule);
        return 0;
    }
    cfg.rules.append(cfg.alloc, rule) catch rules.freeRule(rule);
    return 0;
}

// How `// @doc` annotations work: tools/gen_docs.zig scans the config sources for
// lines beginning `// @doc ` and renders types/agate.lua plus the wiki's
// Configuration reference from them (run `zig build docs`). Each annotation lives
// directly above the code it documents. Field separator is '|'; the FP/C
// type/form fields may contain '|'.

const agate_fns = [_]zlua.FnReg{
    .{ .name = "config",      .func = zlua.wrap(agateConfig) },
    .{ .name = "bind",        .func = zlua.wrap(agateBind) },
    .{ .name = "gesture",     .func = zlua.wrap(agateGesture) },
    .{ .name = "on",          .func = zlua.wrap(agateOn) },
    .{ .name = "mode",        .func = zlua.wrap(agateMode) },
    .{ .name = "enter_mode",  .func = zlua.wrap(agateEnterMode) },
    .{ .name = "exit_mode",   .func = zlua.wrap(agateExitMode) },
    .{ .name = "focus",       .func = zlua.wrap(agateFocus) },
    .{ .name = "layout",      .func = zlua.wrap(agateLayout) },
    .{ .name = "space",       .func = zlua.wrap(agateSpace) },
    .{ .name = "resize",      .func = zlua.wrap(agateResize) },
    .{ .name = "move",        .func = zlua.wrap(agateMove) },
    .{ .name = "focus_monitor", .func = zlua.wrap(agateFocusMonitor) },
    .{ .name = "join",        .func = zlua.wrap(agateJoin) },
    .{ .name = "column_width", .func = zlua.wrap(agateColumnWidth) },
    .{ .name = "scroll",      .func = zlua.wrap(agateScroll) },
    .{ .name = "consume",     .func = zlua.wrap(agateConsume) },
    .{ .name = "expel",       .func = zlua.wrap(agateExpel) },
    .{ .name = "toggle",      .func = zlua.wrap(agateToggle) },
    .{ .name = "exec",        .func = zlua.wrap(agateExec) },
    .{ .name = "rule",        .func = zlua.wrap(agateRule) },
};

/// Install the `agate` global table into `lua` (called once from `lua.init`).
pub fn register(lua: *Lua) void {
    // Resolve printable keyspecs against the user's active keyboard layout, so
    // `minus`/`plus`/`z`/… bind the physical key that types them on non-US
    // layouts (issue #6). Done here — before init.lua's `agate.bind` calls run.
    parse.charToKeycode = macos.keyboard.keycodeForChar;
    lua.newLib(&agate_fns);
    lua.setGlobal("agate");
}
