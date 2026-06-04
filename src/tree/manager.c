#include "manager.h"

#include "node.h"
#include "workspace.h"
#include "../accessibility/enumerate.h"
#include "../layout/layout.h"
#include "../platform/platform.h"
#include "../window/ax_window.h"
#include "../utils/log.h"

#include <CoreFoundation/CoreFoundation.h>

ManagerNormalization g_manager_normalization = { .flatten = true, .opposite = true };

// Applying a layout moves/resizes windows via AX, which echoes back as
// WINDOW_MOVED / WINDOW_RESIZED events. We ignore those events for a short
// window after every layout pass so re-tile-on-move doesn't feed back on itself.
#define MANAGER_ECHO_SUPPRESS_SECS 0.25
static CFAbsoluteTime g_suppress_until;

// A leaf must be absent from the on-screen set for this long before it's removed,
// so a transient tab close/reselect re-pairs before the other windows reflow.
#define MANAGER_REMOVE_GRACE_SECS 0.30

// Interactive-drag state, scoped between a left-mouse down and up. While the
// button is held, a tiled window's AX move/resize events are NOT snapped back
// (the user drags freely); on release we either snap a moved window back to its
// slot or, for a resize, recompute split weights so the neighbor adjusts.
static bool       g_mouse_down;
static CGWindowID g_drag_wid;
static bool       g_drag_resized;

static bool events_suppressed(void) {
    return CFAbsoluteTimeGetCurrent() < g_suppress_until;
}

void manager_retile_space(uint64_t sid) {
    Node *root = workspace_existing_root(sid);
    if (!root) {
        LOG("tile", "retile sid=%llu: no tree", (unsigned long long)sid);
        return;
    }
    node_normalize(root, g_manager_normalization.flatten, g_manager_normalization.opposite);
    // Suppress the move/resize echoes this layout pass is about to generate.
    g_suppress_until = CFAbsoluteTimeGetCurrent() + MANAGER_ECHO_SUPPRESS_SECS;
    CGRect r = layout_usable_rect(sid);
    LOG("tile", "retile sid=%llu: %zu window(s), rect=(%.0f,%.0f %.0fx%.0f)",
        (unsigned long long)sid, node_leaf_count(root), r.origin.x, r.origin.y, r.size.width, r.size.height);
    layout_apply(root, r);
}

#define MAX_RECONCILE 256

static bool set_contains(const AgateWindow *set, int n, CGWindowID wid) {
    for (int i = 0; i < n; i++) {
        if (set[i].wid == wid) return true;
    }
    return false;
}

// Collect every window leaf in the subtree into `out` (in tree order).
static void collect_leaves(Node *node, Node **out, int *count, int max) {
    if (node->type == NODE_WINDOW) {
        if (*count < max) out[(*count)++] = node;
        return;
    }
    for (size_t i = 0; i < node->child_count; i++) {
        collect_leaves(node->children[i], out, count, max);
    }
}

