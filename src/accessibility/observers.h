#ifndef OBSERVERS_H
#define OBSERVERS_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <sys/types.h>

typedef enum {
    WM_EVENT_WINDOW_MOVED,
    WM_EVENT_WINDOW_APPEARED,
    WM_EVENT_WINDOW_RESIZED,
    WM_EVENT_WINDOW_DISAPPEARED,
    WM_EVENT_SPACE_CHANGED,
    WM_EVENT_ALT_TAB,
    WM_EVENT_APP_TERMINATED, // an app quit; wid is 0, pid identifies the app
    WM_EVENT_MOUSE_DOWN,     // left mouse pressed; pid/wid are 0
    WM_EVENT_MOUSE_UP,       // left mouse released; pid/wid are 0
} WMEventType;

// pid and wid are 0 for WM_EVENT_SPACE_CHANGED, WM_EVENT_MOUSE_DOWN, and
// WM_EVENT_MOUSE_UP; wid is 0 for WM_EVENT_APP_TERMINATED
typedef void (*WMEventCallback)(WMEventType event, pid_t pid, CGWindowID wid, void *userdata);

// Register AX observers for all window events on a running application.
// Also subscribes to already-open windows belonging to that app.
bool observers_register_app(pid_t pid, WMEventCallback cb, void *userdata);

// Remove all AX observers previously registered for this pid.
void observers_unregister_app(pid_t pid);

#endif // OBSERVERS_H
