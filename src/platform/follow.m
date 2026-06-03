#import "platform.h"
#import "internal.h"
#import "../extern/skylight.h"
#import "../extern/ax_private.h"
#import <AppKit/AppKit.h>
#import <stdio.h>

// GetProcessForPID / ProcessSerialNumber come from ApplicationServices
// (HIServices/Processes.h), pulled in via ax_private.h.

// Mark `psn` as the frontmost process *of a space* (so the activated app is
// focused on its destination space, not just globally).
extern CGError SLSSpaceSetFrontPSN(SLSConnectionID cid, uint64_t sid, ProcessSerialNumber psn);

#define kVK_Tab 0x30  // virtual keycode for the Tab key

// Gate state: we only follow space on an activation shortly after the user did
// something that legitimately raises an app — a Cmd+Tab, or a click that landed
// on a Dock icon. This excludes background activations and the ones our own
// space switch provokes (no preceding input → no ping-pong). Times are
// monotonic seconds (NSProcessInfo.systemUptime).
static NSTimeInterval g_last_cmd_tab;     // last Cmd+Tab
static NSTimeInterval g_last_dock_click;  // last click that hit-tested onto a Dock item
static pid_t          g_dock_pid;         // com.apple.dock, for classifying clicks

// Managed space id of a window. Mask 0x7 (user + fullscreen + system spaces);
// ~0ULL wrongly returns the active space for any window. The array is empty for
// a window on the visible space OR for an unmanaged window (panel/sheet) — both
// yield 0, i.e. "no off-screen space to follow".
static uint64_t space_of_window(CGWindowID wid) {
    if (!wid) return 0;
    CFArrayRef arr = SLSCopySpacesForWindows(CGSMainConnectionID(), 0x7,
                                             (__bridge CFArrayRef)@[ @(wid) ]);
    uint64_t sid = 0;
    if (arr) {
        if (CFArrayGetCount(arr)) sid = [((__bridge NSArray *)arr)[0] unsignedLongLongValue];
        CFRelease(arr);
    }
    return sid;
}

// AX focused (else main) window of `pid`. Accurate for "the window the user is
// on", but can return an auxiliary window with no managed space.
static CGWindowID ax_front_window_id(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return 0;
    AXUIElementRef win = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&win) != kAXErrorSuccess) win = NULL;
    if (!win) AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, (CFTypeRef *)&win);
    CFRelease(app);
    if (!win) return 0;
    CGWindowID wid = 0;
    _AXUIElementGetWindow(win, &wid);
    CFRelease(win);
    return wid;
}

// Scan every managed space for a top-level (layer-0) window owned by `pid`,
// returning that space's id. This mirrors the enumerate logic and is the
// reliable way to map an app to its space — AX can hand back an auxiliary
// window, and CGWindowList's frontmost-window heuristic picks the wrong one.
// Returns the first matching space (lowest Mission Control order) or 0.
static uint64_t app_space_for_pid(pid_t pid) {
    SLSConnectionID cid = CGSMainConnectionID();
    CFArrayRef displays = SLSCopyManagedDisplaySpaces(cid);
    if (!displays) return 0;

    uint64_t found = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(displays) && !found; i++) {
        CFDictionaryRef disp = CFArrayGetValueAtIndex(displays, i);
        CFArrayRef spaces = CFDictionaryGetValue(disp, CFSTR("Spaces"));
        for (CFIndex j = 0; spaces && j < CFArrayGetCount(spaces) && !found; j++) {
            CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, j);
            uint64_t sid = platform_managed_space_id((__bridge NSDictionary *)space);
            CFNumberRef id64 = CFDictionaryGetValue(space, CFSTR("id64"));
            if (!sid || !id64) continue;

            const void *v[1] = { id64 };
            CFArrayRef spaceArr = CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);
            uint64_t setTags = 0, clearTags = 0;
            CFArrayRef wids = SLSCopyWindowsWithOptionsAndTags(cid, 0, spaceArr, 0x2, &setTags, &clearTags);

            if (wids && CFArrayGetCount(wids)) {
                CFIndex n = CFArrayGetCount(wids);
                const void **raw = malloc(sizeof(void *) * (size_t)n);
                for (CFIndex k = 0; k < n; k++) {
                    uint32_t w = 0;
                    CFNumberGetValue(CFArrayGetValueAtIndex(wids, k), kCFNumberSInt32Type, &w);
                    raw[k] = (const void *)(uintptr_t)w;
                }
                CFArrayRef idArray = CFArrayCreate(NULL, raw, n, NULL);
                CFArrayRef descs = CGWindowListCreateDescriptionFromArray(idArray);
                for (CFIndex k = 0; descs && k < CFArrayGetCount(descs); k++) {
                    CFDictionaryRef d = CFArrayGetValueAtIndex(descs, k);
                    long layer = 0, opid = 0;
                    CFNumberRef ln = CFDictionaryGetValue(d, kCGWindowLayer);
                    CFNumberRef pn = CFDictionaryGetValue(d, kCGWindowOwnerPID);
                    if (ln) CFNumberGetValue(ln, kCFNumberLongType, &layer);
                    if (pn) CFNumberGetValue(pn, kCFNumberLongType, &opid);
                    if (layer == 0 && (pid_t)opid == pid) { found = sid; break; }
                }
                if (descs) CFRelease(descs);
                CFRelease(idArray);
                free(raw);
            }
            if (wids) CFRelease(wids);
            CFRelease(spaceArr);
        }
    }
    CFRelease(displays);
    return found;
}

