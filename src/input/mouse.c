#include "mouse.h"
#include "../utils/log.h"

#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>

static WMEventCallback g_cb;
static void           *g_ud;
static CFMachPortRef   g_tap;

static CGEventRef mouse_tap_cb(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *userinfo) {
    (void)proxy; (void)userinfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }
    if (!g_cb) return event;

    if (type == kCGEventLeftMouseDown) {
        g_cb(WM_EVENT_MOUSE_DOWN, 0, 0, g_ud);
    } else if (type == kCGEventLeftMouseUp) {
        g_cb(WM_EVENT_MOUSE_UP, 0, 0, g_ud);
    }
    return event; // listen-only: never alter the event
}

void mouse_watch(WMEventCallback cb, void *userdata) {
    g_cb = cb;
    g_ud = userdata;

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                             kCGEventTapOptionListenOnly, mask, mouse_tap_cb, NULL);
    if (!g_tap) {
        fprintf(stderr, "warning: mouse drag handling unavailable — grant Accessibility "
                        "in System Settings → Privacy & Security → Accessibility\n");
        return;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(g_tap, true);
    LOG("mouse", "drag watch enabled");
}
