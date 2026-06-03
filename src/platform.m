#import "platform.h"
#import "accessibility/observers.h"
#import "extern/skylight.h"
#import "extern/ax_private.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>

// --- Private symbols used only here ----------------------------------------
// GetProcessForPID / ProcessSerialNumber come from ApplicationServices
// (HIServices/Processes.h), pulled in via ax_private.h.

// Mark `psn` as the frontmost process *of a space* (so the activated app is
// focused on its destination space, not just globally).
extern CGError  SLSSpaceSetFrontPSN(SLSConnectionID cid, uint64_t sid, ProcessSerialNumber psn);

#define kVK_Tab 0x30  // virtual keycode for the Tab key

uint64_t platform_active_space(void) {
    SLSConnectionID cid = CGSMainConnectionID();
    CFStringRef uuid = SLSCopyActiveMenuBarDisplayIdentifier(cid);
    if (!uuid) return 0;
    uint64_t sid = SLSManagedDisplayGetCurrentSpace(cid, uuid);
    CFRelease(uuid);
    return sid;
}

bool platform_move_window_to_space(CGWindowID wid, uint64_t sid) {
    if (wid == 0 || sid == 0) return false;

    // SLSBridgedMoveWindowsToManagedSpaceOperation is part of the SkyLight
    // WindowManagement bridge — the same machinery the native window manager
    // uses. Driving it directly through the ObjC runtime performs the move via
    // the WMBridge delegate, with no SIP changes and no injection.
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!cls) return false;

    SEL initSel    = NSSelectorFromString(@"initWithWindows:spaceID:");
    SEL performSel = NSSelectorFromString(@"performWithWMBridgeDelegate");
    if (![cls instancesRespondToSelector:initSel] ||
        ![cls instancesRespondToSelector:performSel]) return false;

    // Every operation-object handle below is held as void * so ARC stays out of
    // its lifetime: -initWithWindows:spaceID: takes a scalar uint64 (not
    // expressible through ARC's normal messaging), so we drive it via
    // objc_msgSend casts and balance the +1 from +alloc with a manual release.
    typedef void *(*MsgAlloc) (void *, SEL);
    typedef void *(*MsgInit)  (void *, SEL, void *, uint64_t);
    typedef void  (*MsgVoid)  (void *, SEL);

    NSArray *windows = @[ @(wid) ];  // ARC-managed; stays alive across the call

    void *raw = ((MsgAlloc)objc_msgSend)((__bridge void *)cls, sel_registerName("alloc"));
    if (!raw) return false;

    void *op = ((MsgInit)objc_msgSend)(raw, initSel, (__bridge void *)windows, sid);
    void *obj = op ? op : raw;  // init may substitute the instance; track whichever we own

    if (op) ((MsgVoid)objc_msgSend)(op, performSel);

    ((MsgVoid)objc_msgSend)(obj, sel_registerName("release"));
    return op != NULL;
}

bool platform_move_window_to_active_space(CGWindowID wid) {
    uint64_t sid = platform_active_space();
    if (sid == 0) return false;
    return platform_move_window_to_space(wid, sid);
}

// ManagedSpaceID (preferred) or id64 out of a SkyLight space/Current-Space dict.
static uint64_t managed_space_id(NSDictionary *d) {
    if (!d) return 0;
    uint64_t v = [d[@"ManagedSpaceID"] unsignedLongLongValue];
    return v ?: [d[@"id64"] unsignedLongLongValue];
}

// CGDirectDisplayID whose UUID string matches `uuid`, or kCGNullDirectDisplay.
static CGDirectDisplayID display_id_for_uuid(NSString *uuid) {
    CGDirectDisplayID ids[16]; uint32_t n = 0;
    if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess) return kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++) {
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if (!u) continue;
        CFStringRef s = CFUUIDCreateString(NULL, u);
        bool match = s && [uuid isEqualToString:(__bridge NSString *)s];
        if (s) CFRelease(s);
        CFRelease(u);
        if (match) return ids[i];
    }
    return kCGNullDirectDisplay;
}

// Display currently under the mouse cursor.
static CGDirectDisplayID cursor_display_id(void) {
    CGEventRef ev = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(ev);
    CFRelease(ev);
    CGDirectDisplayID did = kCGNullDirectDisplay; uint32_t cnt = 0;
    CGGetDisplaysWithPoint(p, 1, &did, &cnt);
    return cnt ? did : kCGNullDirectDisplay;
}

