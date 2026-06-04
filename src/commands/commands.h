#ifndef COMMANDS_COMMANDS_H
#define COMMANDS_COMMANDS_H

#include "../tree/node.h"

// Tiling commands. Each operates on the currently focused window's node in its
// Space tree, then normalizes + re-tiles the affected Space.

typedef enum {
    DIR_LEFT,
    DIR_DOWN,
    DIR_UP,
    DIR_RIGHT,
} Direction;

// Move keyboard focus to the nearest tile in `dir` and raise it.
void cmd_focus(Direction dir);

// Move the focused window one position in `dir` within the tree.
void cmd_move(Direction dir);

// Wrap the focused window in a new container with the given orientation
// (LAYOUT_H_TILES or LAYOUT_V_TILES). i3's `split`.
void cmd_split(Layout orientation);

// Set the focused window's parent container layout.
void cmd_layout(Layout layout);

// Grow/shrink the focused tile along `dir` by `px` pixels (approx, via weights).
void cmd_resize(Direction dir, int px);

#endif // COMMANDS_COMMANDS_H
