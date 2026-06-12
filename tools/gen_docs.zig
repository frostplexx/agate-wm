//! Documentation generator for agate's Lua config surface.
//!
//! A single metadata table below is the source of truth for both outputs:
//!   * `markdown()` → `docs/configuration.md` (human reference)
//!   * `lua()`      → `types/agate.lua` (LuaCATS type stub for lua-language-server)
//!
//! `build.zig` imports this file and calls the two functions, writing the
//! results into the source tree via `zig build docs`. Keep the metadata in sync
//! with `src/config/lua.zig` (the `agate_fns` table, `agateConfig` parsing,
//! `layoutFromName`, and `parseDir`).
const std = @import("std");

// --- Source-of-truth metadata ----------------------------------------------

const Param = struct {
    name: []const u8,
    ty: []const u8, // Lua/LuaCATS type
    doc: []const u8,
    optional: bool = false,
};

const Func = struct {
    name: []const u8,
    params: []const Param = &.{},
    ret: ?[]const u8 = null,
    doc: []const u8,
};

const Setting = struct {
    name: []const u8,
    ty: []const u8,
    default: []const u8,
    doc: []const u8,
};

const Alias = struct {
    name: []const u8,
    values: []const []const u8,
    doc: []const u8,
};

const settings = [_]Setting{
    .{ .name = "gaps", .ty = "number", .default = "8", .doc = "Pixels between adjacent tiles." },
    .{ .name = "outer_gaps", .ty = "number", .default = "8", .doc = "Pixels inset from the screen edge." },
    .{ .name = "accordion_padding", .ty = "number", .default = "40", .doc = "Stacked-window \"peek\": how far each window in a stack/accordion fans past the one in front. Alias: `accordion`." },
    .{ .name = "hyper", .ty = "string[]", .default = "{\"ctrl\",\"alt\",\"cmd\",\"shift\"}", .doc = "Modifier set the `hyper` macro in key specs expands to. Any of: `ctrl`/`control`, `alt`/`opt`, `cmd`/`command`, `shift`." },
    .{ .name = "hyper_key", .ty = "string", .default = "\"f18\"", .doc = "Physical key whose held state is treated as `hyper`, for remappers (lazykeys/Karabiner) that hide the real modifiers from the event tap. A key name like `\"f18\"`; empty disables." },
    .{ .name = "small_screen", .ty = "agate.SmallScreen", .default = "{ enabled = true, layout = \"h_accordion\", max_width = 0 }", .doc = "Small Screen Mode (see agate.SmallScreen): workspaces on a small main display trade the split layout for an accordion, and back when a big display takes over." },
    .{ .name = "drag_preview", .ty = "boolean", .default = "true", .doc = "While dragging a window, highlight the tile it will swap into on drop with a translucent overlay." },
    .{ .name = "space_indicator", .ty = "boolean", .default = "true", .doc = "Show the active space's number as a menu-bar status item." },
    .{ .name = "animations", .ty = "boolean", .default = "false", .doc = "Animate tiling frame changes instead of snapping: the final size applies instantly, the position glides over (60 Hz, ease-out, capped at 8 windows per flush with an automatic snap when an app is too busy to keep up). Speed via `animation_duration`." },
    .{ .name = "animation_duration", .ty = "number", .default = "150", .doc = "Length of the frame animation in **milliseconds** (lower = faster; `0` disables). Only meaningful with `animations = true`." },
    .{ .name = "space_animation", .ty = "string", .default = "\"instant\"", .doc = "How much of the Space-switch transition plays: `\"fast\"`, `\"very_fast\"`, or `\"instant\"` (no perceptible animation)." },
};

// Fields of the `small_screen` table inside `agate.config{}`.
const small_screen_fields = [_]Param{
    .{ .name = "enabled", .ty = "boolean", .doc = "Master switch (default `true`).", .optional = true },
    .{ .name = "layout", .ty = "string", .doc = "Layout small workspaces get: any layout name (default `\"h_accordion\"`), or `\"tabs\"` for a zero-peek stack — full-area windows flipped through like tabs.", .optional = true },
    .{ .name = "max_width", .ty = "number", .doc = "Width (points) at or under which a display counts as small, in addition to the built-in panel. `0` (default) = built-in display detection only.", .optional = true },
};

