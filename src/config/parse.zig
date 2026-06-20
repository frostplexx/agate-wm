//! Pure parsing helpers for the config layer: key specs, gesture specs, and the
//! name→enum maps for directions and layouts. No Lua state, no OS interaction —
//! everything here is a string in, value out, and unit-tested below.
const std = @import("std");
const gestures = @import("../wm/gestures.zig");
const focus = @import("../wm/focus/focus.zig");
const data = @import("../wm/data.zig");
const types = @import("types.zig");

const MOD_SHIFT = types.MOD_SHIFT;
const MOD_CTRL = types.MOD_CTRL;
const MOD_ALT = types.MOD_ALT;
const MOD_CMD = types.MOD_CMD;

// ---------------------------------------------------------------------------
// Mac Virtual Key Codes (kVK_* from HIToolbox/Events.h)
// ---------------------------------------------------------------------------

const KeyEntry = struct { name: []const u8, code: u16 };

/// Layout-independent keys: navigation, editing, the keypad, and the function
/// keys often remapped to a "hyper" trigger. These occupy the same physical
/// `kVK_*` keycode on every keyboard layout, so they match by name directly.
const special_keys = [_]KeyEntry{
    .{ .name = "return", .code = 36 }, .{ .name = "tab", .code = 48 },
    .{ .name = "space", .code = 49 },  .{ .name = "delete", .code = 51 },
    .{ .name = "escape", .code = 53 },
    .{ .name = "left", .code = 123 },  .{ .name = "right", .code = 124 },
    .{ .name = "down", .code = 125 },  .{ .name = "up", .code = 126 },
    // Function keys commonly used as a remapped "hyper" trigger.
    .{ .name = "f13", .code = 105 }, .{ .name = "f14", .code = 107 },
    .{ .name = "f15", .code = 113 }, .{ .name = "f16", .code = 106 },
    .{ .name = "f17", .code = 64 },  .{ .name = "f18", .code = 79 },
    .{ .name = "f19", .code = 80 },  .{ .name = "f20", .code = 90 },
    // Keypad keys (numeric pad) — distinct from the main row, so a binding can
    // target them explicitly (e.g. `hyper+kp_plus`). `kp_`/`keypad_` aliases.
    .{ .name = "kp_0", .code = 82 }, .{ .name = "keypad_0", .code = 82 },
    .{ .name = "kp_1", .code = 83 }, .{ .name = "keypad_1", .code = 83 },
    .{ .name = "kp_2", .code = 84 }, .{ .name = "keypad_2", .code = 84 },
    .{ .name = "kp_3", .code = 85 }, .{ .name = "keypad_3", .code = 85 },
    .{ .name = "kp_4", .code = 86 }, .{ .name = "keypad_4", .code = 86 },
    .{ .name = "kp_5", .code = 87 }, .{ .name = "keypad_5", .code = 87 },
    .{ .name = "kp_6", .code = 88 }, .{ .name = "keypad_6", .code = 88 },
    .{ .name = "kp_7", .code = 89 }, .{ .name = "keypad_7", .code = 89 },
    .{ .name = "kp_8", .code = 91 }, .{ .name = "keypad_8", .code = 91 },
    .{ .name = "kp_9", .code = 92 }, .{ .name = "keypad_9", .code = 92 },
    .{ .name = "kp_decimal", .code = 65 }, .{ .name = "kp_multiply", .code = 67 },
    .{ .name = "kp_plus", .code = 69 },    .{ .name = "keypad_plus", .code = 69 },
    .{ .name = "kp_clear", .code = 71 },   .{ .name = "kp_divide", .code = 75 },
    .{ .name = "kp_enter", .code = 76 },   .{ .name = "kp_minus", .code = 78 },
    .{ .name = "keypad_minus", .code = 78 }, .{ .name = "kp_equals", .code = 81 },
};

