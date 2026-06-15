//! Config-layer data definitions: the `Config` record, the binding/mode/rule
//! types, and the modifier-bit constants. Pure declarations — no business
//! logic, no Lua glue. The `// @doc` lines on `Config`/`Rule` fields are read by
//! `tools/gen_docs.zig` to generate `types/agate.lua` and the wiki reference.
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const regexp = @import("../lib/regexp.zig");
const gestures = @import("../wm/gestures.zig");
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
    /// Float matched windows on appearance (yabai's `rule --add ... manage=off`):
    /// they're tracked but lifted out of the tiling, keeping their own size/place.
    /// Usable on its own (no `space`/`monitor`) to float an app wherever it opens,
    /// or alongside a Space assignment to float it there.
    // @doc SR|floating|boolean|true|Float matched windows when they appear (like `agate.toggle_float()` applied automatically) — tracked but lifted out of the tiling. Can be the rule's only effect (no `space` needed), or combined with a Space/monitor assignment.
    floating: bool = false,
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
    /// big display takes over. See `small_screen.applySmallScreenMode`.
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
