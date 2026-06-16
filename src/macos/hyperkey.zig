//! Built-in hyper key — ported from frostplexx/LazyKeys (HyperKey.swift).
//!
//! Remaps Caps Lock to F18 at the HID-driver level with `hidutil`, so a held
//! Caps Lock arrives at our keyboard tap as plain F18 key-down/up events. agate
//! intercepts F18 in `wm/observer.zig` (`keyTap`): while it is held, the focused
//! app — and agate's own keybindings — see the configured hyper modifiers
//! (Cmd+Ctrl+Alt+Shift by default). This module owns only the system-level
//! remap and its teardown.
//!
//! The remap persists at the HID layer until cleared, so `enable` also installs
//! signal handlers that restore the default Caps Lock on exit (as LazyKeys does).
//! SIGKILL can't be caught, so a hard kill leaves Caps Lock mapped to F18 until
//! the next `hidutil` reset or reboot — the same limitation LazyKeys has.
//!
//! Why F18? It's effectively unused on real keyboards, so it never collides with
//! an app shortcut — the "clean slate" trick from Ryan Hanson's article that
//! LazyKeys (and Karabiner's complex mods) rely on.
const std = @import("std");

/// kVK_F18 — the virtual keycode Caps Lock is remapped to. The observer's
/// keyboard tap watches for this as the hyper trigger.
pub const F18_KEYCODE: u16 = 79;

// `fork` and `signal` aren't exposed by Zig 0.16's std (private/absent), so
// declare just these two; `execve`/`waitpid`/`_exit`/`environ` come from std.c.
extern "c" fn fork() std.c.pid_t;
const SigHandler = *const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SigHandler) SigHandler;

const SIGINT: c_int = 2;
const SIGQUIT: c_int = 3;
const SIGTERM: c_int = 15;

// hidutil `UserKeyMapping` payloads. Caps Lock HID usage 0x700000039 → F18
// 0x70000006D, written in decimal so the JSON needs no hex handling. These are
// compile-time string constants on purpose: the cleanup signal handler must stay
// async-signal-safe, so teardown forks/execs a prebuilt string with no JSON
// serialization (which would not be signal-safe).
const REMAP_JSON: [*:0]const u8 =
    "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}";
const RESET_JSON: [*:0]const u8 = "{\"UserKeyMapping\":[]}";

/// Run `/usr/bin/hidutil property --set <json>` and wait for it. Synchronous so
/// the remap is settled before the keyboard tap starts seeing F18. fork/execve/
/// waitpid are all async-signal-safe, so this is also safe to call from the
/// teardown signal handler.
fn runHidutil(json: [*:0]const u8) void {
    const pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/hidutil", "property", "--set", json };
        _ = std.c.execve("/usr/bin/hidutil", &argv, @ptrCast(std.c.environ));
        std.c._exit(127); // execve only returns on failure
    }
    _ = std.c.waitpid(pid, null, 0);
}

/// SIGINT/SIGTERM/SIGQUIT handler: restore the default Caps Lock, then exit, so a
/// normal quit doesn't leave Caps Lock stuck as F18 (LazyKeys' cleanup model).
fn onSignal(_: c_int) callconv(.c) void {
    runHidutil(RESET_JSON);
    std.c._exit(0);
}

/// Remap Caps Lock → F18 and install the cleanup signal handlers. Call once at
/// startup, only when the hyper key is enabled in the config.
pub fn enable() void {
    runHidutil(REMAP_JSON);
    _ = signal(SIGINT, onSignal);
    _ = signal(SIGTERM, onSignal);
    _ = signal(SIGQUIT, onSignal);
    std.debug.print("[hyperkey] Caps Lock → F18 remap active (hidutil)\n", .{});
}

/// Restore the default Caps Lock mapping (clears the F18 remap).
pub fn disable() void {
    runHidutil(RESET_JSON);
}
