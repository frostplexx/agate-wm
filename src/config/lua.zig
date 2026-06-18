//! Lua configuration public facade. Owns the lifecycle (`init`/`deinit`:
//! create the `Config`, open the Lua VM, install the `agate.*` API, find and run
//! init.lua) and re-exports the entry points the rest of the app calls. The
//! actual work is split across sibling files:
//!
//!   * `types.zig`        — Config / Binding / Rule data definitions
//!   * `context.zig`      — the live Config + AppState globals and their getters
//!   * `api.zig`          — the `agate.*` Lua functions (marshalling only)
//!   * `parse.zig`        — key / gesture / direction / layout parsing
//!   * `actions.zig`      — window-management verbs (layout, move, zoom, …)
//!   * `keybind.zig`      — key dispatch, string commands, modal keymaps
//!   * `swipe.zig`        — trackpad-gesture HUD and dispatch
//!   * `rules.zig`        — window assignment rules
//!   * `small_screen.zig` — Small Screen Mode
//!   * `exec.zig`         — launching shell commands
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const macos = @import("macos");
const state = @import("../state.zig");
const tree = @import("../wm/tree.zig");

const types = @import("types.zig");
const ctx = @import("context.zig");
const api = @import("api.zig");
const keybind = @import("keybind.zig");
const swipe = @import("swipe.zig");
const actions = @import("actions.zig");
const rules = @import("rules.zig");
const small_screen = @import("small_screen.zig");
const paths = @import("paths.zig");
const events = @import("events.zig");

const Config = types.Config;

// ---------------------------------------------------------------------------
// Public API re-exports (the surface other modules import as `lua_config.*`)
// ---------------------------------------------------------------------------

pub const MOD_SHIFT = types.MOD_SHIFT;
pub const MOD_CTRL = types.MOD_CTRL;
pub const MOD_ALT = types.MOD_ALT;
pub const MOD_CMD = types.MOD_CMD;
pub const MOD_MASK = types.MOD_MASK;

pub const hyperMods = ctx.hyperMods;
pub const hyperKey = ctx.hyperKey;
pub const hyperEnabled = ctx.hyperEnabled;
pub const spaceIndicatorEnabled = ctx.spaceIndicatorEnabled;
pub const dragPreviewEnabled = ctx.dragPreviewEnabled;

pub const matchBinding = keybind.matchBinding;
pub const handleKey = keybind.handleKey;

pub const gestureBegin = swipe.gestureBegin;
pub const gestureUpdate = swipe.gestureUpdate;
pub const gestureEnd = swipe.gestureEnd;
pub const hasFourFingerGesture = swipe.hasFourFingerGesture;

pub const runPendingMove = actions.runPendingMove;
pub const applyRulesToLeaf = rules.applyRulesToLeaf;
pub const applySmallScreenMode = small_screen.applySmallScreenMode;

// Event callbacks (`agate.on`) — emit helpers the WM event sites call.
pub const emitSpaceChanged = events.emitSpaceChanged;
pub const emitModeChanged = events.emitModeChanged;
pub const emitWindowCreated = events.emitWindowCreated;
pub const emitWindowDestroyed = events.emitWindowDestroyed;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

pub fn init(gpa: std.mem.Allocator, app: *state.AppState) !*Config {
    ctx.appstate = app;

    const cfg = try gpa.create(Config);
    // Default Flow strip width presets (fractions of the viewport). Owned by the
    // config allocator so a user `preset_column_widths` can free and replace it.
    const default_presets = try gpa.alloc(f64, 4);
    default_presets[0] = 1.0 / 3.0;
    default_presets[1] = 0.5;
    default_presets[2] = 2.0 / 3.0;
    default_presets[3] = 1.0;
    cfg.* = .{
        .alloc = gpa,
        .gaps = 8,
        .outer_gaps = 8,
        .peek = 48,
        .default_column_width = 0.5,
        .min_column_width = 0.22,
        .preset_column_widths = default_presets,
        .swipe_scroll_fingers = 3,
        .hyper_mods = types.MOD_CTRL | types.MOD_ALT | types.MOD_CMD | types.MOD_SHIFT,
        .hyper_enabled = true, // built-in Caps Lock → F18 hyper key (LazyKeys port)
        .hyper_key = macos.hyperkey.F18_KEYCODE, // trigger = F18 (Caps Lock is remapped to it)
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
        .event_handlers = .empty,
        .lua = try Lua.init(gpa),
    };
    ctx.config = cfg;

    cfg.lua.openLibs();
    api.register(cfg.lua);

    const config_path = paths.findConfigPath(gpa) orelse {
        std.debug.print("[config] no init.lua found; using defaults\n", .{});
        // Small Screen Mode is on by default, so it applies config or not.
        if (small_screen.applySmallScreenMode(app)) tree.flushAllVisible(app);
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
    if (small_screen.applySmallScreenMode(app)) tree.flushAllVisible(app);

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
    for (cfg.rules.items) |r| rules.freeRule(r);
    cfg.rules.deinit(cfg.alloc);
    for (cfg.event_handlers.items) |h| cfg.lua.unref(zlua.registry_index, h.lua_fn);
    cfg.event_handlers.deinit(cfg.alloc);
    cfg.lua.deinit();
    cfg.alloc.destroy(cfg);
    ctx.config = null;
    ctx.appstate = null;
}

/// The init.lua path agate would load, or null if none exists (see `paths`).
/// Exposed for the CLI (`agate config`), which resolves it without the VM.
pub const findConfigPath = paths.findConfigPath;