// Managed space id of the space `pid` lives on, or 0 if on the visible space /
// not found. Prefers the AX focused window when it resolves to a managed space
// (most accurate for multi-window apps); otherwise scans spaces by pid.
static uint64_t app_front_window_space(pid_t pid) {
    CGWindowID ax = ax_front_window_id(pid);
    uint64_t sid = space_of_window(ax);
    if (sid == 0) sid = app_space_for_pid(pid);
    return sid;
}

// If `pid`'s front window is on a non-visible space, focus that app on its
// space and instantly switch to it.
static void switch_to_app_space(pid_t pid) {
    if (pid <= 0 || pid == getpid()) return;

    // Only follow space for activations the user drove via Cmd+Tab or a Dock
    // click in the last ~1.5s.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - g_last_cmd_tab > 1.5 && now - g_last_dock_click > 1.5) return;

    uint64_t sid = app_front_window_space(pid);
    if (sid == 0 || sid == platform_active_space()) return;

    // GetProcessForPID is the simplest pid→PSN bridge; deprecated but still the
    // path window managers use, and SLSSpaceSetFrontPSN wants a PSN.
    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) == 0) {
#pragma clang diagnostic pop
        SLSSpaceSetFrontPSN(CGSMainConnectionID(), sid, psn);
    }
    platform_focus_space(sid);
}

static WMEventCallback g_alt_cb;
static void           *g_alt_ud;
static CFMachPortRef   g_alt_tap;

// True if the screen point `p` is on a Dock icon. Hit-tested at click time
// (when the Dock is showing under the cursor) via Accessibility — the Dock has
// no per-icon window to test against, and there is no SkyLight dock-click event.
static bool click_was_on_dock(CGPoint p) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    AXUIElementRef hit = NULL;
    bool yes = false;
    if (AXUIElementCopyElementAtPosition(sys, (float)p.x, (float)p.y, &hit) == kAXErrorSuccess && hit) {
        pid_t hp = 0;
        AXUIElementGetPid(hit, &hp);
        if (g_dock_pid && hp == g_dock_pid) {
            yes = true;  // anything the Dock owns at that point
        } else {
            CFTypeRef r = NULL;
            if (AXUIElementCopyAttributeValue(hit, kAXRoleAttribute, &r) == kAXErrorSuccess && r) {
                yes = CFEqual(r, CFSTR("AXDockItem"));
                CFRelease(r);
            }
        }
        CFRelease(hit);
    }
    CFRelease(sys);
    return yes;
}

// Listen-only session tap. Surfaces Cmd+Tab as WM_EVENT_ALT_TAB and records the
// timestamps that gate the space-follow. The window-server connection event for
// Cmd+Tab is undocumented and version-specific (it did not fire on macOS 26),
// so we observe the keystroke directly — the same approach AltTab uses. The
// event is returned unchanged so the system app switcher still works.
static CGEventRef alt_tab_tap_cb(CGEventTapProxy proxy, CGEventType type,
                                 CGEventRef event, void *userinfo) {
    (void)proxy; (void)userinfo;

    // A tap can be silently disabled by a timeout or user input; re-arm it.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_alt_tap) CGEventTapEnable(g_alt_tap, true);
        return event;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;

    if (type == kCGEventKeyDown) {
        CGKeyCode key     = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flag = CGEventGetFlags(event);
        if (key == kVK_Tab && (flag & kCGEventFlagMaskCommand)) {
            g_last_cmd_tab = now;  // gate the space-follow
            // Coalesce the emitted event (Tab auto-repeats while Cmd is held).
            static NSTimeInterval last_emit;
            if (now - last_emit > 0.3) {
                last_emit = now;
                if (g_alt_cb) g_alt_cb(WM_EVENT_ALT_TAB, 0, 0, g_alt_ud);
            }
        }
    } else if (type == kCGEventLeftMouseDown) {
        // Classify the click now, while the Dock is visible under the cursor.
        if (click_was_on_dock(CGEventGetLocation(event))) g_last_dock_click = now;
    }
    return event;
}

void platform_enable_alt_tab_space_switch(WMEventCallback cb, void *userdata) {
    g_alt_cb = cb;
    g_alt_ud = userdata;

    // Cache the Dock's pid so clicks on it can be classified cheaply.
    for (NSRunningApplication *a in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([a.bundleIdentifier isEqualToString:@"com.apple.dock"]) {
            g_dock_pid = (pid_t)a.processIdentifier;
            break;
        }
    }

    // Detect Cmd+Tab and clicks (Dock icons) via a listen-only session tap.
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventLeftMouseDown);
    g_alt_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                 kCGEventTapOptionListenOnly, mask, alt_tab_tap_cb, NULL);
    if (!g_alt_tap) {
        fprintf(stderr, "warning: alt-tab detection unavailable — grant Input Monitoring "
                        "in System Settings → Privacy & Security → Input Monitoring\n");
    } else {
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, g_alt_tap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        CFRelease(src);
        CGEventTapEnable(g_alt_tap, true);
    }

    // App activation (fired by Cmd+Tab and by Dock/click activations) is the
    // reliable trigger that carries which app was activated; do the instant
    // space follow from here.
    static id token; (void)token;
    token = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if (app) switch_to_app_space((pid_t)app.processIdentifier);
        }];
}
