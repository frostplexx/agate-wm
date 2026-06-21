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

// ---------------------------------------------------------------------------
// agate.* functions
// ---------------------------------------------------------------------------

// @doc F|config|Apply global configuration. Call once near the top of init.lua.
// @doc FP|config|config|agate.Config|false|Settings table (see agate.Config).
fn agateConfig(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    if (!lua.isTable(1)) return 0;
    _ = numberField(lua, "gaps", &cfg.gaps);
    _ = numberField(lua, "outer_gaps", &cfg.outer_gaps);
    // accept "accordion_padding" or the shorter "accordion"
    if (!numberField(lua, "accordion_padding", &cfg.accordion_padding))
        _ = numberField(lua, "accordion", &cfg.accordion_padding);
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
    if (ctx.appstate) |app| if (app.tree) |root| actions.applyGapsToTree(root, cfg.gaps, cfg.outer_gaps, cfg.accordion_padding);
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
// @doc F|on|Run a Lua callback whenever agate performs an action. The callback receives a single table describing the event. Register more than one for the same event and they all run, in order. Events: `space_changed` (`{ space = N }` — the new 1-based Space position), `mode_changed` (`{ mode = "name" }` on enter, `{ mode = nil }` on exit), `window_created` / `window_destroyed` (`{ window = id }`), `monitors_changed` (`{ count = N }` — a display was plugged/unplugged; inspect `agate.monitors()` to adapt the config). Use it to e.g. run a shell command on every Space switch via `agate.exec`, or re-pin apps when docking.
// @doc FP|on|event|string|false|Event name: `"space_changed"`, `"mode_changed"`, `"window_created"`, `"window_destroyed"`, or `"monitors_changed"`.
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

/// `agate.cycle("next"|"prev")` — focus the next/previous window among the
/// focused window's siblings, wrapping at the edges. The accordion motion:
/// on a small screen every window is one cycle step away.
// @doc F|cycle|Focus the next/previous window among the focused window's siblings, wrapping at the edges — the natural motion through an accordion/stack (Small Screen Mode), bindable to a swipe or a key.
// @doc FP|cycle|dir|"next"|"prev"|false|Cycle direction.
fn agateCycle(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
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
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
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

// @doc F|zoom_fullscreen|Toggle "zoom fullscreen" for the focused window (yabai's `window --toggle zoom-fullscreen`): the window fills the whole space, overlapping the other tiles; toggle again to drop it back into the tiling. Not native macOS fullscreen — it stays on the same Space with no transition.
fn agateZoomFullscreen(lua: *Lua) i32 {
    _ = lua;
    actions.toggleZoomFullscreen(ctx.appstate orelse return 0);
    return 0;
}

// @doc F|native_fullscreen|Toggle native macOS fullscreen for the focused window — the green-button fullscreen that moves it to its own Space with the standard transition (toggle again to leave). Unlike `zoom_fullscreen`, this is real fullscreen, so you can drop Raycast/other tools' fullscreen keybind.
fn agateNativeFullscreen(lua: *Lua) i32 {
    _ = lua;
    actions.toggleNativeFullscreen(ctx.appstate orelse return 0);
    return 0;
}

// @doc F|toggle_float|Toggle floating for the focused window (yabai's `window --toggle float`): lift it out of the tiling so it keeps its own free position and size on top while the other tiles reflow without it; toggle again to drop it back into the layout. The window stays on the same Space and is still tracked, focusable, and closes normally.
fn agateToggleFloat(lua: *Lua) i32 {
    _ = lua;
    actions.toggleFloat(ctx.appstate orelse return 0);
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

// @doc F|space|Switch to a Space, given either a 1-based position or a name registered with `agate.name_space`. A number counts every Space the swipe passes through on the focused display, in Mission Control order — including native-fullscreen Spaces (so a fullscreened app at strip position N is reached by N). A name jumps to that named slot, switching the monitor it lives on (and focusing it). Pass a `monitor` to address a position on a specific display instead of the focused one.
// @doc FP|space|target|integer|string|false|1-based Space position (Mission Control order, fullscreen included), or a name registered with `agate.name_space`.
// @doc FP|space|monitor|integer|true|1-based monitor (arrangement order, like `agate.monitors()` `id`) the position counts on, switching and focusing that display. Omit for the focused display. Ignored when `target` is a name (the name carries its own monitor).
fn agateSpace(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    // A string argument is a named space (agate.name_space); it carries its own
    // monitor. `actions.focusSpace` handles monitor 0 (the focused display) too,
    // so every form funnels through the one call.
    if (lua.typeOf(1) == .string) {
        const name = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
        const ns = ctx.lookupNamedSpace(name) orelse {
            std.debug.print("[config] agate.space: unknown space name '{s}'\n", .{name});
            return 0;
        };
        actions.focusSpace(app, ns.monitor, ns.space);
        return 0;
    }
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    // Optional monitor argument (0 = focused display).
    const mon: usize = if (lua.isNumber(2)) blk: {
        const m = lua.toInteger(2) catch 0;
        break :blk if (m >= 1) @as(usize, @intCast(m)) else 0;
    } else 0;
    actions.focusSpace(app, mon, @intCast(n));
    return 0;
}

// @doc F|space_next|Switch to the next Space on the focused display (one step in Mission Control order, fullscreen Spaces included).
fn agateSpaceNext(lua: *Lua) i32 {
    _ = lua;
    const app = ctx.appstate orelse return 0;
    macos.spaces.switchNext(app.gpa, app.skylight_cid) catch {};
    return 0;
}

// @doc F|space_prev|Switch to the previous Space on the focused display (one step in Mission Control order, fullscreen Spaces included).
fn agateSpacePrev(lua: *Lua) i32 {
    _ = lua;
    const app = ctx.appstate orelse return 0;
    macos.spaces.switchPrev(app.gpa, app.skylight_cid) catch {};
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

// @doc F|move|Swap the focused window with its neighbour in a direction. Works across nested containers.
// @doc FP|move|dir|agate.Direction|false|Direction to move the window.
fn agateMove(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    const leaf = focus.currentFocusedLeaf(app) orelse return 0;
    const forward = dir == .right or dir == .down;
    if (tree.swapLeaf(leaf, forward)) tree.flushActive(app);
    return 0;
}

/// `agate.move_to_space(n [, monitor])`: send the focused window to user space
/// `n`. With a second argument it targets space `n` on monitor `monitor`
/// (1-based, in display order) — so a window can be assigned to a Space on
/// another display; without it, the focused display.
// @doc F|move_to_space|Send the focused window to a user space (does not follow focus), given either a 1-based position or a name registered with `agate.name_space`. A name carries its own monitor; with a number, pass a `monitor` argument to target a Space on another display.
// @doc FP|move_to_space|target|integer|string|false|1-based Space position (Mission Control order, fullscreen included), or a name registered with `agate.name_space`.
// @doc FP|move_to_space|monitor|integer|true|1-based monitor (spatial arrangement, left→right — same as `agate.monitors()` `id`) the position counts on. Omit for the focused display — pass it to assign the window to a Space on another monitor. Ignored when `target` is a name (the name carries its own monitor).
fn agateMoveToSpace(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    // A string argument is a named space (agate.name_space), which carries its own
    // monitor; a number takes an optional monitor (0 = focused display).
    if (lua.typeOf(1) == .string) {
        const name = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
        const ns = ctx.lookupNamedSpace(name) orelse {
            std.debug.print("[config] agate.move_to_space: unknown space name '{s}'\n", .{name});
            return 0;
        };
        actions.moveFocusedToSpace(app, ns.monitor, ns.space);
        return 0;
    }
    const n = lua.toInteger(1) catch return 0;
    if (n < 1) return 0;
    const mon: usize = if (lua.isNumber(2)) blk: {
        const m = lua.toInteger(2) catch 0;
        break :blk if (m >= 1) @as(usize, @intCast(m)) else 0;
    } else 0;
    actions.moveFocusedToSpace(app, mon, @intCast(n));
    return 0;
}

/// `agate.name_space(name, target [, monitor])` — give a (monitor, space) slot a
/// name. `target` is a 1-based space index, or a table `{ space = N, monitor = M }`.
/// Registered names work anywhere a Space number does: `agate.space`,
/// `agate.move_to_space`, and `agate.rule`'s `space` field. Re-registering a name
/// overwrites it, so a `monitors_changed` handler can remap names on dock/undock.
// @doc F|name_space|Give a (monitor, space) slot a name, so binds and rules can refer to it by name instead of by number. The name then works anywhere a Space number does — `agate.space`, `agate.move_to_space`, and `agate.rule`'s `space` field all accept it. Re-registering a name overwrites it, so a `monitors_changed` handler can remap names as displays come and go (e.g. a "music" space that lives on the built-in panel when docked and on the laptop's own Space otherwise).
// @doc FP|name_space|name|string|false|The name to register, e.g. `"music"`.
// @doc FP|name_space|target|integer|table|false|A 1-based Space position, or a table `{ space = N, monitor = M }` pinning it to monitor `M` (1-based arrangement, like `agate.rule`). With a bare number the monitor defaults to the focused display unless given as a third argument.
// @doc FP|name_space|monitor|integer|true|1-based monitor the space lives on, when `target` is a number. Omit (or `0`) for the focused display.
fn agateNameSpace(lua: *Lua) i32 {
    const cfg = ctx.config orelse return 0;
    const name = std.mem.sliceTo(lua.toString(1) catch return 0, 0);
    if (name.len == 0) return 0;

    var space_n: usize = 0;
    var monitor: usize = 0;
    if (lua.isNumber(2)) {
        const s = lua.toInteger(2) catch 0;
        if (s >= 1) space_n = @intCast(s);
        if (lua.isNumber(3)) {
            const m = lua.toInteger(3) catch 0;
            if (m >= 1) monitor = @intCast(m);
        }
    } else if (lua.isTable(2)) {
        _ = lua.getField(2, "space");
        if (lua.isNumber(-1)) {
            const s = lua.toInteger(-1) catch 0;
            if (s >= 1) space_n = @intCast(s);
        }
        lua.pop(1);
        _ = lua.getField(2, "monitor");
        if (lua.isNumber(-1)) {
            const m = lua.toInteger(-1) catch 0;
            if (m >= 1) monitor = @intCast(m);
        }
        lua.pop(1);
    }
    if (space_n == 0) {
        std.debug.print("[config] agate.name_space('{s}'): needs a space index >= 1\n", .{name});
        return 0;
    }
    // Overwrite an existing entry with the same name so a monitors_changed
    // handler can remap names on dock/undock without piling up duplicates.
    for (cfg.named_spaces.items) |*ns| {
        if (std.mem.eql(u8, ns.name, name)) {
            ns.space = space_n;
            ns.monitor = monitor;
            return 0;
        }
    }
    const owned = cfg.alloc.dupe(u8, name) catch return 0;
    cfg.named_spaces.append(cfg.alloc, .{ .name = owned, .space = space_n, .monitor = monitor }) catch {
        cfg.alloc.free(owned);
    };
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

/// `agate.move_to_monitor(dir)`: move the focused window to the visible Space
/// of an adjacent display and tile it there, following it over.
// @doc F|move_to_monitor|Move the focused window to an adjacent display's visible space, tile it there, and follow focus to it.
// @doc FP|move_to_monitor|dir|agate.MonitorDir|false|Which display to move the window to.
fn agateMoveToMonitor(lua: *Lua) i32 {
    const app = ctx.appstate orelse return 0;
    const dir_z = lua.toString(1) catch return 0;
    const dir = parse.parseMonitorDir(std.mem.sliceTo(dir_z, 0)) orelse return 0;
    actions.moveFocusedToMonitor(app, dir);
    return 0;
}

/// The stable key of the display the focus currently lives on, or 0.
fn focusedMonitorKey(app: *@import("../state.zig").AppState) u64 {
    const mon = focus.currentMonitor(app) orelse return 0;
    return mon.id; // Monitor.id == monitor.keyForUUID
}

/// `agate.monitors()`: an array of tables describing every connected display, in
/// spatial order (left→right). Each entry: `{ id, name, x, y, width, height,
/// main, focused }`, where `id` is the 1-based arrangement number used to
/// address the monitor in rules and `move_to_space`. For conditional configs.
// @doc F|monitors|Return an array of tables describing the connected displays, in spatial order (left→right). Each entry has `id` (1-based arrangement number — the value `agate.rule{monitor=...}` / `agate.move_to_space(n, monitor)` expect), `name`, `x`, `y`, `width`, `height`, `main` (the primary display), and `focused` (the display with keyboard focus). Combine with `agate.on("monitors_changed", ...)` for configs that adapt to docking.
fn agateMonitors(lua: *Lua) i32 {
    const app = ctx.appstate orelse {
        lua.newTable();
        return 1;
    };
    var buf: [macos.monitor.max_monitors]macos.monitor.Monitor = undefined;
    const mons = macos.monitor.enumerate(&buf, app.skylight_cid);
    const focused_key = focusedMonitorKey(app);

    lua.createTable(@intCast(mons.len), 0);
    for (mons, 1..) |m, i| {
        lua.createTable(0, 8);
        lua.pushInteger(@intCast(m.arrangement));
        lua.setField(-2, "id");
        _ = lua.pushString(m.nameSlice());
        lua.setField(-2, "name");
        lua.pushNumber(m.frame.origin.x);
        lua.setField(-2, "x");
        lua.pushNumber(m.frame.origin.y);
        lua.setField(-2, "y");
        lua.pushNumber(m.frame.size.width);
        lua.setField(-2, "width");
        lua.pushNumber(m.frame.size.height);
        lua.setField(-2, "height");
        lua.pushBoolean(m.is_main);
        lua.setField(-2, "main");
        lua.pushBoolean(m.key == focused_key);
        lua.setField(-2, "focused");
        lua.setIndex(-2, @intCast(i));
    }
    return 1;
}

/// `agate.monitor_count()`: the number of connected displays.
// @doc F|monitor_count|Return the number of connected displays. Handy for branching config, e.g. `if agate.monitor_count() == 1 then ... end`.
fn agateMonitorCount(lua: *Lua) i32 {
    const app = ctx.appstate orelse {
        lua.pushInteger(0);
        return 1;
    };
    var buf: [macos.monitor.max_monitors]macos.monitor.Monitor = undefined;
    const mons = macos.monitor.enumerate(&buf, app.skylight_cid);
    lua.pushInteger(@intCast(mons.len));
    return 1;
}

/// `agate.focused_monitor()`: the 1-based arrangement number of the display that
/// currently has keyboard focus (0 if it can't be resolved).
// @doc F|focused_monitor|Return the 1-based arrangement number of the display that currently has keyboard focus (0 if unknown) — the same numbering `agate.monitors()` reports and rules address.
fn agateFocusedMonitor(lua: *Lua) i32 {
    const app = ctx.appstate orelse {
        lua.pushInteger(0);
        return 1;
    };
    const key = focusedMonitorKey(app);
    var buf: [macos.monitor.max_monitors]macos.monitor.Monitor = undefined;
    const mons = macos.monitor.enumerate(&buf, app.skylight_cid);
    var arrangement: usize = 0;
    for (mons) |m| if (m.key == key) {
        arrangement = m.arrangement;
        break;
    };
    lua.pushInteger(@intCast(arrangement));
    return 1;
}

/// `agate.focus_app(name)`: focus a running app by (partial) name, wherever it
/// lives — switches the display holding its window to that window's Space and
/// raises it, even across monitors and even with macOS's "switch space on app
/// switch" setting off. Returns true if a tracked window matched. Pair with
/// `agate.exec("open -a …")` as a fallback to launch the app when it isn't open.
// @doc F|focus_app|Focus a running app by name, wherever its window lives: switches the display that holds the window to its Space (across monitors too, regardless of the macOS "switch to a Space with open windows" setting) and raises it. Matches the app name as a substring (so `"Zen"` matches `"Zen Browser (Beta)"`). Returns `true` if a tracked window was found and focused, `false` otherwise — fall back to `agate.exec("open -a Name")` to launch it. Expandable: bind one per app.
// @doc FP|focus_app|name|string|false|App name (or a substring of it) to focus.
// @doc FR|focus_app|boolean|`true` if a matching window was focused, else `false`.
fn agateFocusApp(lua: *Lua) i32 {
    const app = ctx.appstate orelse {
        lua.pushBoolean(false);
        return 1;
    };
    const name_z = lua.toString(1) catch {
        lua.pushBoolean(false);
        return 1;
    };
    const ok = actions.focusApp(app, std.mem.sliceTo(name_z, 0));
    lua.pushBoolean(ok);
    return 1;
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
    if (lua.typeOf(-1) == .string) {
        // Store the name rather than resolving it now: rules.matchRules looks it
        // up when a window appears, so the rule follows a name that's remapped on
        // docking (the name supplies both the space index and its monitor).
        const name = std.mem.sliceTo(lua.toString(-1) catch "", 0);
        rule.space_name = cfg.alloc.dupe(u8, name) catch null;
    } else if (lua.isNumber(-1)) {
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

    if ((rule.app == null and rule.title == null) or (rule.space == 0 and rule.space_name == null and !rule.floating)) {
        std.debug.print("[config] rule needs an app or title matcher, and a space/monitor or floating=true; ignored\n", .{});
        rules.freeRule(cfg.alloc, rule);
        return 0;
    }
    cfg.rules.append(cfg.alloc, rule) catch rules.freeRule(cfg.alloc, rule);
    return 0;
}

/// `agate.clear_rules()`: drop every registered window-assignment rule (freeing
/// their compiled regexes). The companion to `agate.on("monitors_changed", ...)`:
/// a conditional config rebuilds its rule set from scratch each time the display
/// layout changes, without the rules accumulating across docks.
// @doc F|clear_rules|Remove all window assignment rules previously added with `agate.rule`. Use it before re-registering rules in a `monitors_changed` handler so conditional rule sets don't pile up across dock/undock cycles.
fn agateClearRules(lua: *Lua) i32 {
    _ = lua;
    const cfg = ctx.config orelse return 0;
    for (cfg.rules.items) |r| rules.freeRule(cfg.alloc, r);
    cfg.rules.clearRetainingCapacity();
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
    .{ .name = "cycle",       .func = zlua.wrap(agateCycle) },
    .{ .name = "focus",       .func = zlua.wrap(agateFocus) },
    .{ .name = "layout",      .func = zlua.wrap(agateLayout) },
    .{ .name = "space",       .func = zlua.wrap(agateSpace) },
    .{ .name = "space_next",  .func = zlua.wrap(agateSpaceNext) },
    .{ .name = "space_prev",  .func = zlua.wrap(agateSpacePrev) },
    .{ .name = "resize",      .func = zlua.wrap(agateResize) },
    .{ .name = "move",        .func = zlua.wrap(agateMove) },
    .{ .name = "move_to_space", .func = zlua.wrap(agateMoveToSpace) },
    .{ .name = "name_space",  .func = zlua.wrap(agateNameSpace) },
    .{ .name = "focus_monitor", .func = zlua.wrap(agateFocusMonitor) },
    .{ .name = "move_to_monitor", .func = zlua.wrap(agateMoveToMonitor) },
    .{ .name = "monitors",    .func = zlua.wrap(agateMonitors) },
    .{ .name = "monitor_count", .func = zlua.wrap(agateMonitorCount) },
    .{ .name = "focused_monitor", .func = zlua.wrap(agateFocusedMonitor) },
    .{ .name = "focus_app",   .func = zlua.wrap(agateFocusApp) },
    .{ .name = "join",        .func = zlua.wrap(agateJoin) },
    .{ .name = "zoom_fullscreen", .func = zlua.wrap(agateZoomFullscreen) },
    .{ .name = "native_fullscreen", .func = zlua.wrap(agateNativeFullscreen) },
    .{ .name = "toggle_float", .func = zlua.wrap(agateToggleFloat) },
    .{ .name = "exec",        .func = zlua.wrap(agateExec) },
    .{ .name = "rule",        .func = zlua.wrap(agateRule) },
    .{ .name = "clear_rules", .func = zlua.wrap(agateClearRules) },
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