// Fields of the table passed to `agate.rule{}`.
const rule_fields = [_]Param{
    .{ .name = "app", .ty = "string", .doc = "POSIX extended regex matched against the owning application's name, e.g. `\"^Music$\"`.", .optional = true },
    .{ .name = "title", .ty = "string", .doc = "POSIX extended regex matched against the window title.", .optional = true },
    .{ .name = "space", .ty = "integer", .doc = "1-based user-space index matched windows are sent to. Required." },
    .{ .name = "follow", .ty = "boolean", .doc = "Switch to that space along with the window (default `true`). Set `false` to route the window in the background.", .optional = true },
};

const aliases = [_]Alias{
    .{ .name = "agate.Direction", .values = &.{ "left", "right", "up", "down" }, .doc = "A focus/move/resize direction." },
    .{ .name = "agate.Layout", .values = &.{ "h_tiles", "v_tiles", "h_stack", "v_stack", "accordion", "float", "toggle" }, .doc = "A layout mode. Synonyms: `h_split`/`horizontal` = `h_tiles`; `v_split`/`vertical` = `v_tiles`; `v_accordion`/`stacking`/`stacked` = `v_stack`/`accordion`; `floating` = `float`. `toggle` flips the split orientation." },
};

const dir_ty = "agate.Direction";
const layout_ty = "agate.Layout";

const funcs = [_]Func{
    .{
        .name = "config",
        .params = &.{.{ .name = "config", .ty = "agate.Config", .doc = "Settings table (see agate.Config)." }},
        .doc = "Apply global configuration. Call once near the top of init.lua.",
    },
    .{
        .name = "bind",
        .params = &.{
            .{ .name = "spec", .ty = "string", .doc = "Key chord, e.g. `\"hyper+shift+l\"`." },
            .{ .name = "action", .ty = "fun()|string", .doc = "A Lua callback, or a string command (see Commands below)." },
        },
        .doc = "Bind a key chord to an action.",
    },
    .{
        .name = "gesture",
        .params = &.{
            .{ .name = "spec", .ty = "string", .doc = "Finger count (3 or 4) and direction, e.g. `\"3:left\"` or `\"4:up\"`." },
            .{ .name = "action", .ty = "fun()|string", .doc = "A Lua callback, or a string command (see Commands below)." },
        },
        .doc = "Bind a trackpad swipe to an action. One step fires per ~quarter-pad of travel, so a long swipe repeats the action (Hyprland-style). The system gestures on the same finger count must be off or moved to the other count in Trackpad settings.",
    },
    .{
        .name = "cycle",
        .params = &.{.{ .name = "dir", .ty = "\"next\"|\"prev\"", .doc = "Cycle direction." }},
        .doc = "Focus the next/previous window among the focused window's siblings, wrapping at the edges — the natural motion through an accordion/stack (Small Screen Mode), bindable to a swipe or a key.",
    },
    .{
        .name = "focus",
        .params = &.{.{ .name = "dir", .ty = dir_ty, .doc = "Direction to move focus." }},
        .doc = "Move focus to the nearest window in a direction, descending into and ascending out of nested containers (i3-style). Left/right traverse horizontal splits/stacks; up/down vertical ones.",
    },
    .{
        .name = "layout",
        .params = &.{.{ .name = "mode", .ty = layout_ty, .doc = "Layout mode to apply." }},
        .doc = "Set the focused container's layout (the focused window's parent), falling back to the workspace for top-level windows.",
    },
    .{
        .name = "resize",
        .params = &.{
            .{ .name = "dir", .ty = dir_ty, .doc = "Edge to grow toward." },
            .{ .name = "amount", .ty = "number", .doc = "Pixels to resize by. Default 50.", .optional = true },
        },
        .doc = "Resize the focused tile, transferring the delta to its neighbour.",
    },
    .{
        .name = "move",
        .params = &.{.{ .name = "dir", .ty = dir_ty, .doc = "Direction to move the window." }},
        .doc = "Swap the focused window with its neighbour in a direction. Works across nested containers.",
    },
    .{
        .name = "join",
        .params = &.{
            .{ .name = "dir", .ty = dir_ty, .doc = "Neighbour to combine with." },
            .{ .name = "mode", .ty = layout_ty, .doc = "Layout of the new container. Default `v_stack`.", .optional = true },
        },
        .doc = "Combine the focused window with its neighbour into a nested container, for mixed layouts (e.g. a row whose one slot is a stack of two windows).",
    },
    .{
        .name = "space",
        .params = &.{.{ .name = "n", .ty = "integer", .doc = "1-based user-space index on the focused display." }},
        .doc = "Switch to user space N on the focused display.",
    },
    .{ .name = "space_next", .doc = "Switch to the next user space on the focused display." },
    .{ .name = "space_prev", .doc = "Switch to the previous user space on the focused display." },
    .{
        .name = "move_to_space",
        .params = &.{.{ .name = "n", .ty = "integer", .doc = "1-based user-space index to send the window to." }},
        .doc = "Send the focused window to user space N (does not follow focus).",
    },
    .{
        .name = "rule",
        .params = &.{.{ .name = "rule", .ty = "agate.Rule", .doc = "Rule table (see agate.Rule)." }},
        .doc = "Register a window assignment rule, like yabai's `rule --add`: windows whose app name/title match the given regexes are sent to a space when they appear. At least one of `app`/`title` is required; both must match when both are given. When several rules match a window, the last registered one wins.",
    },
};

