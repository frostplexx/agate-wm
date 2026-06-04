#import "platform.h"
#import "../accessibility/observers.h"
#import "../extern/ax_private.h"
#import <AppKit/AppKit.h>

void platform_init(void) {
    [NSApplication sharedApplication];
    // Accessory policy: no Dock icon, no menu bar, but the process keeps a full
    // per-session WindowServer/AppKit connection. Prohibited suppresses that
    // session bootstrap, which silently stops NSWorkspace space-change
    // notifications from being delivered.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void platform_watch_spaces(WMEventCallback cb, void *userdata) {
    // The tokens returned by addObserverForName:... must be retained for as long
    // as the observers should be active. Without these statics, ARC releases them
    // on return and the observers are silently unregistered.
    static id space_token;  (void)space_token;
    static id app_token;    (void)app_token;

    // Last space id we reported a change for, so we only fire on a real change
    // and never double-fire when both notifications land for one transition.
    static uint64_t last_sid;
    last_sid = platform_active_space();

    // Fire SPACE_CHANGED only when the active space actually differs from the
    // last one we saw. Shared by both notification paths below.
    void (^emit_if_changed)(void) = ^{
        uint64_t sid = platform_active_space();
        if (sid && sid != last_sid) {
            last_sid = sid;
            if (cb) cb(WM_EVENT_SPACE_CHANGED, 0, 0, userdata);
        }
    };

    NSNotificationCenter *wc = NSWorkspace.sharedWorkspace.notificationCenter;

    // Explicit space navigation: swipe, Ctrl+arrow, Mission Control.
    space_token = [wc
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) { (void)note; emit_if_changed(); }];

    // App activation: Cmd+Tab to an app on another space auto-swooshes to that
    // space WITHOUT posting ActiveSpaceDidChange. Re-checking the active space
    // here catches those transitions.
    app_token = [wc
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) { (void)note; emit_if_changed(); }];
}

void platform_watch_running_apps(WMEventCallback cb, void *userdata) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (app.processIdentifier == getpid()) continue;
        observers_register_app((pid_t)app.processIdentifier, cb, userdata);
    }
}

// Announce the windows an app already has open as WM_EVENT_WINDOW_APPEARED.
// observers_register_app subscribes to existing windows silently (to avoid
// re-announcing startup windows); a freshly launched app may already own a
// window by the time its launch notification fires, so we announce those here.
// Re-announcing a window already in a tree is a no-op (the manager dedupes).
static void announce_existing_windows(pid_t pid, WMEventCallback cb, void *userdata) {
    if (!cb) return;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return;
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CGWindowID wid = 0;
            if (_AXUIElementGetWindow(w, &wid) == kAXErrorSuccess && wid) {
                cb(WM_EVENT_WINDOW_APPEARED, pid, wid, userdata);
            }
        }
        CFRelease(wins);
    }
    CFRelease(app);
}

void platform_watch_app_lifecycle(WMEventCallback cb, void *userdata) {
    static id launch_token;    (void)launch_token;
    static id terminate_token; (void)terminate_token;

    NSNotificationCenter *wc = NSWorkspace.sharedWorkspace.notificationCenter;

    launch_token = [wc
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if (!app || app.activationPolicy != NSApplicationActivationPolicyRegular) return;
            if (app.processIdentifier == getpid()) return;
            pid_t pid = (pid_t)app.processIdentifier;
            if (observers_register_app(pid, cb, userdata)) {
                announce_existing_windows(pid, cb, userdata);
            }
        }];

    terminate_token = [wc
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if (!app) return;
            pid_t pid = (pid_t)app.processIdentifier;
            observers_unregister_app(pid);
            if (cb) cb(WM_EVENT_APP_TERMINATED, pid, 0, userdata);
        }];
}
