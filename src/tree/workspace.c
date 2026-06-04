#include "workspace.h"

#include <stddef.h>

// Spaces are few (a handful per machine), so a flat array keyed by space id is
// simpler and faster than a hash table.
#define MAX_WORKSPACES 64

typedef struct {
    uint64_t sid;
    Node    *root;
} Workspace;

static Workspace g_workspaces[MAX_WORKSPACES];
static int       g_workspace_count;

Node *workspace_existing_root(uint64_t sid) {
    if (sid == 0) return NULL;
    for (int i = 0; i < g_workspace_count; i++) {
        if (g_workspaces[i].sid == sid) return g_workspaces[i].root;
    }
    return NULL;
}

Node *workspace_root_for_space(uint64_t sid) {
    Node *root = workspace_existing_root(sid);
    if (root) return root;
    if (sid == 0 || g_workspace_count >= MAX_WORKSPACES) return NULL;

    root = node_new_container(LAYOUT_H_TILES);
    g_workspaces[g_workspace_count].sid  = sid;
    g_workspaces[g_workspace_count].root = root;
    g_workspace_count++;
    return root;
}

uint64_t workspace_find_window(CGWindowID wid, Node **out_node) {
    for (int i = 0; i < g_workspace_count; i++) {
        Node *hit = node_find_window(g_workspaces[i].root, wid);
        if (hit) {
            if (out_node) *out_node = hit;
            return g_workspaces[i].sid;
        }
    }
    if (out_node) *out_node = NULL;
    return 0;
}

void workspace_each(void (*fn)(uint64_t sid, Node *root, void *ud), void *ud) {
    if (!fn) return;
    for (int i = 0; i < g_workspace_count; i++) {
        fn(g_workspaces[i].sid, g_workspaces[i].root, ud);
    }
}
