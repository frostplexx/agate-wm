//! Event callbacks (`agate.on`): user Lua functions run when the WM performs an
//! action — a Space change, a mode switch, a window appearing or closing. The
//! mechanism mirrors the keybinding path (a Lua registry ref invoked through
//! `protectedCall`), but the trigger is a WM event rather than a key chord, so
//! init.lua can react to things agate does on its own — e.g. run a shell command
//! whenever the active Space changes.
//!
//! Registration (`agate.on(name, fn)`) lives in `api.zig`; the WM event sites
//! (mostly `wm/observer.zig`, plus `keybind.zig` for mode changes) call the
//! `emit*` helpers below. Each handler is handed a single table argument whose
//! fields depend on the event (see the `emit*` doc comments).
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const ctx = @import("context.zig");

/// The actions init.lua can hook with `agate.on`. The enum field names are the
/// exact strings passed to `agate.on` (matched via `std.meta.stringToEnum`).
pub const Event = enum {
    /// The active Space changed (any display). Payload: `{ space = <1-based
    /// position> }`.
    space_changed,
    /// A modal keymap was entered or left (`agate.enter_mode`/`exit_mode`).
    /// Payload: `{ mode = "<name>" }` on enter, `{ mode = nil }` on exit.
    mode_changed,
    /// A new window was picked up and tiled. Payload: `{ window = <id> }`.
    window_created,
    /// A tracked window closed. Payload: `{ window = <id> }`.
    window_destroyed,

    /// Resolve a Lua event name to its enum, or null if unknown.
    pub fn fromName(name: []const u8) ?Event {
        return std.meta.stringToEnum(Event, name);
    }
};

/// One registered callback: which event fires it, and the Lua registry ref of
/// the function to call. The ref is released in `lua.deinit` (see the cleanup
/// loop there), like binding/gesture refs.
pub const Handler = struct {
    event: Event,
    lua_fn: i32,
};

/// Call every handler registered for `event`, passing a single table argument
/// built from the fields of `payload` (a Zig struct — its field names become the
/// table keys). Safe to call when nothing is registered (cheap early-out) and
/// when the config is torn down. Must run on the main thread, like every other
/// Lua call in agate.
pub fn emit(event: Event, payload: anytype) void {
    const cfg = ctx.config orelse return;
    if (cfg.event_handlers.items.len == 0) return;
    for (cfg.event_handlers.items) |h| {
        if (h.event != event) continue;
        _ = cfg.lua.getIndexRaw(zlua.registry_index, h.lua_fn);
        pushPayload(cfg.lua, payload);
        cfg.lua.protectedCall(.{ .args = 1, .results = 0 }) catch |err| {
            std.debug.print("[config] {s} handler error: {}\n", .{ @tagName(event), err });
        };
    }
}

/// Push a Lua table whose keys/values mirror the fields of the struct `payload`.
/// Field types are mapped by `pushValue`; an optional field that is null becomes
/// a nil entry (so e.g. `mode_changed` on exit yields `{ mode = nil }`).
fn pushPayload(lua: *Lua, payload: anytype) void {
    const info = @typeInfo(@TypeOf(payload)).@"struct";
    lua.createTable(0, info.fields.len);
    inline for (info.fields) |f| {
        pushValue(lua, @field(payload, f.name));
        lua.setField(-2, f.name);
    }
}

/// Push a single Zig value as the matching Lua value. Handles the field types the
/// `emit*` payloads use: integers, booleans, `[]const u8` strings, and optionals
/// of those (null → nil).
fn pushValue(lua: *Lua, v: anytype) void {
    switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => lua.pushInteger(@intCast(v)),
        .bool => lua.pushBoolean(v),
        .optional => if (v) |inner| pushValue(lua, inner) else lua.pushNil(),
        .pointer => _ = lua.pushString(v), // []const u8 slice
        else => lua.pushNil(),
    }
}

// ---------------------------------------------------------------------------
// Typed emit helpers — one per event, so call sites stay readable and the
// payload shape for each event lives in exactly one place.
// ---------------------------------------------------------------------------