/// Printable keys at their US ANSI positions — the fallback when the active
/// layout can't resolve the character (no layout map in unit tests, or a
/// character the layout doesn't type). `plus` maps to the `=`/`+` key so a
/// `hyper+plus` binding still registers on US layouts.
const us_printable_keys = [_]KeyEntry{
    .{ .name = "a", .code = 0 },    .{ .name = "s", .code = 1 },
    .{ .name = "d", .code = 2 },    .{ .name = "f", .code = 3 },
    .{ .name = "h", .code = 4 },    .{ .name = "g", .code = 5 },
    .{ .name = "z", .code = 6 },    .{ .name = "x", .code = 7 },
    .{ .name = "c", .code = 8 },    .{ .name = "v", .code = 9 },
    .{ .name = "b", .code = 11 },   .{ .name = "q", .code = 12 },
    .{ .name = "w", .code = 13 },   .{ .name = "e", .code = 14 },
    .{ .name = "r", .code = 15 },   .{ .name = "y", .code = 16 },
    .{ .name = "t", .code = 17 },   .{ .name = "1", .code = 18 },
    .{ .name = "2", .code = 19 },   .{ .name = "3", .code = 20 },
    .{ .name = "4", .code = 21 },   .{ .name = "6", .code = 22 },
    .{ .name = "5", .code = 23 },   .{ .name = "equal", .code = 24 },
    .{ .name = "plus", .code = 24 },
    .{ .name = "9", .code = 25 },   .{ .name = "7", .code = 26 },
    .{ .name = "minus", .code = 27 }, .{ .name = "8", .code = 28 },
    .{ .name = "0", .code = 29 },   .{ .name = "o", .code = 31 },
    .{ .name = "u", .code = 32 },   .{ .name = "i", .code = 34 },
    .{ .name = "p", .code = 35 },   .{ .name = "l", .code = 37 },
    .{ .name = "j", .code = 38 },   .{ .name = "k", .code = 40 },
    .{ .name = "n", .code = 45 },   .{ .name = "m", .code = 46 },
    .{ .name = "grave", .code = 50 }, .{ .name = "comma", .code = 43 },
    .{ .name = "period", .code = 47 }, .{ .name = "slash", .code = 44 },
    .{ .name = "semicolon", .code = 41 },
};

/// Optional layout-aware resolver, installed at startup
/// (`macos.keyboard.keycodeForChar` via `api.register`). Left null in unit
/// tests so key parsing stays pure and deterministic (US fallback only).
pub var charToKeycode: ?*const fn (u8) ?u16 = null;

/// The ASCII character a printable key *name* stands for, so it can be resolved
/// against the active layout. Single-character names are themselves; the rest
/// are punctuation aliases. Special keys are deliberately absent — they're
/// layout-independent and matched by `special_keys`.
fn nameToChar(name: []const u8) ?u8 {
    if (name.len == 1) return name[0];
    const eql = std.mem.eql;
    if (eql(u8, name, "minus")) return '-';
    if (eql(u8, name, "plus")) return '+';
    if (eql(u8, name, "equal")) return '=';
    if (eql(u8, name, "comma")) return ',';
    if (eql(u8, name, "period")) return '.';
    if (eql(u8, name, "slash")) return '/';
    if (eql(u8, name, "semicolon")) return ';';
    if (eql(u8, name, "grave")) return '`';
    return null;
}

/// Resolve a key name to its hardware virtual keycode. Layout-independent keys
/// (`special_keys`) match by name; printable keys resolve to the physical key
/// that types that character on the *active* keyboard layout — so `minus`,
/// `plus`, `z`, … land correctly on German/AZERTY/Dvorak/… keyboards — and fall
/// back to the US ANSI positions when the layout map is unavailable.
pub fn lookupKeycode(name: []const u8) ?u16 {
    for (special_keys) |e| if (std.mem.eql(u8, e.name, name)) return e.code;
    if (nameToChar(name)) |ch| {
        if (charToKeycode) |f| if (f(ch)) |code| return code;
    }
    for (us_printable_keys) |e| if (std.mem.eql(u8, e.name, name)) return e.code;
    return null;
}

/// Parse a keyspec like `"hyper+shift+h"` into a modifiers bitmask and
/// virtual keycode. The last `+`-separated token that isn't a modifier name
/// is treated as the key. Returns null if the key name is not recognised.
pub fn parseKeySpec(spec: []const u8, hyper_mods: u64) ?struct { mods: u64, keycode: u16 } {
    var mods: u64 = 0;
    var key: []const u8 = "";
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "control")) {
            mods |= MOD_CTRL;
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "opt") or std.mem.eql(u8, part, "option")) {
            mods |= MOD_ALT;
        } else if (std.mem.eql(u8, part, "cmd") or std.mem.eql(u8, part, "command")) {
            mods |= MOD_CMD;
        } else if (std.mem.eql(u8, part, "shift")) {
            mods |= MOD_SHIFT;
        } else if (std.mem.eql(u8, part, "hyper")) {
            mods |= hyper_mods;
        } else {
            key = part;
        }
    }
    const code = lookupKeycode(key) orelse return null;
    return .{ .mods = mods, .keycode = code };
}

