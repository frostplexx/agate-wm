#ifndef TREE_MANAGER_H
#define TREE_MANAGER_H

#include <stdbool.h>
#include <stdint.h>

#include "../accessibility/observers.h"

// The tiling manager owns the link between window/space events and the per-space
// trees. It inserts/removes window leaves and re-tiles affected spaces.

// Normalization toggles (mirror i3/AeroSpace). Set from the Lua config; both
// default to true.
typedef struct {
    bool flatten;  // collapse single-child containers
    bool opposite; // force nested containers to alternate orientation
} ManagerNormalization;

extern ManagerNormalization g_manager_normalization;

// WMEventCallback entry point: route observer/space events into the trees.
void manager_handle_event(WMEventType event, pid_t pid, CGWindowID wid, void *userdata);

// Re-run normalization + layout for `sid`'s tree (no-op if it has no tree).
void manager_retile_space(uint64_t sid);

// Insert an existing window into its space's tree (used during initial
// enumeration). `sid` is the space the window lives on.
void manager_adopt_window(uint64_t sid, pid_t pid, CGWindowID wid);

#endif // TREE_MANAGER_H
