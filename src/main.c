#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

#include "platform/platform.h"
#include "accessibility/enumerate.h"
#include "accessibility/observers.h"
#include "config/config.h"
#include "input/keybind.h"
#include "input/mouse.h"
#include "tree/manager.h"
#include "utils/verify_perms.h"

int main(void) {
    platform_init();

    if (!verify_perms()) {
        return 1;
    }

    // Load config first: it registers the agate Lua API and the user's
    // keybindings, and sets gaps/normalization options used below.
    config_load();

    // Adopt windows that are already open into their Space trees and tile.
    enumerate_adopt_windows();

    // Route all window/space events into the tiling manager.
    platform_watch_spaces(manager_handle_event, NULL);
    platform_watch_running_apps(manager_handle_event, NULL);
    platform_watch_app_lifecycle(manager_handle_event, NULL);
    platform_enable_alt_tab_space_switch(manager_handle_event, NULL);

    // Interactive window drags: snap-back on move, weight recompute on resize.
    mouse_watch(manager_handle_event, NULL);

    // Start intercepting the configured global hotkeys.
    keybind_start();

    printf("agate: tiling\n");
    CFRunLoopRun();
    return 0;
}
