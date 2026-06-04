#ifndef LAYOUT_LAYOUT_H
#define LAYOUT_LAYOUT_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#include "../tree/node.h"

// Gap configuration, mutated from the Lua config. `inner` is the space between
// tiles; `outer` is the inset from the usable screen edge.
typedef struct {
    int inner;
    int outer;
} LayoutGaps;

extern LayoutGaps g_layout_gaps;

// Tileable rect for the display owning `sid`, in top-left AX coordinates
// (menu bar excluded, outer gap applied). Returns CGRectNull if the display
// can't be resolved.
CGRect layout_usable_rect(uint64_t sid);

// Recursively position every window leaf in `root` within `rect`, splitting
// along each container's orientation and applying inner gaps. Calls
// ax_window_set_frame for each leaf.
void layout_apply(Node *root, CGRect rect);

#endif // LAYOUT_LAYOUT_H