bool platform_focus_space(uint64_t sid) {
    if (sid == 0) return false;
    SLSConnectionID cid = CGSMainConnectionID();

    // Find the display that owns `sid`, the ordered index of `sid` within that
    // display, and the index of that display's own current space. The dock
    // swipe moves one space per gesture, so the swipe count is the index gap.
    NSString *displayId = nil;
    int cur_index = -1, new_index = -1;
    CFArrayRef disp = SLSCopyManagedDisplaySpaces(cid);
    if (!disp) return false;
    for (CFIndex d = 0; d < CFArrayGetCount(disp) && new_index < 0; d++) {
        NSDictionary *dd = (__bridge NSDictionary *)CFArrayGetValueAtIndex(disp, d);
        uint64_t dcur = managed_space_id(dd[@"Current Space"]);
        int i = 0, ci = -1, ni = -1;
        for (NSDictionary *s in dd[@"Spaces"]) {
            uint64_t x = managed_space_id(s);
            if (x == dcur) ci = i;
            if (x == sid)  ni = i;
            i++;
        }
        if (ni >= 0) { displayId = dd[@"Display Identifier"]; cur_index = ci; new_index = ni; }
    }
    CFRelease(disp);
    if (new_index < 0 || cur_index < 0 || !displayId) return false;

    // If the target space lives on a different display than the cursor, warp the
    // cursor to that display so the dock-swipe gesture is delivered there.
    CGDirectDisplayID target_did = display_id_for_uuid(displayId);
    if (target_did != kCGNullDirectDisplay && target_did != cursor_display_id()) {
        CGRect b = CGDisplayBounds(target_did);
        CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)));
    }

    int count = abs(new_index - cur_index);
    if (count == 0) return true;  // already the current space on its display

    // No public/private API activates a space, so synthesize a sequence of
    // high-velocity horizontal dock-swipe gestures. Velocity 9999 is large
    // enough that the window server skips the transition animation. Field
    // numbers and constants are the undocumented CGEvent gesture encoding
    // (see yabai space_manager_focus_space_using_gesture / #2781).
    double sign = (new_index - cur_index) > 0 ? 1.0 : -1.0;

    CGEventRef e = CGEventCreate(NULL);
    if (!e) return false;
    CGEventSetIntegerValueField(e, (CGEventField)55,  30);   // kCGSEventTypeField = kCGSEventDockControl
    CGEventSetIntegerValueField(e, (CGEventField)110, 23);   // kCGEventGestureHIDType = kIOHIDEventTypeDockSwipe
    CGEventSetIntegerValueField(e, (CGEventField)123, 1);    // kCGEventGestureSwipeMotion = horizontal
    CGEventSetDoubleValueField (e, (CGEventField)124, sign); // kCGEventGestureSwipeProgress
    CGEventSetDoubleValueField (e, (CGEventField)129, sign * 9999.0); // kCGEventGestureSwipeVelocityX

    for (int k = 0; k < count; k++) {
        CGEventSetIntegerValueField(e, (CGEventField)132, 1); // kCGEventGesturePhase = began
        CGEventPost(kCGSessionEventTap, e);
        CGEventSetIntegerValueField(e, (CGEventField)132, 4); // kCGEventGesturePhase = ended
        CGEventPost(kCGSessionEventTap, e);
    }
    CFRelease(e);
    return true;
}

// Monotonic timestamp (seconds) of the most recent explicit user action that
// can cause an app to activate — a Cmd+Tab or a mouse click. We only follow
// space on activations shortly after one of these, which excludes background
// activations and the ones our own space switch provokes (no preceding input).
static NSTimeInterval g_last_user_input;

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
            uint64_t sid = managed_space_id((__bridge NSDictionary *)space);
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
    const char *via = "ax";
    if (sid == 0) { sid = app_space_for_pid(pid); via = "scan"; }
    fprintf(stderr, "    [lookup] pid=%d ax_wid=%u via=%s -> space=%llu\n", pid, ax, via, sid);
    return sid;
}

// If `pid`'s front window is on a non-visible space, focus that app on its
// space and instantly switch to it.
static void switch_to_app_space(pid_t pid) {
    if (pid <= 0 || pid == getpid()) return;

    // Only follow space for activations the user drove via Cmd+Tab or a click
    // (e.g. a Dock icon) in the last ~1.5s. This excludes background
    // activations and the ones our own space switch provokes (no preceding
    // input → no ping-pong).
    if (NSProcessInfo.processInfo.systemUptime - g_last_user_input > 1.5) return;

    uint64_t sid = app_front_window_space(pid);
    uint64_t cur = platform_active_space();
    fprintf(stderr, "  [switch] pid=%d app_window_space=%llu current=%llu -> %s\n",
            pid, sid, cur, (sid && sid != cur) ? "SWITCHING" : "skip");
    if (sid == 0 || sid == cur) return;

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

// Listen-only keyboard tap: surfaces Cmd+Tab as WM_EVENT_ALT_TAB. The
// window-server connection event for Cmd+Tab is undocumented and version-
// specific (it did not fire on macOS 26), so we observe the keystroke directly
// — the same approach AltTab uses. The event is returned unchanged so the
// system app switcher still works.
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
            g_last_user_input = now;  // gate the space-follow
            // Coalesce the emitted event (Tab auto-repeats while Cmd is held).
            static NSTimeInterval last_emit;
            if (now - last_emit > 0.3) {
                last_emit = now;
                if (g_alt_cb) g_alt_cb(WM_EVENT_ALT_TAB, 0, 0, g_alt_ud);
            }
        }
    } else if (type == kCGEventLeftMouseDown) {
        g_last_user_input = now;  // e.g. a Dock-icon click
    }
    return event;
}

void platform_enable_alt_tab_space_switch(WMEventCallback cb, void *userdata) {
    g_alt_cb = cb;
    g_alt_ud = userdata;

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
