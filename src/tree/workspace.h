#ifndef TREE_WORKSPACE_H
#define TREE_WORKSPACE_H

#include <stdint.h>

#include "node.h"

// Per macOS Space tiling trees. Each Space (keyed by its managed space id) owns
// one root container; the root is the single container allowed to hold just one
// window child (per the normalization rules).

// Root container for `sid`, created lazily (default LAYOUT_H_TILES). Returns
// NULL only if `sid` is 0 or the table is full.
Node *workspace_root_for_space(uint64_t sid);

// Root for `sid` if one already exists, else NULL (no creation).
Node *workspace_existing_root(uint64_t sid);

// Find the (space id, leaf node) that owns window `wid` across every known
// Space. Returns the space id (writing the node to *out_node) or 0 if absent.
uint64_t workspace_find_window(CGWindowID wid, Node **out_node);

// Invoke `fn` for every known (space id, root) pair.
void workspace_each(void (*fn)(uint64_t sid, Node *root, void *ud), void *ud);

#endif // TREE_WORKSPACE_H
