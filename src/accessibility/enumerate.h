#ifndef ENUMERATE_H
#define ENUMERATE_H

#include <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>

typedef struct {
    CGWindowID wid;
    pid_t      pid;
} AgateWindow;

// Print every managed window across all spaces (debug/inspection).
void enumerate_windows(void);

// Insert every already-open, tileable top-level window into its Space's tiling
// tree (startup adoption), then re-tile the active Space.
void enumerate_adopt_windows(void);

// Fill `out` with up to `max` on-screen, tileable windows of the CURRENT space,
// and return the count. This is the CGWindowList-first ground truth: the window
// server reports only the rendered (selected) tab of a native tab group, so
// background tabs are absent and a tab group yields exactly one entry. Used to
// reconcile the active Space's tree against what's actually on screen.
int enumerate_onscreen_tileable(AgateWindow *out, int max);

#endif // ENUMERATE_H