/// Parse a gesture spec like `"3:left"` / `"swipe+3+up"`: a finger count
/// (3 or 4) and a direction, in any order, separated by `:`, `+` or `-`.
/// A literal `swipe` token is allowed and ignored. Null if either is missing.
pub fn parseGestureSpec(spec: []const u8) ?struct { fingers: u8, dir: gestures.Swipe } {
    var fingers: u8 = 0;
    var dir: ?gestures.Swipe = null;
    var it = std.mem.splitAny(u8, spec, ":+-");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "swipe")) continue;
        if (part.len == 1 and part[0] >= '0' and part[0] <= '9') {
            fingers = part[0] - '0';
        } else if (std.mem.eql(u8, part, "left")) {
            dir = .left;
        } else if (std.mem.eql(u8, part, "right")) {
            dir = .right;
        } else if (std.mem.eql(u8, part, "up")) {
            dir = .up;
        } else if (std.mem.eql(u8, part, "down")) {
            dir = .down;
        } else {
            return null;
        }
    }
    if (fingers < 3 or fingers > 4) return null;
    return .{ .fingers = fingers, .dir = dir orelse return null };
}

/// Map a layout name to a tiling mode. Accepts AeroSpace-ish synonyms.
/// "toggle" is handled by `actions.setActiveLayout` (it needs the current layout).
// @doc A|agate.Layout|A layout mode. Synonyms: `h_split`/`horizontal` = `h_tiles`; `v_split`/`vertical` = `v_tiles`; `v_accordion`/`stacking`/`stacked` = `v_stack`/`accordion`; `floating` = `float`. `toggle` flips the split orientation.
// @doc AV|agate.Layout|h_tiles
// @doc AV|agate.Layout|v_tiles
// @doc AV|agate.Layout|h_stack
// @doc AV|agate.Layout|v_stack
// @doc AV|agate.Layout|accordion
// @doc AV|agate.Layout|float
// @doc AV|agate.Layout|toggle
pub fn layoutFromName(name: []const u8) ?data.Layout {
    const eql = std.mem.eql;
    if (eql(u8, name, "h_tiles") or eql(u8, name, "h_split") or eql(u8, name, "horizontal")) return .H_SPLIT;
    if (eql(u8, name, "v_tiles") or eql(u8, name, "v_split") or eql(u8, name, "vertical")) return .V_SPLIT;
    if (eql(u8, name, "h_stack") or eql(u8, name, "h_accordion")) return .H_STACK;
    if (eql(u8, name, "v_stack") or eql(u8, name, "v_accordion") or
        eql(u8, name, "accordion") or eql(u8, name, "stacking") or eql(u8, name, "stacked")) return .V_STACK;
    if (eql(u8, name, "float") or eql(u8, name, "floating")) return .FLOAT;
    return null;
}

// @doc A|agate.Direction|A focus/move/resize direction.
// @doc AV|agate.Direction|left
// @doc AV|agate.Direction|right
// @doc AV|agate.Direction|up
// @doc AV|agate.Direction|down
pub fn parseDir(s: []const u8) ?focus.Direction {
    if (std.mem.eql(u8, s, "left"))  return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up"))    return .up;
    if (std.mem.eql(u8, s, "down"))  return .down;
    return null;
}

// @doc A|agate.MonitorDir|A monitor selector: `next`/`prev` cycle displays in spatial arrangement order (left→right); `left`/`right`/`up`/`down` step to the physically adjacent display.
// @doc AV|agate.MonitorDir|next
// @doc AV|agate.MonitorDir|prev
// @doc AV|agate.MonitorDir|left
// @doc AV|agate.MonitorDir|right
// @doc AV|agate.MonitorDir|up
// @doc AV|agate.MonitorDir|down
pub fn parseMonitorDir(s: []const u8) ?focus.MonitorDir {
    if (std.mem.eql(u8, s, "next")) return .next;
    if (std.mem.eql(u8, s, "prev") or std.mem.eql(u8, s, "previous")) return .prev;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "down")) return .down;
    return null;
}

// ---------------------------------------------------------------------------
// Tests (pure parsing helpers — no Lua state or OS interaction)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseKeySpec parses modifiers and key" {
    const p = parseKeySpec("ctrl+shift+h", 0).?;
    try testing.expectEqual(MOD_CTRL | MOD_SHIFT, p.mods);
    try testing.expectEqual(@as(u16, 4), p.keycode); // kVK_ANSI_H

    const plain = parseKeySpec("space", 0).?;
    try testing.expectEqual(@as(u64, 0), plain.mods);
    try testing.expectEqual(@as(u16, 49), plain.keycode);
}