/// Fire `space_changed` with the new active Space's 1-based position.
pub fn emitSpaceChanged(space: usize) void {
    emit(.space_changed, .{ .space = space });
}

/// Fire `mode_changed` with the entered mode's name, or null when leaving a mode.
pub fn emitModeChanged(mode: ?[]const u8) void {
    emit(.mode_changed, .{ .mode = mode });
}

/// Fire `window_created` with the new window's id.
pub fn emitWindowCreated(window_id: u64) void {
    emit(.window_created, .{ .window = window_id });
}

/// Fire `window_destroyed` with the closed window's id.
pub fn emitWindowDestroyed(window_id: u64) void {
    emit(.window_destroyed, .{ .window = window_id });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Event.fromName maps the public event names" {
    try std.testing.expectEqual(Event.space_changed, Event.fromName("space_changed").?);
    try std.testing.expectEqual(Event.mode_changed, Event.fromName("mode_changed").?);
    try std.testing.expectEqual(Event.window_created, Event.fromName("window_created").?);
    try std.testing.expectEqual(Event.window_destroyed, Event.fromName("window_destroyed").?);
    try std.testing.expect(Event.fromName("nope") == null);
}

/// Build a throwaway Config wired to `lua` with no handlers. Only the fields
/// `emit` touches are set; the rest stay undefined (the test never reads them).
fn testConfig(alloc: std.mem.Allocator, lua: *Lua) @import("types.zig").Config {
    var cfg: @import("types.zig").Config = undefined;
    cfg.alloc = alloc;
    cfg.lua = lua;
    cfg.event_handlers = .empty;
    return cfg;
}

test "emit delivers an integer payload field to the registered handler" {
    const alloc = std.testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    var cfg = testConfig(alloc, lua);
    defer cfg.event_handlers.deinit(alloc);
    ctx.config = &cfg;
    defer ctx.config = null;

    try lua.doString("function __cb(e) captured = e.space end");
    _ = lua.getGlobal("__cb");
    const ref = lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, ref);
    try cfg.event_handlers.append(alloc, .{ .event = .space_changed, .lua_fn = ref });

    emitSpaceChanged(7);

    _ = lua.getGlobal("captured");
    try std.testing.expectEqual(@as(zlua.Integer, 7), try lua.toInteger(-1));
    lua.pop(1);
}

test "emit passes a string payload, and nil for a null optional" {
    const alloc = std.testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    var cfg = testConfig(alloc, lua);
    defer cfg.event_handlers.deinit(alloc);
    ctx.config = &cfg;
    defer ctx.config = null;

    try lua.doString("function __cb(e) captured = e.mode or '<nil>' end");
    _ = lua.getGlobal("__cb");
    const ref = lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, ref);
    try cfg.event_handlers.append(alloc, .{ .event = .mode_changed, .lua_fn = ref });

    emitModeChanged("resize");
    _ = lua.getGlobal("captured");
    try std.testing.expectEqualStrings("resize", std.mem.sliceTo(try lua.toString(-1), 0));
    lua.pop(1);

    emitModeChanged(null);
    _ = lua.getGlobal("captured");
    try std.testing.expectEqualStrings("<nil>", std.mem.sliceTo(try lua.toString(-1), 0));
    lua.pop(1);
}

test "emit only fires handlers registered for that event" {
    const alloc = std.testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    var cfg = testConfig(alloc, lua);
    defer cfg.event_handlers.deinit(alloc);
    ctx.config = &cfg;
    defer ctx.config = null;

    try lua.doString("hits = 0; function __cb(e) hits = hits + 1 end");
    _ = lua.getGlobal("__cb");
    const ref = lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, ref);
    try cfg.event_handlers.append(alloc, .{ .event = .window_created, .lua_fn = ref });

    emitSpaceChanged(1); // different event — must not fire the handler
    emitWindowCreated(42); // matching event — fires once

    _ = lua.getGlobal("hits");
    try std.testing.expectEqual(@as(zlua.Integer, 1), try lua.toInteger(-1));
    lua.pop(1);
}
