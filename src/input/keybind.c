#include "keybind.h"

#include <stdio.h>

#define MAX_BINDINGS 256

// Device-independent modifier bits we match on. macOS sets extra bits
// (kCGEventFlagMaskNonCoalesced, caps lock, fn, numeric pad) that must be masked
// out before comparing, or shortcuts silently fail.
static const CGEventFlags kModMask =
    kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
    kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;

typedef struct {
    CGEventFlags  mods;
    CGKeyCode     key;
    KeybindAction action;
    void         *ctx;
} Binding;

static Binding       g_bindings[MAX_BINDINGS];
static int           g_binding_count;
static CFMachPortRef g_tap;

bool keybind_register(CGEventFlags mods, CGKeyCode key, KeybindAction action, void *ctx) {
    if (g_binding_count >= MAX_BINDINGS || !action) return false;
    g_bindings[g_binding_count++] = (Binding){
        .mods = mods & kModMask, .key = key, .action = action, .ctx = ctx,
    };
    return true;
}

static CGEventRef tap_cb(CGEventTapProxy proxy, CGEventType type,
                         CGEventRef event, void *userinfo) {
    (void)proxy; (void)userinfo;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }
    if (type != kCGEventKeyDown) return event;

    CGKeyCode    key  = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags mods = CGEventGetFlags(event) & kModMask;

    for (int i = 0; i < g_binding_count; i++) {
        if (g_bindings[i].key == key && g_bindings[i].mods == mods) {
            g_bindings[i].action(g_bindings[i].ctx);
            return NULL; // swallow the event
        }
    }
    return event;
}

void keybind_start(void) {
    if (g_binding_count == 0) return; // nothing bound

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                             kCGEventTapOptionDefault, mask, tap_cb, NULL);
    if (!g_tap) {
        fprintf(stderr, "warning: keybindings unavailable — grant Accessibility "
                        "in System Settings → Privacy & Security → Accessibility\n");
        return;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(g_tap, true);
}