test "parseKeySpec expands hyper to the configured modifier set" {
    const hyper = MOD_CMD | MOD_ALT;
    const p = parseKeySpec("hyper+l", hyper).?;
    try testing.expectEqual(hyper, p.mods);
    try testing.expectEqual(@as(u16, 37), p.keycode); // kVK_ANSI_L
}

test "parseKeySpec rejects unknown or missing keys" {
    try testing.expect(parseKeySpec("ctrl+notakey", 0) == null);
    try testing.expect(parseKeySpec("ctrl+shift", 0) == null); // modifiers only
}

test "lookupKeycode: US fallback for plus/minus and the keypad" {
    try testing.expectEqual(@as(u16, 27), lookupKeycode("minus").?);
    try testing.expectEqual(@as(u16, 24), lookupKeycode("equal").?);
    try testing.expectEqual(@as(u16, 24), lookupKeycode("plus").?); // alias of the =/+ key
    try testing.expectEqual(@as(u16, 69), lookupKeycode("kp_plus").?);
    try testing.expectEqual(@as(u16, 78), lookupKeycode("keypad_minus").?);
    try testing.expectEqual(@as(u16, 49), lookupKeycode("space").?);
    try testing.expect(lookupKeycode("nope") == null);
}

test "lookupKeycode resolves printable keys against the active layout when set" {
    // Stand-in layout map: "+" lives on an unshifted key (code 200), as on a
    // German keyboard — proving the layout hook wins over the US fallback for
    // printable keys, while special keys stay layout-independent.
    const Stub = struct {
        fn f(ch: u8) ?u16 {
            return switch (ch) {
                '+' => 200,
                '-' => 201,
                else => null, // not on this "layout" → US fallback
            };
        }
    };
    charToKeycode = &Stub.f;
    defer charToKeycode = null;

    try testing.expectEqual(@as(u16, 200), lookupKeycode("plus").?); // layout, not 24
    try testing.expectEqual(@as(u16, 201), lookupKeycode("minus").?); // layout, not 27
    try testing.expectEqual(@as(u16, 24), lookupKeycode("equal").?); // '=' absent → US fallback
    try testing.expectEqual(@as(u16, 49), lookupKeycode("space").?); // special: never via layout
    try testing.expectEqual(@as(u16, 69), lookupKeycode("kp_plus").?); // keypad stays fixed
}

test "layoutFromName maps names and synonyms" {
    try testing.expectEqual(data.Layout.H_SPLIT, layoutFromName("h_tiles").?);
    try testing.expectEqual(data.Layout.H_SPLIT, layoutFromName("horizontal").?);
    try testing.expectEqual(data.Layout.V_SPLIT, layoutFromName("vertical").?);
    try testing.expectEqual(data.Layout.H_STACK, layoutFromName("h_accordion").?);
    try testing.expectEqual(data.Layout.V_STACK, layoutFromName("accordion").?);
    try testing.expectEqual(data.Layout.V_STACK, layoutFromName("stacking").?);
    try testing.expectEqual(data.Layout.FLOAT, layoutFromName("floating").?);
    try testing.expect(layoutFromName("bogus") == null);
}

test "parseGestureSpec parses finger count and direction" {
    const p = parseGestureSpec("3:left").?;
    try testing.expectEqual(@as(u8, 3), p.fingers);
    try testing.expectEqual(gestures.Swipe.left, p.dir);

    const q = parseGestureSpec("swipe+4+up").?; // alternate separators, swipe token
    try testing.expectEqual(@as(u8, 4), q.fingers);
    try testing.expectEqual(gestures.Swipe.up, q.dir);

    const r = parseGestureSpec("right:3").? ; // order-insensitive
    try testing.expectEqual(gestures.Swipe.right, r.dir);

    try testing.expect(parseGestureSpec("2:left") == null); // 2 fingers is scrolling
    try testing.expect(parseGestureSpec("5:left") == null); // unsupported count
    try testing.expect(parseGestureSpec("3") == null); // no direction
    try testing.expect(parseGestureSpec("3:sideways") == null); // bad direction
}

test "parseDir maps direction names" {
    try testing.expectEqual(focus.Direction.left, parseDir("left").?);
    try testing.expectEqual(focus.Direction.down, parseDir("down").?);
    try testing.expect(parseDir("sideways") == null);
}
