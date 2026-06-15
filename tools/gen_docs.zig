//! Reads `// @doc` annotations from every `.zig` file in src/config/ and emits:
//!   * Configuration.md  — settings reference for the GitHub wiki (installed to
//!                         zig-out, not committed; published by
//!                         `just publish-docs`)
//!   * types/agate.lua   — LuaCATS type stub for lua-language-server (committed)
//!
//! Invoked by `zig build docs` (see build.zig). Never edit this file when
//! adding settings — add `// @doc` lines next to the code in src/config/.
//!
//! Annotation format (use | as field separator; never use | inside a field
//! value except in FP type names, which are parsed from both ends):
//!
//!   // @doc S|name|lua_type|default|description
//!   // @doc SS|name|lua_type|optional|description      (small_screen fields)
//!   // @doc SR|name|lua_type|optional|description      (rule fields)
//!   // @doc A|name|description                         (start an alias)
//!   // @doc AV|alias_name|value                        (alias value; follows its A)
//!   // @doc F|name|description                         (api function)
//!   // @doc FP|func|param|type|optional|description    (function param)
//!   // @doc C|form|description                         (string command)
const std = @import("std");

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

const Setting = struct { name: []const u8, ty: []const u8, default: []const u8, doc: []const u8 };
const Param = struct { name: []const u8, ty: []const u8, optional: bool, doc: []const u8 };
const Alias = struct { name: []const u8, doc: []const u8, values: [][]const u8 };
const Func = struct { name: []const u8, doc: []const u8 };
const FuncParam = struct { func: []const u8, name: []const u8, ty: []const u8, optional: bool, doc: []const u8 };
const Command = struct { form: []const u8, doc: []const u8 };

