#include "observers.h"
#include "../extern/ax_private.h"
#include "../extern/skylight.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// List of accessibility observable events the wm subscribes to.
enum {
    WM_NOTIF_WINDOW_APPEARED    = 0,
    WM_NOTIF_WINDOW_MOVED       = 1,
    WM_NOTIF_WINDOW_RESIZED     = 2,
    WM_NOTIF_WINDOW_DISAPPEARED = 3,
};

#define MAX_APP_OBSERVERS 256

typedef struct {
    pid_t           pid;
    AXObserverRef   observer;
    WMEventCallback cb;
    void           *userdata;
} AppObserver;

static AppObserver g_observers[MAX_APP_OBSERVERS];
static int         g_observer_count;

// Per-application notifications (registered on the app AXUIElement)
static CFStringRef const kAppNotifs[] = {
    kAXWindowCreatedNotification,
};

// Per-window notifications (registered on each window AXUIElement)
static CFStringRef const kWinNotifs[] = {
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXUIElementDestroyedNotification,
};
#define kWinNotifsCount (sizeof(kWinNotifs) / sizeof(*kWinNotifs))

static AppObserver *find_observer(pid_t pid) {
    for (int i = 0; i < g_observer_count; i++) {
        if (g_observers[i].pid == pid) return &g_observers[i];
    }
    return NULL;
}

// Returns true if wid is a top-level window (parent == 0 in the window server).
// Rejects sheets, drawers, and sub-windows (e.g. some Ghostty panes) which
// have a non-zero parent even though AX may report them as window elements.
static bool is_top_level_window(CGWindowID wid) {
    if (wid == 0) return false;

    SLSConnectionID cid = CGSMainConnectionID();
    CFNumberRef widRef  = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    const void *v[1]    = { widRef };
    CFArrayRef  arr     = CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);

    uint32_t parent = 0;
    CFTypeRef query = SLSWindowQueryWindows(cid, arr, 1);
    if (query) {
        CFTypeRef it = SLSWindowQueryResultCopyWindows(query);
        if (it) {
            if (SLSWindowIteratorAdvance(it)) parent = SLSWindowIteratorGetParentID(it);
            CFRelease(it);
        }
        CFRelease(query);
    }
    CFRelease(arr);
    CFRelease(widRef);

    return parent == 0;
}

// Subscribe a window element to per-window notifications.
// Returns true  → newly subscribed (window is new).
// Returns false → kAXErrorNotificationAlreadyRegistered on the first
//                 notification, meaning we subscribed to this element during
//                 initial enumeration; the caller should NOT fire window_appeared.
static bool subscribe_window(AXObserverRef obs, AXUIElementRef win, void *ctx) {
    AXError first = AXObserverAddNotification(obs, win, kWinNotifs[0], ctx);
    if (first == kAXErrorNotificationAlreadyRegistered) return false;
    for (size_t i = 1; i < kWinNotifsCount; i++) {
        AXObserverAddNotification(obs, win, kWinNotifs[i], ctx);
    }
    return true;
}

static void ax_callback(AXObserverRef obs, AXUIElementRef element,
                         CFStringRef notif, void *userdata) {
    AppObserver *ao = userdata;

    pid_t pid = 0;
    AXUIElementGetPid(element, &pid);

    CGWindowID wid = 0;
    _AXUIElementGetWindow(element, &wid);

    if (CFEqual(notif, kAXWindowCreatedNotification)) {
        // Reject non-top-level elements (sheets, panes with a window-server parent).
        if (!is_top_level_window(wid)) return;

        // subscribe_window returns false when this element was already
        // subscribed during initial registration — the app is replaying
        // notifications for existing windows, not creating a new one.
        if (!subscribe_window(obs, element, ao)) return;

        if (ao->cb) ao->cb(WM_EVENT_WINDOW_APPEARED, pid, wid, ao->userdata);

    } else if (CFEqual(notif, kAXWindowMovedNotification)) {
        if (ao->cb) ao->cb(WM_EVENT_WINDOW_MOVED, pid, wid, ao->userdata);

    } else if (CFEqual(notif, kAXWindowResizedNotification)) {
        if (ao->cb) ao->cb(WM_EVENT_WINDOW_RESIZED, pid, wid, ao->userdata);

    } else if (CFEqual(notif, kAXUIElementDestroyedNotification)) {
        // wid is 0 once the element is gone from the window server; not actionable.
        if (wid == 0) return;
        if (ao->cb) ao->cb(WM_EVENT_WINDOW_DISAPPEARED, pid, wid, ao->userdata);
    }
}


bool observers_register_app(pid_t pid, WMEventCallback cb, void *userdata) {
    if (g_observer_count >= MAX_APP_OBSERVERS) return false;
    if (find_observer(pid)) return false; // already registered

    AXObserverRef obs = NULL;
    if (AXObserverCreate(pid, ax_callback, &obs) != kAXErrorSuccess) return false;

    AppObserver *ao = &g_observers[g_observer_count++];
    ao->pid      = pid;
    ao->observer = obs;
    ao->cb       = cb;
    ao->userdata = userdata;

    AXUIElementRef app = AXUIElementCreateApplication(pid);

    for (size_t i = 0; i < sizeof(kAppNotifs) / sizeof(*kAppNotifs); i++) {
        AXObserverAddNotification(obs, app, kAppNotifs[i], ao);
    }

    // Subscribe to windows that are already open — subscribe_window marks
    // these so kAXWindowCreatedNotification replays are ignored.
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            subscribe_window(obs, win, ao);
        }
        CFRelease(wins);
    }

    CFRelease(app);
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), kCFRunLoopDefaultMode);
    return true;
}

void observers_unregister_app(pid_t pid) {
    for (int i = 0; i < g_observer_count; i++) {
        if (g_observers[i].pid != pid) continue;

        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(g_observers[i].observer),
                              kCFRunLoopDefaultMode);
        CFRelease(g_observers[i].observer);

        g_observers[i] = g_observers[--g_observer_count];
        return;
    }
}

