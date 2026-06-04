#include "node.h"

#include <stdlib.h>

Node *node_new_container(Layout layout) {
    Node *n = calloc(1, sizeof(Node));
    n->type   = NODE_CONTAINER;
    n->layout = layout;
    n->weight = 1.0;
    return n;
}

Node *node_new_window(CGWindowID wid, pid_t pid) {
    Node *n = calloc(1, sizeof(Node));
    n->type   = NODE_WINDOW;
    n->weight = 1.0;
    n->wid    = wid;
    n->pid    = pid;
    return n;
}

void node_free(Node *node) {
    if (!node) return;
    for (size_t i = 0; i < node->child_count; i++) node_free(node->children[i]);
    free(node->children);
    free(node);
}

void node_append_child(Node *parent, Node *child) {
    if (!parent || !child) return;
    if (parent->child_count == parent->child_cap) {
        size_t cap = parent->child_cap ? parent->child_cap * 2 : 4;
        parent->children = realloc(parent->children, cap * sizeof(Node *));
        parent->child_cap = cap;
    }
    parent->children[parent->child_count++] = child;
    child->parent = parent;
}

void node_insert_after(Node *ref, Node *node) {
    Node *parent = ref ? ref->parent : NULL;
    if (!parent || !node) return;

    long idx = node_index_in_parent(ref);
    if (idx < 0) return;

    // Grow then shift the tail right by one to open a slot at idx+1.
    node_append_child(parent, node); // ensures capacity + sets parent
    for (size_t i = parent->child_count - 1; i > (size_t)idx + 1; i--) {
        parent->children[i] = parent->children[i - 1];
    }
    parent->children[idx + 1] = node;
}

void node_insert_before(Node *ref, Node *node) {
    Node *parent = ref ? ref->parent : NULL;
    if (!parent || !node) return;

    long idx = node_index_in_parent(ref);
    if (idx < 0) return;

    node_append_child(parent, node); // ensures capacity + sets parent
    for (size_t i = parent->child_count - 1; i > (size_t)idx; i--) {
        parent->children[i] = parent->children[i - 1];
    }
    parent->children[idx] = node;
}

void node_detach(Node *node) {
    Node *parent = node ? node->parent : NULL;
    if (!parent) return;

    long idx = node_index_in_parent(node);
    if (idx < 0) return;
    for (size_t i = (size_t)idx; i + 1 < parent->child_count; i++) {
        parent->children[i] = parent->children[i + 1];
    }
    parent->child_count--;
    node->parent = NULL;
}

Node *node_remove(Node *node) {
    if (!node) return NULL;
    Node *parent = node->parent;
    node_detach(node);
    node_free(node);
    return parent;
}

long node_index_in_parent(Node *node) {
    Node *parent = node ? node->parent : NULL;
    if (!parent) return -1;
    for (size_t i = 0; i < parent->child_count; i++) {
        if (parent->children[i] == node) return (long)i;
    }
    return -1;
}

Node *node_find_window(Node *node, CGWindowID wid) {
    if (!node) return NULL;
    if (node->type == NODE_WINDOW) return node->wid == wid ? node : NULL;
    for (size_t i = 0; i < node->child_count; i++) {
        Node *hit = node_find_window(node->children[i], wid);
        if (hit) return hit;
    }
    return NULL;
}

Node *node_first_leaf(Node *node) {
    if (!node) return NULL;
    if (node->type == NODE_WINDOW) return node;
    for (size_t i = 0; i < node->child_count; i++) {
        Node *leaf = node_first_leaf(node->children[i]);
        if (leaf) return leaf;
    }
    return NULL;
}

size_t node_leaf_count(Node *node) {
    if (!node) return 0;
    if (node->type == NODE_WINDOW) return 1;
    size_t n = 0;
    for (size_t i = 0; i < node->child_count; i++) n += node_leaf_count(node->children[i]);
    return n;
}

// --- Normalization ---------------------------------------------------------

// Replace `child` (a single-child container) in its parent with `child`'s only
// grandchild, preserving the grandchild's relative position and weight.
static void flatten_into_parent(Node *child) {
    Node *parent = child->parent;
    Node *grand  = child->children[0];

    long idx = node_index_in_parent(child);
    grand->parent = parent;
    grand->weight = child->weight; // grandchild inherits the slot's share
    parent->children[idx] = grand;

    child->children[0] = NULL;
    child->child_count = 0;
    node_free(child);
}

void node_normalize(Node *root, bool flatten, bool opposite) {
    if (!root || root->type != NODE_CONTAINER) return;

    // Normalize children first (post-order), then this level.
    for (size_t i = 0; i < root->child_count; i++) {
        node_normalize(root->children[i], flatten, opposite);
    }

    if (flatten) {
        // A non-root container reduced to a single container/window child is
        // collapsed. Repeat until no immediate child qualifies.
        bool changed = true;
        while (changed) {
            changed = false;
            for (size_t i = 0; i < root->child_count; i++) {
                Node *c = root->children[i];
                if (c->type == NODE_CONTAINER && c->child_count == 1) {
                    flatten_into_parent(c);
                    changed = true;
                    break;
                }
            }
        }
    }

    if (opposite) {
        // A container nested directly inside `root` must use the opposite
        // orientation.
        for (size_t i = 0; i < root->child_count; i++) {
            Node *c = root->children[i];
            if (c->type == NODE_CONTAINER && c->child_count > 1 &&
                layout_is_horizontal(c->layout) == layout_is_horizontal(root->layout)) {
                c->layout = layout_is_horizontal(root->layout) ? LAYOUT_V_TILES : LAYOUT_H_TILES;
            }
        }
    }
}
