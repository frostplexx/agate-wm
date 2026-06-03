#import "platform.h"
#import "internal.h"
#import "../extern/skylight.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

uint64_t platform_managed_space_id(NSDictionary *d) {
    if (!d) return 0;
    uint64_t v = [d[@"ManagedSpaceID"] unsignedLongLongValue];
    return v ?: [d[@"id64"] unsignedLongLongValue];
}

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
        uint64_t dcur = platform_managed_space_id(dd[@"Current Space"]);
        int i = 0, ci = -1, ni = -1;
        for (NSDictionary *s in dd[@"Spaces"]) {
            uint64_t x = platform_managed_space_id(s);
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
