#include <stdio.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include "../platform/userdefaults.h"

// Checks if all settings and permissions are in place for the app to run correctly. If not, prints an error message and returns false.
bool verify_perms() {

    // Use bool so it shows all issues at once
    bool is_ok = true;

    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "error: accessibility permissions required — grant access in System Settings → Privacy → Accessibility\n");
        is_ok = false;
    }

    // Read defaults to check if the following setting is turned off:
    //  system.defaults.NSGlobalDomain.AppleSpacesSwitchOnActivate
    if (platform_get_default_bool("NSGlobalDomain", "AppleSpacesSwitchOnActivate") == 1) {
        fprintf(stderr, "error: the setting 'System Settings → Desktop & Dock → 'When switching to an application, switch to a Space with open windows for the application'' must be turned off\n");
        is_ok = false;
    }

    // system.defaults.dock.mru-spaces also needs to be turned off.
    if (platform_get_default_bool("com.apple.dock", "mru-spaces") == 1) {
        fprintf(stderr, "error: the setting 'System Settings → Desktop & Dock → 'Automatically rearrange Spaces based on most recent use'' must be turned off\n");
        is_ok = false;
    }

    return is_ok;
}
