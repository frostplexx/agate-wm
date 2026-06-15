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

/// The CGEventFlag bits to synthesize when the hyper key is held (see
/// `Config.hyper_key`). Used by the event tap to fake the modifiers a remapper
/// hides from it.
pub fn hyperMods() u64 {
    const cfg = config orelse return 0;
    return cfg.hyper_mods;
}

/// The virtual keycode whose held state means "hyper" (0 = feature disabled).
pub fn hyperKey() u16 {
    const cfg = config orelse return 0;
    return cfg.hyper_key;
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
