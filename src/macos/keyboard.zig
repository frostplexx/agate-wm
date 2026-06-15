//! Active-keyboard-layout key resolution.
//!
//! agate's keyspecs name keys by the character they *type* — `minus`, `equal`,
//! `z`, the digits — but a keyspec ultimately has to match a hardware virtual
//! keycode. On a US ANSI keyboard the character and the keycode line up with the
//! `kVK_ANSI_*` constants, which is what `parse.zig`'s fallback table assumes.
//! On a German/AZERTY/Dvorak/… layout they do *not*: "-" and "+" sit on
//! different physical keys, so a hardcoded US table binds the wrong key (the
//! root cause of "resize keys don't work" for non-US users, issue #6).
//!
//! This maps a character to the virtual keycode that types it on the user's
//! *current* layout, via Carbon's `UCKeyTranslate`. `parse.lookupKeycode`
//! consults it for printable keys (falling back to the US table when a character
//! isn't on the layout or the lookup is unavailable, e.g. in unit tests).
const c = @import("c.zig").c;

// Carbon / HIToolbox Text Input Sources SPI. Hand-declared as `extern` (the
// Carbon umbrella header defeats Zig's translate-c — the same reason the AX API
// is hand-declared in `ax.zig`); linking the Carbon framework resolves them.
const TISInputSourceRef = ?*anyopaque;
extern fn TISCopyCurrentKeyboardLayoutInputSource() TISInputSourceRef;
extern fn TISGetInputSourceProperty(source: TISInputSourceRef, propertyKey: c.CFStringRef) ?*anyopaque;
extern const kTISPropertyUnicodeKeyLayoutData: c.CFStringRef;
extern fn LMGetKbdType() u8;
extern fn UCKeyTranslate(
    keyLayoutPtr: *const anyopaque,
    virtualKeyCode: u16,
    keyAction: u16,
    modifierKeyState: u32,
    keyboardType: u32,
    keyTranslateOptions: u32,
    deadKeyState: *u32,
    maxStringLength: u32,
    actualStringLength: *u32,
    unicodeString: [*]u16,
) i32;

/// `kUCKeyActionDisplay` — translate as if for display (no key-up/down state).
const kUCKeyActionDisplay: u16 = 3;
/// `1 << kUCKeyTranslateNoDeadKeysBit` — never enter a dead-key sequence, so a
/// key like `grave` resolves to its own character instead of arming an accent.
const no_dead_keys: u32 = 1;

/// Cache: char → virtual keycode for the layout sampled on first use. Lower
/// keycodes win a tie so the main-row key is preferred over its keypad twin.
/// Built once (config is loaded once); a mid-session layout switch is not
/// tracked, which matches how bindings are parsed a single time at startup.
var char_to_code: [128]?u16 = [_]?u16{null} ** 128;
var built: bool = false;

/// Sample the active layout and fill `char_to_code`. Marks `built` even on
/// failure so a missing/odd input source doesn't re-probe Carbon on every call;
/// callers then fall back to the US table.
fn build() void {
    built = true;
    const src = TISCopyCurrentKeyboardLayoutInputSource() orelse return;
    defer c.CFRelease(src);
    const data_ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) orelse return;
    const data: c.CFDataRef = @ptrCast(data_ptr);
    const layout = c.CFDataGetBytePtr(data) orelse return;
    const kbd_type: u32 = LMGetKbdType();

    var code: u16 = 0;
    while (code < 128) : (code += 1) {
        // Skip the numeric keypad: its keys type digits and operators *without*
        // shift, so they'd shadow the main row for characters that need shift
        // there — e.g. on a US layout `+` is shift+`=` on the main row but bare
        // on the keypad, so the keypad would capture `+` and a `hyper+plus`
        // binding would only fire from the numpad (issue #6). The keypad is
        // still bindable by its explicit `kp_*` names.
        if (isKeypad(code)) continue;
        var dead: u32 = 0;
        var out: [4]u16 = undefined;
        var len: u32 = 0;
        const status = UCKeyTranslate(layout, code, kUCKeyActionDisplay, 0, kbd_type, no_dead_keys, &dead, out.len, &len, &out);
        if (status != 0 or len != 1) continue; // no/dead/multi-char output
        const u = out[0];
        if (u < 128) {
            const ch: usize = @intCast(u);
            if (char_to_code[ch] == null) char_to_code[ch] = code;
        }
    }
}

/// Whether `code` is a numeric-keypad virtual keycode (`kVK_ANSI_Keypad*`).
fn isKeypad(code: u16) bool {
    return switch (code) {
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92 => true,
        else => false,
    };
}

/// The virtual keycode that types ASCII character `ch` on the active keyboard
/// layout, or null if no key produces it (or the layout couldn't be read).
pub fn keycodeForChar(ch: u8) ?u16 {
    if (!built) build();
    if (ch >= 128) return null;
    return char_to_code[ch];
}
