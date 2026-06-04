#include "commands.h"

#include "../tree/manager.h"
#include "../tree/workspace.h"
#include "../window/ax_window.h"

#include <stdint.h>

static bool dir_horizontal(Direction d) { return d == DIR_LEFT || d == DIR_RIGHT; }
static bool dir_forward(Direction d)    { return d == DIR_RIGHT || d == DIR_DOWN; }

// Focused window's leaf node in its Space tree, plus that Space id. NULL if the
// focused window isn't tracked (e.g. a floating window).
static Node *focused_leaf(uint64_t *out_sid) {
    pid_t pid = 0;
    CGWindowID wid = 0;
    if (!ax_window_focused(&pid, &wid)) return NULL;
    Node *leaf = NULL;
    uint64_t sid = workspace_find_window(wid, &leaf);
    if (out_sid) *out_sid = sid;
    return leaf;
}

// Walk up from `node` to the first ancestor whose orientation matches `dir`'s
// axis and that has a sibling on `dir`'s side; return that sibling subtree.
static Node *neighbor(Node *node, Direction dir) {
    bool horiz = dir_horizontal(dir);
    bool fwd   = dir_forward(dir);
    for (Node *cur = node; cur && cur->parent; cur = cur->parent) {
        Node *p = cur->parent;
        if (layout_is_horizontal(p->layout) != horiz) continue;
        long idx  = node_index_in_parent(cur);
        long nidx = fwd ? idx + 1 : idx - 1;
        if (nidx >= 0 && nidx < (long)p->child_count) return p->children[nidx];
    }
    return NULL;
}

void cmd_focus(Direction dir) {
    Node *leaf = focused_leaf(NULL);
    if (!leaf) return;
    Node *nb = neighbor(leaf, dir);
    Node *target = nb ? node_first_leaf(nb) : NULL;
    if (target && target->type == NODE_WINDOW) {
        ax_window_raise_focus(target->pid, target->wid);
    }
}

void cmd_move(Direction dir) {
    uint64_t sid = 0;
    Node *leaf = focused_leaf(&sid);
    if (!leaf || !leaf->parent) return;

    bool horiz = dir_horizontal(dir);
    bool fwd   = dir_forward(dir);
    Node *p    = leaf->parent;

    // Common case: reorder within a same-axis parent by swapping with the
    // adjacent sibling.
    if (layout_is_horizontal(p->layout) == horiz) {
        long idx  = node_index_in_parent(leaf);
        long nidx = fwd ? idx + 1 : idx - 1;
        if (nidx >= 0 && nidx < (long)p->child_count) {
            Node *sib = p->children[nidx];
            p->children[nidx] = leaf;
            p->children[idx]  = sib;
            manager_retile_space(sid);
            return;
        }
    }

    // Otherwise re-parent next to a same-axis ancestor's neighbor.
    Node *nb = neighbor(leaf, dir);
    if (!nb) return;
    node_detach(leaf);
    if (nb->type == NODE_CONTAINER) {
        // Enter the neighbor container at the near edge.
        if (fwd) node_insert_before(node_first_leaf(nb), leaf);
        else     node_append_child(nb, leaf);
    } else if (fwd) {
        node_insert_before(nb, leaf);
    } else {
        node_insert_after(nb, leaf);
    }
    manager_retile_space(sid);
}

void cmd_split(Layout orientation) {
    uint64_t sid = 0;
    Node *leaf = focused_leaf(&sid);
    if (!leaf || !leaf->parent) return;

    // Wrap the focused leaf in a fresh container of the requested orientation.
    Node *wrap = node_new_container(orientation);
    wrap->weight = leaf->weight;
    leaf->weight = 1.0;
    node_insert_before(leaf, wrap);
    node_detach(leaf);
    node_append_child(wrap, leaf);
    manager_retile_space(sid);
}

void cmd_layout(Layout layout) {
    uint64_t sid = 0;
    Node *leaf = focused_leaf(&sid);
    if (!leaf || !leaf->parent) return;
    leaf->parent->layout = layout;
    manager_retile_space(sid);
}

void cmd_resize(Direction dir, int px) {
    uint64_t sid = 0;
    Node *leaf = focused_leaf(&sid);
    if (!leaf || !leaf->parent) return;

    bool horiz = dir_horizontal(dir);
    Node *p    = leaf->parent;
    if (layout_is_horizontal(p->layout) != horiz) return; // can't grow along this axis here
    if (p->child_count < 2) return;

    // Translate a pixel delta into a weight delta against the average sibling
    // weight, nudging the focused node and shrinking the rest proportionally.
    double step = (double)px / 100.0;
    bool grow = dir_forward(dir);
    double delta = grow ? step : -step;

    double new_weight = leaf->weight + delta;
    if (new_weight < 0.1) new_weight = 0.1;
    leaf->weight = new_weight;
    manager_retile_space(sid);
}
