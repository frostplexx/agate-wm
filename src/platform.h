#ifndef PLATFORM_H
#define PLATFORM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#include "accessibility/observers.h"

// Must be called first. Initialises NSApplication as an accessory background
// process (no Dock icon, no menu bar) while keeping the full per-session
// WindowServer connection required for workspace notifications to be delivered.
void platform_init(void);

// Register for Mission Control space-switch notifications via NSWorkspace.
// More reliable than CGSRegisterNotifyProc, which requires a full app session.
void platform_watch_spaces(WMEventCallback cb, void *userdata);

// Register AX observers for every regular-activation app currently running
// (apps with a Dock presence, including Finder — even when it has no windows).
void platform_watch_running_apps(WMEventCallback cb, void *userdata);

// Current active (visible) space id of the focused display, or 0 if it can't
// be read.
uint64_t platform_active_space(void);

// Move a window to another Mission Control (managed Desktop) space. Instant,
// no animation, and — unlike yabai's scripting addition — does NOT require SIP
// to be disabled: it drives the SkyLight WindowManagement bridge operation
// (SLSBridgedMoveWindowsToManagedSpaceOperation) in-process via the ObjC
// runtime. Returns false if the private operation class is unavailable.
bool platform_move_window_to_space(CGWindowID wid, uint64_t sid);

// Convenience: move a window onto the space the user is currently looking at.
// This is the no-SIP, no-animation alternative to switching the user *to* the
// window — bring the window to the user instead.
bool platform_move_window_to_active_space(CGWindowID wid);

// Switch the active (visible) space to `sid` on the focused display, without
// SIP. macOS exposes no API for space activation, so this synthesizes a
// high-velocity dock-swipe gesture (yabai's #2781 technique); the velocity is
// high enough to skip the transition animation. It steps through spaces by
// Mission Control order, so it traverses |target - current| adjacent spaces.
// Requires Accessibility (event-posting) permission. Returns false if `sid`
// is not a space on the focused display.
bool platform_focus_space(uint64_t sid);

// Enable instant, no-SIP space following on app activation (Cmd+Tab / Dock).
// When an app is activated whose front window lives on a non-visible space,
// jump to that space instantly via platform_focus_space (skipping macOS's
// auto-swoosh animation). Also registers the window-server Cmd+Tab signal and
// emits WM_EVENT_ALT_TAB through `cb` when it fires. For the snappiest result,
// disable System Settings → Desktop & Dock → "When switching to an application,
// switch to a Space with open windows for the application".
void platform_enable_alt_tab_space_switch(WMEventCallback cb, void *userdata);

#endif // PLATFORM_H
