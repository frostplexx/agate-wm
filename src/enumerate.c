// enumerate.c — minimal window enumeration across ALL spaces, built on the
// src/extern bridges.
//
// CGWindowList's on-screen list only covers the current Mission Control space,
// so we drive it from SkyLight instead:
//   SLSCopyManagedDisplaySpaces      -> every space on every display
//   SLSCopyWindowsWithOptionsAndTags -> the window ids living in each space
//   CGWindowListCreateDescriptionFromArray -> owner / title / bounds / layer
//   SLSWindowIteratorGetParentID     -> drop sheets / child windows

#include "extern/skylight.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// SkyLight parent id of a window: 0 for a top-level window, non-zero for a
// sheet / drawer / child.
static uint32_t window_parent_id(SLSConnectionID cid, uint32_t wid) {
    CFNumberRef widRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    const void *values[1] = {widRef};
    CFArrayRef windows = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);

    uint32_t parent = 0;
    CFTypeRef query = SLSWindowQueryWindows(cid, windows, 1);
    if (query) {
        CFTypeRef it = SLSWindowQueryResultCopyWindows(query);
        if (it) {
            if (SLSWindowIteratorAdvance(it)) parent = SLSWindowIteratorGetParentID(it);
            CFRelease(it);
        }
        CFRelease(query);
    }
    CFRelease(windows);
    CFRelease(widRef);
    return parent;
}

static long dict_int(CFDictionaryRef d, CFStringRef key) {
    long v = 0;
    CFNumberRef n = CFDictionaryGetValue(d, key);
    if (n) CFNumberGetValue(n, kCFNumberLongType, &v);
    return v;
}

static void dict_str(CFDictionaryRef d, CFStringRef key, char *buf, size_t len) {
    buf[0] = '\0';
    CFStringRef s = CFDictionaryGetValue(d, key);
    if (s) CFStringGetCString(s, buf, (CFIndex)len, kCFStringEncodingUTF8);
}

// CGWindowListCreateDescriptionFromArray wants the window ids stored as raw
// integer pointer values, but SkyLight hands us CFNumbers — convert.
static CFArrayRef describe(CFArrayRef cfNumberIDs) {
    CFIndex n = CFArrayGetCount(cfNumberIDs);
    const void **raw = malloc(sizeof(void *) * (size_t)n);
    CFIndex k = 0;
    for (CFIndex i = 0; i < n; i++) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(cfNumberIDs, i), kCFNumberSInt32Type, &wid);
        raw[k++] = (const void *)(uintptr_t)wid;
    }
    CFArrayRef idArray = CFArrayCreate(NULL, raw, k, NULL);
    CFArrayRef desc = CGWindowListCreateDescriptionFromArray(idArray);
    CFRelease(idArray);
    free(raw);
    return desc;
}

static int print_space(SLSConnectionID cid, CFNumberRef spaceID64, int ordinal) {
    long sid = 0;
    CFNumberGetValue(spaceID64, kCFNumberLongType, &sid);

    const void *v[1] = {spaceID64};
    CFArrayRef spaceArr = CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);
    uint64_t setTags = 0, clearTags = 0;
    CFArrayRef wids = SLSCopyWindowsWithOptionsAndTags(cid, 0, spaceArr, 0x2, &setTags, &clearTags);

    int shown = 0;
    // `ordinal` is the Mission Control desktop number (1-based); `sid` is the
    // internal id64 SkyLight uses — they are not the same and id64s aren't
    // contiguous.
    printf("Space %d (id64=%ld):\n", ordinal, sid);
    if (wids) {
        CFArrayRef descs = describe(wids);
        for (CFIndex i = 0; descs && i < CFArrayGetCount(descs); i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(descs, i);

            if (dict_int(d, kCGWindowLayer) != 0) continue; // normal app windows only

            CGRect bounds = CGRectZero;
            CFDictionaryRef boundsDict = CFDictionaryGetValue(d, kCGWindowBounds);
            if (boundsDict) CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds);
            if (bounds.size.width < 100 || bounds.size.height < 80) continue;

            uint32_t wid = (uint32_t)dict_int(d, kCGWindowNumber);
            if (window_parent_id(cid, wid) != 0) continue; // skip sheets / child windows

            char owner[256], title[256];
            dict_str(d, kCGWindowOwnerName, owner, sizeof(owner));
            dict_str(d, kCGWindowName, title, sizeof(title));

            printf("  [%-7u] pid=%-6ld %-20.20s %-30.30s (%.0f,%.0f %.0fx%.0f)\n", wid,
                   dict_int(d, kCGWindowOwnerPID), owner, title, bounds.origin.x, bounds.origin.y,
                   bounds.size.width, bounds.size.height);
            shown++;
        }
        if (descs) CFRelease(descs);
        CFRelease(wids);
    }
    CFRelease(spaceArr);
    return shown;
}

void enumerate_windows(void) {
    SLSConnectionID cid = CGSMainConnectionID();

    CFArrayRef displays = SLSCopyManagedDisplaySpaces(cid);
    if (!displays) {
        printf("no spaces\n");
        return;
    }

    int total = 0;
    int ordinal = 0; // Mission Control desktop number, counted across displays
    for (CFIndex i = 0; i < CFArrayGetCount(displays); i++) {
        CFDictionaryRef disp = CFArrayGetValueAtIndex(displays, i);
        CFArrayRef spaces = CFDictionaryGetValue(disp, CFSTR("Spaces"));
        for (CFIndex j = 0; spaces && j < CFArrayGetCount(spaces); j++) {
            CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, j);
            CFNumberRef id64 = CFDictionaryGetValue(space, CFSTR("id64"));
            if (id64) total += print_space(cid, id64, ++ordinal);
        }
    }
    printf("%d window(s) across all spaces\n", total);

    CFRelease(displays);
}