const ApiData = struct {
    settings: []Setting,
    small_screen: []Param,
    rule_fields: []Param,
    aliases: []Alias,
    funcs: []Func,
    func_params: []FuncParam,
    commands: []Command,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

fn parse(alloc: std.mem.Allocator, src: []const u8) !ApiData {
    var settings: std.ArrayList(Setting) = .empty;
    var small_screen: std.ArrayList(Param) = .empty;
    var rule_fields: std.ArrayList(Param) = .empty;
    const AliasBuilder = struct { name: []const u8, doc: []const u8, values: std.ArrayList([]const u8) };
    var alias_builders: std.ArrayList(AliasBuilder) = .empty;
    var funcs: std.ArrayList(Func) = .empty;
    var func_params: std.ArrayList(FuncParam) = .empty;
    var commands: std.ArrayList(Command) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        const pfx = "// @doc ";
        if (!std.mem.startsWith(u8, line, pfx)) continue;
        const rest = line[pfx.len..];

        if (std.mem.startsWith(u8, rest, "S|")) {
            var it = std.mem.splitScalar(u8, rest[2..], '|');
            const name = it.next() orelse continue;
            const ty = it.next() orelse continue;
            const def = it.next() orelse continue;
            try settings.append(alloc, .{ .name = name, .ty = ty, .default = def, .doc = it.rest() });

        } else if (std.mem.startsWith(u8, rest, "SS|")) {
            var it = std.mem.splitScalar(u8, rest[3..], '|');
            const name = it.next() orelse continue;
            const ty = it.next() orelse continue;
            const opt = it.next() orelse continue;
            try small_screen.append(alloc, .{ .name = name, .ty = ty, .optional = eql(opt, "true"), .doc = it.rest() });

        } else if (std.mem.startsWith(u8, rest, "SR|")) {
            var it = std.mem.splitScalar(u8, rest[3..], '|');
            const name = it.next() orelse continue;
            const ty = it.next() orelse continue;
            const opt = it.next() orelse continue;
            try rule_fields.append(alloc, .{ .name = name, .ty = ty, .optional = eql(opt, "true"), .doc = it.rest() });

        } else if (std.mem.startsWith(u8, rest, "AV|")) {
            // Append value to the last alias (A lines must precede their AV lines).
            var it = std.mem.splitScalar(u8, rest[3..], '|');
            _ = it.next(); // alias name — unused, we just append to the last entry
            const value = it.next() orelse continue;
            if (alias_builders.items.len > 0)
                try alias_builders.items[alias_builders.items.len - 1].values.append(alloc, value);

        } else if (std.mem.startsWith(u8, rest, "A|")) {
            var it = std.mem.splitScalar(u8, rest[2..], '|');
            const name = it.next() orelse continue;
            try alias_builders.append(alloc, .{ .name = name, .doc = it.rest(), .values = .empty });

        } else if (std.mem.startsWith(u8, rest, "FP|")) {
            // Parse from both ends so the type field (field 3) may safely contain '|'.
            // Format: FP|func|param|...type...|optional|description
            const s = rest[3..];
            const func_end = std.mem.indexOfScalar(u8, s, '|') orelse continue;
            const func_name = s[0..func_end];
            const s2 = s[func_end + 1 ..];
            const name_end = std.mem.indexOfScalar(u8, s2, '|') orelse continue;
            const param_name = s2[0..name_end];
            const s3 = s2[name_end + 1 ..]; // "type_possibly_with_pipes|optional|doc"
            const doc_sep = std.mem.lastIndexOfScalar(u8, s3, '|') orelse continue;
            const doc = s3[doc_sep + 1 ..];
            const s4 = s3[0..doc_sep]; // "type_possibly_with_pipes|optional"
            const opt_sep = std.mem.lastIndexOfScalar(u8, s4, '|') orelse continue;
            const ty = s4[0..opt_sep];
            const opt = s4[opt_sep + 1 ..];
            try func_params.append(alloc, .{ .func = func_name, .name = param_name, .ty = ty, .optional = eql(opt, "true"), .doc = doc });

        } else if (std.mem.startsWith(u8, rest, "F|")) {
            var it = std.mem.splitScalar(u8, rest[2..], '|');
            const name = it.next() orelse continue;
            try funcs.append(alloc, .{ .name = name, .doc = it.rest() });

        } else if (std.mem.startsWith(u8, rest, "C|")) {
            // Split on the last '|' so the form may contain '|' (e.g. `cycle <next|prev>`).
            const s = rest[2..];
            const sep = std.mem.lastIndexOfScalar(u8, s, '|') orelse continue;
            try commands.append(alloc, .{ .form = s[0..sep], .doc = s[sep + 1 ..] });
        }
    }

    const aliases = try alloc.alloc(Alias, alias_builders.items.len);
    for (alias_builders.items, aliases) |*ab, *a|
        a.* = .{ .name = ab.name, .doc = ab.doc, .values = try ab.values.toOwnedSlice(alloc) };

    return .{
        .settings = try settings.toOwnedSlice(alloc),
        .small_screen = try small_screen.toOwnedSlice(alloc),
        .rule_fields = try rule_fields.toOwnedSlice(alloc),
        .aliases = aliases,
        .funcs = try funcs.toOwnedSlice(alloc),
        .func_params = try func_params.toOwnedSlice(alloc),
        .commands = try commands.toOwnedSlice(alloc),
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

fn writeSignature(w: anytype, func_name: []const u8, params: []FuncParam, mark_optional: bool) !void {
    try w.writeByte('(');
    var first = true;
    for (params) |p| {
        if (!eql(p.func, func_name)) continue;
        if (!first) try w.writeAll(", ");
        try w.writeAll(p.name);
        if (mark_optional and p.optional) try w.writeByte('?');
        first = false;
    }
    try w.writeByte(')');
}

// ---------------------------------------------------------------------------
// Markdown renderer
// ---------------------------------------------------------------------------

fn renderMarkdown(w: anytype, d: ApiData) !void {
    try w.writeAll("# agate configuration\n\n");
    try w.writeAll("> Auto-generated by `zig build docs` from annotations in `src/config/lua.zig`. Do not edit by hand.\n\n");
    try w.writeAll("All configuration is Lua, loaded from `$WM_CONFIG`, `$XDG_CONFIG_HOME/agate/init.lua`, `~/.config/agate/init.lua`, or `./init.lua`.\n\n");

    try w.writeAll("## `agate.config{}` settings\n\n");
    try w.writeAll("| Key | Type | Default | Description |\n| --- | --- | --- | --- |\n");
    for (d.settings) |s|
        try w.print("| `{s}` | `{s}` | `{s}` | {s} |\n", .{ s.name, s.ty, s.default, s.doc });
    try w.writeByte('\n');

    try w.writeAll("## `small_screen` fields (Small Screen Mode)\n\n");
    try w.writeAll("On a small main display (the built-in panel, or anything at or under `max_width` points), workspaces still on the default split layout switch to `layout` — a straight tiling split is not useful on a tiny screen. They switch back when a big display takes over (dock/undock re-evaluates). Workspaces whose layout was set by hand are left alone in both directions. Pair with `agate.gesture` for trackpad-driven window cycling.\n\n");
    try w.writeAll("| Key | Type | Description |\n| --- | --- | --- |\n");
    for (d.small_screen) |p|
        try w.print("| `{s}` | `{s}` | {s}{s} |\n", .{ p.name, p.ty, p.doc, if (p.optional) " _(optional)_" else "" });
    try w.writeByte('\n');

    try w.writeAll("## `agate.rule{}` fields\n\n");
    try w.writeAll("| Key | Type | Description |\n| --- | --- | --- |\n");
    for (d.rule_fields) |p|
        try w.print("| `{s}` | `{s}` | {s}{s} |\n", .{ p.name, p.ty, p.doc, if (p.optional) " _(optional)_" else "" });
    try w.writeByte('\n');

    try w.writeAll("## API\n\n");
    for (d.funcs) |f| {
        try w.print("### `agate.{s}", .{f.name});
        try writeSignature(w, f.name, d.func_params, true);
        try w.writeAll("`\n\n");
        try w.print("{s}\n\n", .{f.doc});
        var has_params = false;
        for (d.func_params) |p| {
            if (!eql(p.func, f.name)) continue;
            try w.print("- `{s}` (`{s}`){s} — {s}\n", .{ p.name, p.ty, if (p.optional) " _(optional)_" else "", p.doc });
            has_params = true;
        }
        if (has_params) try w.writeByte('\n');
    }

    try w.writeAll("## Commands\n\n");
    try w.writeAll("Strings passed as the second argument of `agate.bind` instead of a function:\n\n");
    try w.writeAll("| Command | Description |\n| --- | --- |\n");
    for (d.commands) |c|
        try w.print("| `{s}` | {s} |\n", .{ c.form, c.doc });
    try w.writeByte('\n');

    try w.writeAll("## Enumerations\n\n");
    for (d.aliases) |a| {
        try w.print("### `{s}`\n\n{s}\n\n", .{ a.name, a.doc });
        for (a.values) |v| try w.print("- `\"{s}\"`\n", .{v});
        try w.writeByte('\n');
    }

    try w.writeAll(
        \\## Example
        \\
        \\```lua
        \\agate.config({ gaps = 8, accordion_padding = 40, hyper = { "ctrl", "alt", "cmd" } })
        \\agate.bind("hyper+l", function() agate.focus("right") end)
        \\agate.bind("hyper+shift+l", "move right")
        \\agate.bind("hyper+s", function() agate.layout("accordion") end)
        \\agate.bind("hyper+g", function() agate.join("right") end)
        \\agate.rule({ app = "^Music$", space = 5 })
        \\agate.rule({ app = "^Firefox$", title = "Library", space = 2, follow = false })
        \\```
        \\
    );
}

// ---------------------------------------------------------------------------
// LuaCATS renderer
// ---------------------------------------------------------------------------

fn renderLua(w: anytype, d: ApiData) !void {
    try w.writeAll("---@meta\n");
    try w.writeAll("-- Auto-generated by `zig build docs`. Do not edit by hand.\n");
    try w.writeAll("-- LuaCATS type definitions for the global `agate` object (lua-language-server).\n\n");

    for (d.aliases) |a| {
        try w.print("---@alias {s}\n", .{a.name});
        for (a.values) |v| try w.print("---| '\"{s}\"'\n", .{v});
        try w.writeByte('\n');
    }

    try w.writeAll("---@class agate.Config\n");
    for (d.settings) |s|
        try w.print("---@field {s}? {s} {s} (default `{s}`)\n", .{ s.name, s.ty, s.doc, s.default });
    try w.writeByte('\n');

    try w.writeAll("---@class agate.SmallScreen\n");
    for (d.small_screen) |p|
        try w.print("---@field {s}{s} {s} {s}\n", .{ p.name, if (p.optional) "?" else "", p.ty, p.doc });
    try w.writeByte('\n');

    try w.writeAll("---@class agate.Rule\n");
    for (d.rule_fields) |p|
        try w.print("---@field {s}{s} {s} {s}\n", .{ p.name, if (p.optional) "?" else "", p.ty, p.doc });
    try w.writeByte('\n');

    try w.writeAll("---@class Agate\nagate = {}\n\n");

    for (d.funcs) |f| {
        try w.print("---{s}\n", .{f.doc});
        for (d.func_params) |p| {
            if (!eql(p.func, f.name)) continue;
            try w.print("---@param {s}{s} {s} {s}\n", .{ p.name, if (p.optional) "?" else "", p.ty, p.doc });
        }
        try w.print("function agate.{s}", .{f.name});
        try writeSignature(w, f.name, d.func_params, false);
        try w.writeAll(" end\n\n");
    }

    try w.writeAll("return agate\n");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Concatenate every `.zig` file in `dir_path` (sorted by name for determinism)
/// so the `@doc` annotations can live next to their code across the config
/// split, not just in one file. Per-file content stays contiguous, so an alias's
/// `A|`/`AV|` lines (which must appear in order) are never interleaved.
fn readConfigDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name)); // name buffer is reused — copy now
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var src: std.ArrayList(u8) = .empty;
    for (names.items) |name| {
        const contents = try dir.readFileAlloc(io, name, alloc, .unlimited);
        try src.appendSlice(alloc, contents);
        try src.append(alloc, '\n');
    }
    return src.items;
}

pub fn main(init: std.process.Init) !void {
    const usage = "usage: gen_docs <config_dir> <out.md> <out.lua>\n";
    var argv = std.process.Args.iterate(init.minimal.args);
    _ = argv.next(); // exe path
    const dir_path = argv.next() orelse { std.debug.print("{s}", .{usage}); std.process.exit(1); };
    const md_path  = argv.next() orelse { std.debug.print("{s}", .{usage}); std.process.exit(1); };
    const lua_path2 = argv.next() orelse { std.debug.print("{s}", .{usage}); std.process.exit(1); };

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const src = try readConfigDir(init.io, alloc, dir_path);
    const data = try parse(alloc, src);

    var md = std.Io.Writer.Allocating.init(alloc);
    try renderMarkdown(&md.writer, data);
    try cwd.writeFile(init.io, .{ .sub_path = md_path, .data = md.written() });

    var lua_out = std.Io.Writer.Allocating.init(alloc);
    try renderLua(&lua_out.writer, data);
    try cwd.writeFile(init.io, .{ .sub_path = lua_path2, .data = lua_out.written() });
}
