#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

#include "platform.h"
#include "accessibility/enumerate.h"
#include "accessibility/observers.h"

static void on_wm_event(WMEventType event, pid_t pid, CGWindowID wid, void *userdata) {
    (void)userdata;
    static const char *names[] = {
        [WM_EVENT_WINDOW_MOVED]       = "window_moved",
        [WM_EVENT_WINDOW_APPEARED]    = "window_appeared",
        [WM_EVENT_WINDOW_RESIZED]     = "window_resized",
        [WM_EVENT_WINDOW_DISAPPEARED] = "window_disappeared",
        [WM_EVENT_SPACE_CHANGED]      = "space_changed",
        [WM_EVENT_ALT_TAB]            = "alt_tab",
    };
    printf("[event] %-20s  pid=%-6d  wid=%u\n", names[event], pid, wid);
}

int main(void) {
    platform_init();

    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "error: accessibility permissions required — grant access in System Settings → Privacy → Accessibility\n");
        return 1;
    }

    enumerate_windows();

    platform_watch_spaces(on_wm_event, NULL);
    platform_watch_running_apps(on_wm_event, NULL);
    platform_enable_alt_tab_space_switch(on_wm_event, NULL);

    printf("observing...\n");
    CFRunLoopRun();
    return 0;
}