// Sync the active Space's tree to the windows actually on screen (CGWindowList
// ground truth). Background tabs are not on screen, so a tab group reduces to one
// tile regardless of how/when macOS orders the old tab out — no reliance on the
// laggy ordered-in bit.
//
// Stability: a removal (a leaf no longer on screen) and an addition (an on-screen
// window not yet tracked) that share a pid are treated as the *same slot* — the
// new window is written into the old leaf in place, preserving its tree position.
// This is what keeps a freshly created native tab from jumping to the end and
// swapping with its neighbor: the old tab and the new tab have the same pid, so
// the new tab inherits the old tab's exact position. (AXTabbedWindows can't help
// here — once a tab is backgrounded, _AXUIElementGetWindow reports 0 for it.)
static void reconcile_active_space(void) {
    uint64_t sid = platform_active_space();
    Node *root = workspace_root_for_space(sid);
    if (!root) return;

    AgateWindow set[MAX_RECONCILE];
    int n = enumerate_onscreen_tileable(set, MAX_RECONCILE);

    Node *leaves[MAX_RECONCILE];
    int leaf_n = 0;
    collect_leaves(root, leaves, &leaf_n, MAX_RECONCILE);

    // Removal candidates: leaves no longer on screen. Present leaves get their
    // absent timer cleared.
    Node *removals[MAX_RECONCILE];
    int rn = 0;
    for (int i = 0; i < leaf_n; i++) {
        if (set_contains(set, n, leaves[i]->wid)) leaves[i]->absent_since = 0;
        else removals[rn++] = leaves[i];
    }

    bool changed = false;

    // Additions: on-screen windows not yet tracked. Pair each with a same-pid
    // removal candidate (reuse its slot in place, preserving position) before
    // falling back to a fresh insert.
    for (int i = 0; i < n; i++) {
        if (node_find_window(root, set[i].wid)) continue; // already tracked

        Node *slot = NULL;
        for (int r = 0; r < rn; r++) {
            if (removals[r] && removals[r]->pid == set[i].pid) {
                slot = removals[r];
                removals[r] = NULL; // consume it
                break;
            }
        }

        if (slot) {
            LOG("tile", "reconcile replace wid=%u -> wid=%u (same pid, keep slot)",
                slot->wid, set[i].wid);
            ax_window_forget(slot->wid);
            slot->wid = set[i].wid;
            slot->pid = set[i].pid;
            slot->absent_since = 0;
        } else {
            Node *leaf = node_new_window(set[i].wid, set[i].pid);
            pid_t fpid = 0;
            CGWindowID fwid = 0;
            Node *anchor = NULL;
            if (ax_window_focused(&fpid, &fwid) && fwid != set[i].wid) {
                anchor = node_find_window(root, fwid);
            }
            if (anchor) node_insert_after(anchor, leaf);
            else        node_append_child(root, leaf);
            LOG("tile", "reconcile add wid=%u pid=%d (%s)", set[i].wid, set[i].pid,
                anchor ? "after-focused" : "append-to-root");
        }
        changed = true;
    }

    // Remaining unpaired removals: only drop one once it has been absent past the
    // grace period. A window briefly missing during a tab close/reselect re-pairs
    // above before the grace expires, so the other window never fullscreens.
    double now = CFAbsoluteTimeGetCurrent();
    for (int r = 0; r < rn; r++) {
        if (!removals[r]) continue;
        if (removals[r]->absent_since == 0) {
            removals[r]->absent_since = now; // start the grace timer; keep for now
            LOG("tile", "reconcile wid=%u absent, holding for grace", removals[r]->wid);
            continue;
        }
        if (now - removals[r]->absent_since < MANAGER_REMOVE_GRACE_SECS) continue;
        LOG("tile", "reconcile remove wid=%u (absent past grace)", removals[r]->wid);
        ax_window_forget(removals[r]->wid);
        node_remove(removals[r]);
        changed = true;
    }

    LOG("tile", "reconcile sid=%llu: %d on-screen, tree now %zu, changed=%d",
        (unsigned long long)sid, n, node_leaf_count(root), changed);

    if (changed) manager_retile_space(sid);
}

// The on-screen window set can lag a beat behind a tab switch / window close.
// Reconcile is idempotent and only re-tiles on real changes, so we also run it
// a couple of times shortly after an event to converge without guessing the
// exact settle time.
static void deferred_reconcile_cb(CFRunLoopTimerRef timer, void *info) {
    (void)info;
    reconcile_active_space();
    CFRunLoopTimerInvalidate(timer);
}

static void schedule_reconcile(double delay) {
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0,
                                               deferred_reconcile_cb, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRelease(t);
}

// Remove every window leaf owned by `pid` from the subtree; returns true if any
// were removed.
static bool remove_pid_leaves(Node *node, pid_t pid) {
    bool removed = false;
    for (size_t i = 0; i < node->child_count; /* advance conditionally */) {
        Node *c = node->children[i];
        if (c->type == NODE_WINDOW) {
            if (c->pid == pid) {
                ax_window_forget(c->wid);
                node_remove(c); // shifts the array left, so don't advance i
                removed = true;
            } else {
                i++;
            }
        } else {
            removed |= remove_pid_leaves(c, pid);
            i++;
        }
    }
    return removed;
}

