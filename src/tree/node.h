#ifndef TREE_NODE_H
#define TREE_NODE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// The tiling tree (AeroSpace/i3 model). Each non-leaf node is a container with
// a layout/orientation; the only leaves are windows. See the doc in
// skylight-snapping-report.md notes and the project plan for the full model.

typedef enum {
    NODE_CONTAINER,
    NODE_WINDOW,
} NodeType;

// Layout encodes both "tiles" and orientation. Accordion layouts are deferred.
typedef enum {
    LAYOUT_H_TILES, // children laid left-to-right (horizontal orientation)
    LAYOUT_V_TILES, // children laid top-to-bottom (vertical orientation)
} Layout;

typedef struct Node Node;
struct Node {
    NodeType type;
    Node    *parent;

    // Share of the parent's split axis this node occupies. Defaults to 1.0;
    // siblings are sized proportionally to their weights.
    double weight;

    // --- container ---
    Layout  layout;
    Node  **children;
    size_t  child_count;
    size_t  child_cap;

    // --- window leaf ---
    CGWindowID wid;
    pid_t      pid;

    // Reconciliation bookkeeping: when this window first went missing from the
    // on-screen set (CFAbsoluteTime), or 0 while present. A leaf is only removed
    // once it has been absent past a short grace period, so a transient tab
    // transition (close/reselect) doesn't briefly drop and re-add the window.
    double absent_since;

    // Rect this node was last laid out into (top-left AX coords). Set by the
    // layout engine; used to recompute split weights on interactive resize.
    CGRect frame;

    // Whether this window was part of a native tab group at the last reconcile.
    // Only tabbed windows need the removal grace period (a sibling tab surfaces a
    // beat after the visible tab closes); standalone windows are removed at once.
    bool tabbed;
};

// True when the layout's split axis is horizontal (left/right).
static inline bool layout_is_horizontal(Layout l) { return l == LAYOUT_H_TILES; }

// Construction. Containers start empty; windows are leaves.
Node *node_new_container(Layout layout);
Node *node_new_window(CGWindowID wid, pid_t pid);

// Recursively free a node and all of its descendants.
void node_free(Node *node);

// Append `child` as the last child of container `parent` (reparents it).
void node_append_child(Node *parent, Node *child);

// Insert `node` immediately after `ref` among ref's siblings (same parent).
void node_insert_after(Node *ref, Node *node);

// Insert `node` immediately before `ref` among ref's siblings (same parent).
void node_insert_before(Node *ref, Node *node);

// Detach `node` from its parent without freeing it. No-op for a root.
void node_detach(Node *node);

// Detach and free `node` (and its subtree). Returns the parent it was removed
// from, so the caller can normalize/re-tile (NULL if it had no parent).
Node *node_remove(Node *node);

// Index of `node` within its parent's children, or -1 if it has no parent.
long node_index_in_parent(Node *node);

// DFS for the window leaf with `wid` in the subtree rooted at `node`.
Node *node_find_window(Node *node, CGWindowID wid);

// First (left/top-most) window leaf in the subtree, or NULL if empty.
Node *node_first_leaf(Node *node);

// Number of window leaves in the subtree.
size_t node_leaf_count(Node *node);

// Normalize the whole tree rooted at `root` (root may keep a single child):
//   1. flatten containers with a single child (unless `flatten` is false)
//   2. force nested containers to alternate orientation (unless `opposite` is
//      false)
// Safe to call after any structural mutation.
void node_normalize(Node *root, bool flatten, bool opposite);

#endif // TREE_NODE_H
