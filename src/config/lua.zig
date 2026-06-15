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

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

pub fn init(gpa: std.mem.Allocator, app: *state.AppState) !*Config {
    ctx.appstate = app;

    const cfg = try gpa.create(Config);
    cfg.* = .{
        .alloc = gpa,
        .gaps = 8,
        .outer_gaps = 8,
        .accordion_padding = 40,
        .hyper_mods = types.MOD_CTRL | types.MOD_ALT | types.MOD_CMD | types.MOD_SHIFT,
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
    ctx.config = cfg;

    cfg.lua.openLibs();
    api.register(cfg.lua);

    const config_path = findConfigPath(gpa) orelse {
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
    cfg.lua.deinit();
    cfg.alloc.destroy(cfg);
    ctx.config = null;
    ctx.appstate = null;
}

// ---------------------------------------------------------------------------
// init.lua discovery
// ---------------------------------------------------------------------------

// `std.Io.Dir.access` needs the `Io` handle from main; plain `access(2)` is
// enough for an existence probe and keeps the config layer Io-free.
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