static void prune_app_in_space(uint64_t sid, Node *root, void *ud) {
    pid_t pid = (pid_t)(intptr_t)ud;
    if (remove_pid_leaves(root, pid)) manager_retile_space(sid);
}

// Insert window (pid, wid) into the tree for `sid`, as a sibling of the
// currently focused window when that window lives in this same tree; otherwise
// append it to the root. Re-tiles `sid`.
static void insert_window(uint64_t sid, pid_t pid, CGWindowID wid) {
    Node *root = workspace_root_for_space(sid);
    if (!root) {
        LOG("tile", "insert wid=%u: no root for sid=%llu", wid, (unsigned long long)sid);
        return;
    }

    // Already tracked? Nothing to do.
    if (node_find_window(root, wid)) {
        LOG("tile", "insert wid=%u: already tracked, skipping", wid);
        return;
    }

    Node *leaf = node_new_window(wid, pid);

    pid_t fpid = 0;
    CGWindowID fwid = 0;
    Node *anchor = NULL;
    if (ax_window_focused(&fpid, &fwid) && fwid != wid) {
        anchor = node_find_window(root, fwid);
    }

    if (anchor) {
        node_insert_after(anchor, leaf);
    } else {
        node_append_child(root, leaf);
    }

    LOG("tile", "insert wid=%u pid=%d sid=%llu (%s focused wid=%u) -> %zu window(s)",
        wid, pid, (unsigned long long)sid, anchor ? "after" : "append-to-root", fwid,
        node_leaf_count(root));

    manager_retile_space(sid);
}

void manager_adopt_window(uint64_t sid, pid_t pid, CGWindowID wid) {
    if (sid == 0 || wid == 0) return;
    if (!ax_window_is_tileable(pid, wid)) return;
    insert_window(sid, pid, wid);
}

// After a user resizes a tiled window by dragging an edge, pin that window to its
// new size and make its siblings absorb the difference so it stays exactly where
// the user left it and everything stays tiled. Weights are set in pixel units so
// that, with layout's own normalization, the dragged child gets precisely its new
// length and the siblings split the remaining space in their previous proportions.
static void finalize_resize(uint64_t sid, Node *leaf) {
    Node *p = leaf->parent;
    if (!p || p->type != NODE_CONTAINER || p->child_count < 2) {
        manager_retile_space(sid); // nothing to redistribute; just re-tile
        return;
    }
    bool horiz = layout_is_horizontal(p->layout);

    CGRect cur;
    if (!ax_window_frame(leaf->pid, leaf->wid, &cur)) {
        manager_retile_space(sid);
        return;
    }

    // Space the parent splits among its children (its axis minus the inner gaps).
    double avail = (horiz ? p->frame.size.width : p->frame.size.height)
                 - (double)g_layout_gaps.inner * (double)(p->child_count - 1);
    if (avail < 20) { manager_retile_space(sid); return; }

    // Requested size for the dragged child, leaving each sibling a minimum.
    const double kMin = 40.0;
    double s_new = horiz ? cur.size.width : cur.size.height;
    double max_for_leaf = avail - kMin * (double)(p->child_count - 1);
    if (s_new > max_for_leaf) s_new = max_for_leaf;
    if (s_new < kMin) s_new = kMin;

    // Previous total length of the siblings, to keep their relative proportions.
    double others_old = 0;
    for (size_t i = 0; i < p->child_count; i++) {
        if (p->children[i] == leaf) continue;
        others_old += horiz ? p->children[i]->frame.size.width : p->children[i]->frame.size.height;
    }
    if (others_old < 1) others_old = 1;

    // Total weight ends up == avail, so the dragged child gets exactly s_new and
    // the siblings share (avail - s_new) in proportion to their old sizes.
    double others_new = avail - s_new;
    for (size_t i = 0; i < p->child_count; i++) {
        Node *c = p->children[i];
        if (c == leaf) {
            c->weight = s_new;
        } else {
            double old_len = horiz ? c->frame.size.width : c->frame.size.height;
            double w = others_new * (old_len / others_old);
            c->weight = w < 1 ? 1 : w;
        }
    }
    LOG("tile", "resize wid=%u -> %.0fpx, siblings absorb the rest", leaf->wid, s_new);
    manager_retile_space(sid);
}

