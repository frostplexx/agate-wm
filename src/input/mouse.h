#ifndef INPUT_MOUSE_H
#define INPUT_MOUSE_H

#include "../accessibility/observers.h"

// Watch the left mouse button via a listen-only event tap and emit
// WM_EVENT_MOUSE_DOWN / WM_EVENT_MOUSE_UP through `cb`. The manager uses these
// to scope interactive window drags: record the dragged window between down and
// up, then snap-back (move) or recompute split weights (resize) on release.
// Degrades gracefully (warns) if the tap can't be created.
void mouse_watch(WMEventCallback cb, void *userdata);

#endif // INPUT_MOUSE_H
