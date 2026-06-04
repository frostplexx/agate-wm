#ifndef WINDOW_AX_WINDOW_H
#define WINDOW_AX_WINDOW_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <sys/types.h>

// Accessibility-based control of other applications' windows. agate manages
// windows it does not own, so frames are applied via AXUIElement
// position/size (per skylight-snapping-report.md's decision guide), not the
// NSWindow SPI or SkyLight tile spaces.

// True if `wid` is a top-level window in the window server (parent == 0).
// Rejects sheets, drawers, and sub-windows. Shared by the observer path and
// the tiling manager.
bool ax_window_is_top_level(CGWindowID wid);

// True if the window can participate in tiling. A window tiles when it is
// top-level, movable + resizable, and is not classified as a dialog. Dialog
// classification (mirroring AeroSpace's isDialogHeuristic): a non-standard AX
// subrole, OR a standard window with no fullscreen button — except for terminal
// apps, which are exempt from the fullscreen-button heuristic. Per-app rules set
// via ax_window_add_rule override the heuristic.
bool ax_window_is_tileable(pid_t pid, CGWindowID wid);

// Per-app tiling override (from the Lua `on_window_detected` config).
typedef enum {
    WINDOW_RULE_NONE,
    WINDOW_RULE_TILE,   // force tile, bypassing the dialog heuristic
    WINDOW_RULE_FLOAT,  // force float (never tile)
} WindowRule;

// Force all windows of the app with bundle id `app_id` to tile or float.
void ax_window_add_rule(const char *app_id, WindowRule action);

// Move + resize the window to `frame` (top-left AX coordinates). Best-effort;
// silently no-ops if the AX element can't be resolved.
void ax_window_set_frame(pid_t pid, CGWindowID wid, CGRect frame);

// Read the window's current frame (top-left AX coordinates) into *out. Returns
// false if it can't be resolved.
bool ax_window_frame(pid_t pid, CGWindowID wid, CGRect *out);

// Raise the window and activate its owning app so it becomes the focused
// window. Used by the focus command.
void ax_window_raise_focus(pid_t pid, CGWindowID wid);

// Currently focused window: the frontmost app's AX focused (else main) window.
// Returns false if it can't be resolved.
bool ax_window_focused(pid_t *out_pid, CGWindowID *out_wid);

// Whether `wid` is currently ordered in (mapped/rendered) by the window server.
// False for background tabs of a native tab group and for minimized windows.
// NOTE: the ordered-out transition is delivered lazily by the window server
// (it can lag seconds behind a tab switch), so this is only reliable for windows
// that have been settled for a while — used at startup adoption, not for live
// tab detection. Live tab handling reconciles against CGWindowList's on-screen
// set instead (see enumerate_onscreen_tileable), where background tabs are
// simply absent.
bool ax_window_is_ordered_in(CGWindowID wid);

// Whether the window is currently part of a native tab group (AXTabbedWindows
// lists more than one tab). Recorded while a window is alive so that, once it
// closes, we know whether to expect a sibling tab to surface.
bool ax_window_is_tabbed(pid_t pid, CGWindowID wid);

// Drop any cached AXUIElementRef for `wid` (call when a window disappears).
void ax_window_forget(CGWindowID wid);

#endif // WINDOW_AX_WINDOW_H