// On mouse release, finalize whatever the held window was doing: snap a move back
// to its slot, or apply a resize to the split weights.
static void finalize_drag(void) {
    if (g_drag_wid == 0) return;

    Node *leaf = NULL;
    uint64_t sid = workspace_find_window(g_drag_wid, &leaf);
    if (leaf) {
        if (g_drag_resized) finalize_resize(sid, leaf);
        else                manager_retile_space(sid); // snap moved window back
    }
    g_drag_wid = 0;
    g_drag_resized = false;
}

void manager_handle_event(WMEventType event, pid_t pid, CGWindowID wid, void *userdata) {
    (void)userdata;

    static const char *names[] = {
        [WM_EVENT_WINDOW_MOVED]       = "moved",
        [WM_EVENT_WINDOW_APPEARED]    = "appeared",
        [WM_EVENT_WINDOW_RESIZED]     = "resized",
        [WM_EVENT_WINDOW_DISAPPEARED] = "disappeared",
        [WM_EVENT_SPACE_CHANGED]      = "space_changed",
        [WM_EVENT_ALT_TAB]            = "alt_tab",
        [WM_EVENT_APP_TERMINATED]     = "app_terminated",
        [WM_EVENT_MOUSE_DOWN]         = "mouse_down",
        [WM_EVENT_MOUSE_UP]           = "mouse_up",
    };
    LOG("event", "%s pid=%d wid=%u", names[event], pid, wid);

    switch (event) {
        // Window appeared/vanished (including a tab created/closed, which the AX
        // API surfaces as a window create/destroy): reconcile the active Space
        // against what's actually on screen. The deferred passes catch the
        // window server settling a beat later (e.g. the old tab going off-screen).
        case WM_EVENT_WINDOW_APPEARED:
        case WM_EVENT_WINDOW_DISAPPEARED: {
            reconcile_active_space();
            schedule_reconcile(0.15);
            schedule_reconcile(0.40);
            break;
        }
        case WM_EVENT_SPACE_CHANGED: {
            reconcile_active_space();
            break;
        }
        case WM_EVENT_APP_TERMINATED: {
            // Some apps quit without per-window destroyed notifications; drop
            // all of the app's leaves and re-tile the spaces they were on.
            workspace_each(prune_app_in_space, (void *)(intptr_t)pid);
            break;
        }
        // A tiled window moved/resized. Ignore our own layout echoes. While the
        // mouse button is held, just record the drag (let the user move/resize
        // freely); we act on release. Stray non-drag moves are left alone.
        case WM_EVENT_WINDOW_MOVED:
        case WM_EVENT_WINDOW_RESIZED: {
            if (events_suppressed()) return;
            if (!g_mouse_down) return; // not an interactive drag
            Node *leaf = NULL;
            if (!workspace_find_window(wid, &leaf) || !leaf) return; // floating/untracked
            g_drag_wid = wid;
            if (event == WM_EVENT_WINDOW_RESIZED) g_drag_resized = true;
            break;
        }
        case WM_EVENT_MOUSE_DOWN: {
            g_mouse_down = true;
            g_drag_wid = 0;
            g_drag_resized = false;
            break;
        }
        case WM_EVENT_MOUSE_UP: {
            g_mouse_down = false;
            finalize_drag();
            break;
        }
        case WM_EVENT_ALT_TAB:
            break;
    }
}