// String commands accepted by `agate.bind(spec, "<command>")`.
const Command = struct { form: []const u8, doc: []const u8 };
const commands = [_]Command{
    .{ .form = "move <dir>", .doc = "Same as `agate.move(dir)`." },
    .{ .form = "focus <dir>", .doc = "Same as `agate.focus(dir)`." },
    .{ .form = "cycle <next|prev>", .doc = "Same as `agate.cycle(dir)`." },
    .{ .form = "layout <mode>", .doc = "Same as `agate.layout(mode)`." },
    .{ .form = "space <n>", .doc = "Same as `agate.space(n)`." },
    .{ .form = "move_to_space <n>", .doc = "Same as `agate.move_to_space(n)`." },
};

// --- Output -----------------------------------------------------------------

/// A growable output buffer carrying its allocator, so the emit helpers read as
/// plain `b.w("...", .{})` calls.
const Buf = struct {
    list: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,
    fn w(b: *Buf, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(b.alloc, fmt, args) catch return;
        b.list.appendSlice(b.alloc, s) catch {};
    }
};

/// Render the markdown settings reference.
pub fn markdown(alloc: std.mem.Allocator) []const u8 {
    var b = Buf{ .alloc = alloc };
    emitMarkdown(&b);
    return b.list.items;
}

/// Render the LuaCATS type stub.
pub fn lua(alloc: std.mem.Allocator) []const u8 {
    var b = Buf{ .alloc = alloc };
    emitLua(&b);
    return b.list.items;
}

/// `(p1, p2, ...)` for a function signature. When `mark_optional` is set, an
/// optional param shows a trailing `?` (doc convention) — but a real Lua
/// `function` definition must use bare names, so the Lua emitter passes false.
fn signature(alloc: std.mem.Allocator, f: Func, mark_optional: bool) []const u8 {
    var sig: std.ArrayList(u8) = .empty;
    sig.append(alloc, '(') catch {};
    for (f.params, 0..) |p, i| {
        if (i != 0) sig.appendSlice(alloc, ", ") catch {};
        sig.appendSlice(alloc, p.name) catch {};
        if (mark_optional and p.optional) sig.append(alloc, '?') catch {};
    }
    sig.append(alloc, ')') catch {};
    return sig.items;
}

