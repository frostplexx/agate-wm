#ifndef INPUT_KEYBIND_H
#define INPUT_KEYBIND_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

// Global hotkey daemon. An active session CGEventTap intercepts key-down events;
// matched bindings invoke their action and the event is swallowed so it never
// reaches the focused app. Separate from the listen-only Cmd+Tab tap in
// follow.m (which must stay passive).

// Action invoked on a matched binding, on the main thread. `ctx` is the opaque
// pointer registered alongside the binding (the Lua callback ref).
typedef void (*KeybindAction)(void *ctx);

// Register a binding. `mods` is a CGEventFlags mask of the required device-
// independent modifiers (command/shift/control/alternate); `key` is the virtual
// keycode. Returns false if the registry is full.
bool keybind_register(CGEventFlags mods, CGKeyCode key, KeybindAction action, void *ctx);

// Create and enable the event tap. Warns (and degrades gracefully) if the tap
// can't be created — usually missing Accessibility/Input Monitoring permission.
void keybind_start(void);

#endif // INPUT_KEYBIND_H
