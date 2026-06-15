//! Keybinding runtime: dispatching key events against the registered bindings,
//! running a binding's action (Lua callback or string command), the string
//! command vocabulary, and the modal-keymap (`agate.mode`) enter/exit. The
//! bindings themselves are registered in `api.zig`; this file consumes them.
const std = @import("std");
const zlua = @import("zlua");
const macos = @import("macos");
const focus = @import("../wm/focus/focus.zig");
const tree = @import("../wm/tree.zig");
const types = @import("types.zig");
const ctx = @import("context.zig");
const parse = @import("parse.zig");
const actions = @import("actions.zig");
const exec = @import("exec.zig");

const Config = types.Config;
const BindingAction = types.BindingAction;
const MOD_MASK = types.MOD_MASK;

// ---------------------------------------------------------------------------
// Modes (Hyprland-style submaps)
// ---------------------------------------------------------------------------

/// Activate the named mode by index (shared by `agate.enter_mode` and the
/// `mode <name>` command). Updates the menu-bar indicator if it's present.
pub fn enterModeByName(cfg: *Config, name: []const u8) void {
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
pub fn exitActiveMode(cfg: *Config) void {
    if (cfg.active_mode == null) return;
    cfg.active_mode = null;
    // Restore the menu-bar item to the Space number the indicator normally shows.
    if (ctx.appstate) |app| {
        macos.statusbar.setSpaceNumber(macos.spaces.activeUserIndex(app.gpa, app.skylight_cid));
    }
}

// ---------------------------------------------------------------------------
// Key dispatch
// ---------------------------------------------------------------------------

/// Cheap test: does any registered binding match this chord? Called from inside
/// the keyboard event tap to decide whether to swallow the keystroke, without
/// running the (slow) action — the action runs deferred via `handleKey`.
pub fn matchBinding(keycode: u16, raw_flags: u64) bool {
    const cfg = ctx.config orelse return false;
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
/// Shared by key bindings (`handleKey`) and gesture bindings (`swipe.handleGesture`).
pub fn runAction(cfg: *Config, action: BindingAction) void {
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
    const cfg = ctx.config orelse return false;
    const mods = raw_flags & MOD_MASK;
    const set = if (cfg.active_mode) |mi| cfg.modes.items[mi].bindings.items else cfg.bindings.items;
    for (set) |b| {
        if (b.keycode != keycode or b.modifiers != mods) continue;
        runAction(cfg, b.action);
        return true;
    }
    return false;
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
// @doc C|toggle_float|Same as `agate.toggle_float()`.
// @doc C|mode <name>|Same as `agate.enter_mode(name)`.
// @doc C|exit_mode|Same as `agate.exit_mode()`.
pub fn executeCommand(cmd: []const u8) void {
    const app = ctx.appstate orelse return;
    if (std.mem.startsWith(u8, cmd, "move ")) {
        const dir = parse.parseDir(cmd[5..]) orelse return;
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
        const dir = parse.parseDir(cmd[6..]) orelse return;
        _ = focus.focusDirection(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "cycle ")) {
        const arg = cmd[6..];
        const forward = !(std.mem.eql(u8, arg, "prev") or std.mem.eql(u8, arg, "previous") or
            std.mem.eql(u8, arg, "back") or std.mem.eql(u8, arg, "backward"));
        _ = focus.cycleFocus(app, forward);
    } else if (std.mem.startsWith(u8, cmd, "layout ")) {
        actions.setActiveLayout(app, cmd[7..]);
    } else if (std.mem.startsWith(u8, cmd, "space ")) {
        const n = std.fmt.parseInt(usize, cmd[6..], 10) catch return;
        macos.spaces.switchToIndex(app.gpa, app.skylight_cid, n) catch {};
    } else if (std.mem.startsWith(u8, cmd, "move_to_space ")) {
        const n = std.fmt.parseInt(usize, cmd[14..], 10) catch return;
        actions.moveFocusedToSpace(app, n);
    } else if (std.mem.startsWith(u8, cmd, "focus_monitor ")) {
        const dir = parse.parseMonitorDir(cmd[14..]) orelse return;
        _ = focus.focusMonitor(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "move_to_monitor ")) {
        const dir = parse.parseMonitorDir(cmd[16..]) orelse return;
        actions.moveFocusedToMonitor(app, dir);
    } else if (std.mem.startsWith(u8, cmd, "mode ")) {
        if (ctx.config) |cfg| enterModeByName(cfg, cmd[5..]);
    } else if (std.mem.eql(u8, cmd, "exit_mode")) {
        if (ctx.config) |cfg| exitActiveMode(cfg);
    } else if (std.mem.eql(u8, cmd, "zoom_fullscreen")) {
        actions.toggleZoomFullscreen(app);
    } else if (std.mem.eql(u8, cmd, "toggle_float")) {
        actions.toggleFloat(app);
    } else if (std.mem.startsWith(u8, cmd, "exec ")) {
        exec.spawnShell(app.gpa, cmd[5..]);
    }
}
