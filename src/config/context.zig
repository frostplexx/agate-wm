//! Shared runtime state for the Lua config layer: the single live `Config` and
//! the `AppState` it drives, set in `lua.init` and cleared in `lua.deinit`.
//! Split out so every config submodule can reach them without importing the
//! `lua.zig` facade (which imports *them*, so the dependency must point one way).
const state = @import("../state.zig");
const types = @import("types.zig");

/// The live configuration, or null before `init` / after `deinit`.
pub var config: ?*types.Config = null;
/// The app state the config drives, or null outside a session.
pub var appstate: ?*state.AppState = null;

/// The CGEventFlag bits the hyper key expands to while held (`Config.hyper_mods`).
/// The keyboard tap ORs these onto key events to form the hyper chord.
pub fn hyperMods() u64 {
    const cfg = config orelse return 0;
    return cfg.hyper_mods;
}

/// The virtual keycode of the hyper trigger key (F18), or 0 when the built-in
/// hyper key is disabled — so the tap's `code == hyperKey()` check short-circuits.
pub fn hyperKey() u16 {
    const cfg = config orelse return 0;
    return if (cfg.hyper_enabled) cfg.hyper_key else 0;
}

/// Whether the built-in hyper key is enabled (config `hyper_key.enabled`). Gates
/// the Caps Lock → F18 `hidutil` remap performed at startup.
pub fn hyperEnabled() bool {
    const cfg = config orelse return false;
    return cfg.hyper_enabled;
}

/// Resolve a space name registered with `agate.name_space` to its (monitor,
/// space) slot, or null if no named space carries that name. Shared by the
/// `agate.*` marshalling (`api.zig`) and rule matching (`rules.zig`).
pub fn lookupNamedSpace(name: []const u8) ?types.NamedSpace {
    const cfg = config orelse return null;
    for (cfg.named_spaces.items) |ns| {
        if (std.mem.eql(u8, ns.name, name)) return ns;
    }
    return null;
}

/// Whether the menu-bar space indicator is enabled (config `space_indicator`).
pub fn spaceIndicatorEnabled() bool {
    const cfg = config orelse return true;
    return cfg.space_indicator;
}

/// Whether the drag-preview overlay is enabled (config `drag_preview`).
pub fn dragPreviewEnabled() bool {
    const cfg = config orelse return true;
    return cfg.drag_preview;
}

const std = @import("std");

test "hyperKey/hyperEnabled gate on hyper_key.enabled" {
    // No live config → safe defaults (feature off).
    config = null;
    try std.testing.expectEqual(@as(u16, 0), hyperKey());
    try std.testing.expect(!hyperEnabled());

    // Only the fields the getters read need to be set on the throwaway Config.
    var cfg: types.Config = undefined;
    cfg.hyper_key = 79;
    cfg.hyper_mods = 0xABC;
    config = &cfg;
    defer config = null;

    cfg.hyper_enabled = true;
    try std.testing.expectEqual(@as(u16, 79), hyperKey());
    try std.testing.expect(hyperEnabled());
    try std.testing.expectEqual(@as(u64, 0xABC), hyperMods());

    // Disabled → the trigger keycode reads as 0 so the tap check short-circuits,
    // even though hyper_key itself is unchanged.
    cfg.hyper_enabled = false;
    try std.testing.expectEqual(@as(u16, 0), hyperKey());
    try std.testing.expect(!hyperEnabled());
}
