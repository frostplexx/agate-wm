#include <stdio.h>
#include "../platform/platform.h"
#include "../platform/userdefaults.h"

// Checks if all settings and permissions are in place for the app to run correctly. If not, prints an error message and returns false.
bool verify_perms() {

    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "error: accessibility permissions required — grant access in System Settings → Privacy → Accessibility\n");
        return false;
    }

    // Read defaults to check if the following setting is turned off:
    //  system.defaults.NSGlobalDomain.AppleSpacesSwitchOnActivate
    if (platform_get_default_bool("NSGlobalDomain", "AppleSpacesSwitchOnActivate") == 1) {
        fprintf(stderr, "error: the setting 'System Settings → Desktop & Dock → 'When switching to an application, switch to a Space with open windows for the application'' must be turned off\n");
        return false;
    }

    // system.defaults.dock.mru-spaces also needs to be turned off.
    if (platform_get_default_bool("com.apple.dock", "mru-spaces") == 1) {
        fprintf(stderr, "error: the setting 'System Settings → Desktop & Dock → 'Automatically rearrange Spaces based on most recent use'' must be turned off\n");
        return false;
    }


    return true;
}