fn emitMarkdown(b: *Buf) void {
    b.w("# agate configuration\n\n", .{});
    b.w("> Auto-generated by `zig build docs` from `tools/gen_docs.zig`. Do not edit by hand.\n\n", .{});
    b.w("All configuration is Lua, loaded from `$WM_CONFIG`, `$XDG_CONFIG_HOME/agate/init.lua`, `~/.config/agate/init.lua`, or `./init.lua`.\n\n", .{});

    b.w("## `agate.config{{}}` settings\n\n", .{});
    b.w("| Key | Type | Default | Description |\n", .{});
    b.w("| --- | --- | --- | --- |\n", .{});
    for (settings) |s| {
        b.w("| `{s}` | `{s}` | `{s}` | {s} |\n", .{ s.name, s.ty, s.default, s.doc });
    }
    b.w("\n", .{});

    b.w("## `small_screen` fields (Small Screen Mode)\n\n", .{});
    b.w("On a small main display (the built-in panel, or anything at or under `max_width` points), workspaces still on the default split layout switch to `layout` — a straight tiling split is not useful on a tiny screen. They switch back when a big display takes over (dock/undock re-evaluates). Workspaces whose layout was set by hand are left alone in both directions. Pair with `agate.gesture` for trackpad-driven window cycling.\n\n", .{});
    b.w("| Key | Type | Description |\n", .{});
    b.w("| --- | --- | --- |\n", .{});
    for (small_screen_fields) |p| {
        const opt = if (p.optional) " _(optional)_" else "";
        b.w("| `{s}` | `{s}` | {s}{s} |\n", .{ p.name, p.ty, p.doc, opt });
    }
    b.w("\n", .{});

    b.w("## `agate.rule{{}}` fields\n\n", .{});
    b.w("| Key | Type | Description |\n", .{});
    b.w("| --- | --- | --- |\n", .{});
    for (rule_fields) |p| {
        const opt = if (p.optional) " _(optional)_" else "";
        b.w("| `{s}` | `{s}` | {s}{s} |\n", .{ p.name, p.ty, p.doc, opt });
    }
    b.w("\n", .{});

    b.w("## API\n\n", .{});
    for (funcs) |f| {
        b.w("### `agate.{s}{s}`\n\n", .{ f.name, signature(b.alloc, f, true) });
        b.w("{s}\n\n", .{f.doc});
        if (f.params.len != 0) {
            for (f.params) |p| {
                const opt = if (p.optional) " _(optional)_" else "";
                b.w("- `{s}` (`{s}`){s} — {s}\n", .{ p.name, p.ty, opt, p.doc });
            }
            b.w("\n", .{});
        }
    }

    b.w("## Commands\n\n", .{});
    b.w("Strings passed as the second argument of `agate.bind` instead of a function:\n\n", .{});
    b.w("| Command | Description |\n| --- | --- |\n", .{});
    for (commands) |cmd| b.w("| `{s}` | {s} |\n", .{ cmd.form, cmd.doc });
    b.w("\n", .{});

    b.w("## Enumerations\n\n", .{});
    for (aliases) |a| {
        b.w("### `{s}`\n\n{s}\n\n", .{ a.name, a.doc });
        for (a.values) |v| b.w("- `\"{s}\"`\n", .{v});
        b.w("\n", .{});
    }

    b.w("## Example\n\n```lua\nagate.config({{ gaps = 8, accordion_padding = 40, hyper = {{ \"ctrl\", \"alt\", \"cmd\" }} }})\nagate.bind(\"hyper+l\", function() agate.focus(\"right\") end)\nagate.bind(\"hyper+shift+l\", \"move right\")\nagate.bind(\"hyper+s\", function() agate.layout(\"accordion\") end)\nagate.bind(\"hyper+g\", function() agate.join(\"right\") end)\nagate.rule({{ app = \"^Music$\", space = 5 }})\nagate.rule({{ app = \"^Firefox$\", title = \"Library\", space = 2, follow = false }})\n```\n", .{});
}

fn emitLua(b: *Buf) void {
    b.w("---@meta\n", .{});
    b.w("-- Auto-generated by `zig build docs` from `tools/gen_docs.zig`. Do not edit by hand.\n", .{});
    b.w("-- LuaCATS type definitions for the global `agate` object (lua-language-server).\n\n", .{});

    for (aliases) |a| {
        b.w("---@alias {s}\n", .{a.name});
        for (a.values) |v| b.w("---| '\"{s}\"'\n", .{v});
        b.w("\n", .{});
    }

    b.w("---@class agate.Config\n", .{});
    for (settings) |s| {
        b.w("---@field {s}? {s} {s} (default `{s}`)\n", .{ s.name, s.ty, s.doc, s.default });
    }
    b.w("\n", .{});

    b.w("---@class agate.SmallScreen\n", .{});
    for (small_screen_fields) |p| {
        const opt = if (p.optional) "?" else "";
        b.w("---@field {s}{s} {s} {s}\n", .{ p.name, opt, p.ty, p.doc });
    }
    b.w("\n", .{});

    b.w("---@class agate.Rule\n", .{});
    for (rule_fields) |p| {
        const opt = if (p.optional) "?" else "";
        b.w("---@field {s}{s} {s} {s}\n", .{ p.name, opt, p.ty, p.doc });
    }
    b.w("\n", .{});

    b.w("---@class Agate\n", .{});
    b.w("agate = {{}}\n\n", .{});

    for (funcs) |f| {
        b.w("---{s}\n", .{f.doc});
        for (f.params) |p| {
            const opt = if (p.optional) "?" else "";
            b.w("---@param {s}{s} {s} {s}\n", .{ p.name, opt, p.ty, p.doc });
        }
        if (f.ret) |r| b.w("---@return {s}\n", .{r});
        b.w("function agate.{s}{s} end\n\n", .{ f.name, signature(b.alloc, f, false) });
    }

    b.w("return agate\n", .{});
}
