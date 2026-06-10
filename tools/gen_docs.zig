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
};

// String commands accepted by `agate.bind(spec, "<command>")`.
const Command = struct { form: []const u8, doc: []const u8 };
const commands = [_]Command{
    .{ .form = "move <dir>", .doc = "Same as `agate.move(dir)`." },
    .{ .form = "focus <dir>", .doc = "Same as `agate.focus(dir)`." },
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

    b.w("## Example\n\n```lua\nagate.config({{ gaps = 8, accordion_padding = 40, hyper = {{ \"ctrl\", \"alt\", \"cmd\" }} }})\nagate.bind(\"hyper+l\", function() agate.focus(\"right\") end)\nagate.bind(\"hyper+shift+l\", \"move right\")\nagate.bind(\"hyper+s\", function() agate.layout(\"accordion\") end)\nagate.bind(\"hyper+g\", function() agate.join(\"right\") end)\n```\n", .{});
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
