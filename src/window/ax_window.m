#import "ax_window.h"
#import "../extern/ax_private.h"
#import "../extern/skylight.h"
#import "../utils/log.h"

#import <AppKit/AppKit.h>

// Cache of CGWindowID -> AXUIElementRef so we don't re-walk an app's window
// list on every frame change. Entries are refreshed on a miss and dropped via
// ax_window_forget when a window disappears.
#define MAX_WINDOW_CACHE 512
typedef struct {
    CGWindowID     wid;
    AXUIElementRef el; // retained
} WinCacheEntry;

static WinCacheEntry g_cache[MAX_WINDOW_CACHE];
static int           g_cache_count;

// Resolve (and cache) the AX window element for (pid, wid); defined below.
static AXUIElementRef resolve_window(pid_t pid, CGWindowID wid);

bool ax_window_is_top_level(CGWindowID wid) {
    if (wid == 0) return false;

    SLSConnectionID cid = CGSMainConnectionID();
    CFNumberRef widRef  = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    const void *v[1]    = { widRef };
    CFArrayRef  arr     = CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);

    uint32_t parent = 0;
    CFTypeRef query = SLSWindowQueryWindows(cid, arr, 1);
    if (query) {
        CFTypeRef it = SLSWindowQueryResultCopyWindows(query);
        if (it) {
            if (SLSWindowIteratorAdvance(it)) parent = SLSWindowIteratorGetParentID(it);
            CFRelease(it);
        }
        CFRelease(query);
    }
    CFRelease(arr);
    CFRelease(widRef);
    return parent == 0;
}

static AXUIElementRef cache_lookup(CGWindowID wid) {
    for (int i = 0; i < g_cache_count; i++) {
        if (g_cache[i].wid == wid) return g_cache[i].el;
    }
    return NULL;
}

static void cache_store(CGWindowID wid, AXUIElementRef el) {
    for (int i = 0; i < g_cache_count; i++) {
        if (g_cache[i].wid == wid) {
            if (g_cache[i].el != el) {
                CFRelease(g_cache[i].el);
                g_cache[i].el = (AXUIElementRef)CFRetain(el);
            }
            return;
        }
    }
    if (g_cache_count >= MAX_WINDOW_CACHE) return;
    g_cache[g_cache_count].wid = wid;
    g_cache[g_cache_count].el  = (AXUIElementRef)CFRetain(el);
    g_cache_count++;
}

bool ax_window_is_ordered_in(CGWindowID wid) {
    if (wid == 0) return false;
    bool ordered = false;
    CGError err = SLSWindowIsOrderedIn(CGSMainConnectionID(), wid, &ordered);
    bool result = err == kCGErrorSuccess && ordered;
    LOG("order", "wid=%u ordered_in=%d (err=%d)", wid, result, err);
    return result;
}

void ax_window_forget(CGWindowID wid) {
    for (int i = 0; i < g_cache_count; i++) {
        if (g_cache[i].wid != wid) continue;
        CFRelease(g_cache[i].el);
        g_cache[i] = g_cache[--g_cache_count];
        return;
    }
}

// Resolve (and cache) the AX window element for (pid, wid). Returns a
// non-retained reference owned by the cache, or NULL.
static AXUIElementRef resolve_window(pid_t pid, CGWindowID wid) {
    AXUIElementRef cached = cache_lookup(wid);
    if (cached) return cached;

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return NULL;

    CFArrayRef wins = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(w, &id) == kAXErrorSuccess && id == wid) {
                cache_store(wid, w);
                found = cache_lookup(wid);
                break;
            }
        }
        CFRelease(wins);
    }
    CFRelease(app);
    return found;
}

// --- Per-app tiling rules (on_window_detected) -----------------------------
#define MAX_WINDOW_RULES 64
typedef struct {
    char       app_id[256];
    WindowRule action;
} AppRule;
static AppRule g_rules[MAX_WINDOW_RULES];
static int     g_rule_count;

void ax_window_add_rule(const char *app_id, WindowRule action) {
    if (!app_id || g_rule_count >= MAX_WINDOW_RULES) return;
    snprintf(g_rules[g_rule_count].app_id, sizeof(g_rules[g_rule_count].app_id), "%s", app_id);
    g_rules[g_rule_count].action = action;
    g_rule_count++;
}

// Bundle id of the app owning `pid`, or nil.
static NSString *bundle_id_for_pid(pid_t pid) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app.bundleIdentifier;
}

static WindowRule rule_for_pid(pid_t pid) {
    NSString *bid = bundle_id_for_pid(pid);
    if (!bid) return WINDOW_RULE_NONE;
    for (int i = 0; i < g_rule_count; i++) {
        if ([bid isEqualToString:@(g_rules[i].app_id)]) return g_rules[i].action;
    }
    return WINDOW_RULE_NONE;
}

// Terminal apps are exempt from the no-fullscreen-button dialog heuristic: some
// have windows that lack the fullscreen button yet should still tile.
static bool is_terminal_app(pid_t pid) {
    static NSSet *terminals;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        terminals = [NSSet setWithArray:@[
            @"com.apple.Terminal", @"com.googlecode.iterm2",
            @"org.alacritty", @"io.alacritty",
            @"com.github.wez.wezterm", @"net.kovidgoyal.kitty",
            @"com.mitchellh.ghostty", @"dev.warp.Warp-Stable", @"co.zeit.hyper",
        ]];
    });
    NSString *bid = bundle_id_for_pid(pid);
    return bid && [terminals containsObject:bid];
}

// A window with a fullscreen button (the green title-bar button — distinct from
// the maximize/zoom button) is a real, tileable window. Its absence is a strong
// dialog signal.
static bool has_fullscreen_button(AXUIElementRef w) {
    CFTypeRef btn = NULL;
    bool has = AXUIElementCopyAttributeValue(w, CFSTR("AXFullScreenButton"), &btn) == kAXErrorSuccess && btn;
    if (btn) CFRelease(btn);
    return has;
}

bool ax_window_is_tileable(pid_t pid, CGWindowID wid) {
    if (!ax_window_is_top_level(wid)) {
        LOG("tile", "wid=%u NOT tileable: not top-level", wid);
        return false;
    }
    AXUIElementRef w = resolve_window(pid, wid);
    if (!w) {
        LOG("tile", "wid=%u NOT tileable: AX element unresolved (pid=%d)", wid, pid);
        return false;
    }

    // Mechanical requirement: agate must be able to move and resize it.
    Boolean posSettable = false, sizeSettable = false;
    AXUIElementIsAttributeSettable(w, kAXPositionAttribute, &posSettable);
    AXUIElementIsAttributeSettable(w, kAXSizeAttribute, &sizeSettable);
    if (!posSettable || !sizeSettable) {
        LOG("tile", "wid=%u NOT tileable: not movable/resizable (pos=%d size=%d)",
            wid, posSettable, sizeSettable);
        return false;
    }

    // Explicit per-app rules win over the heuristic.
    switch (rule_for_pid(pid)) {
        case WINDOW_RULE_FLOAT: LOG("tile", "wid=%u float: app rule", wid); return false;
        case WINDOW_RULE_TILE:  LOG("tile", "wid=%u tile: app rule", wid);  return true;
        case WINDOW_RULE_NONE:  break;
    }

    // Non-standard subroles (dialogs, sheets, floating panels) float.
    CFStringRef subrole = NULL;
    if (AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, (CFTypeRef *)&subrole) == kAXErrorSuccess && subrole) {
        bool standard = CFEqual(subrole, kAXStandardWindowSubrole);
        if (!standard && agate_log_enabled()) {
            char sb[64] = {0};
            CFStringGetCString(subrole, sb, sizeof(sb), kCFStringEncodingUTF8);
            LOG("tile", "wid=%u NOT tileable: subrole=%s (not standard)", wid, sb);
        }
        CFRelease(subrole);
        if (!standard) return false;
    }

    // Dialog heuristic: a standard window without a fullscreen button is treated
    // as a dialog and floated — unless it belongs to a terminal app.
    if (!is_terminal_app(pid) && !has_fullscreen_button(w)) {
        LOG("tile", "wid=%u NOT tileable: no fullscreen button (dialog heuristic)", wid);
        return false;
    }

    LOG("tile", "wid=%u tileable", wid);
    return true;
}

void ax_window_set_frame(pid_t pid, CGWindowID wid, CGRect frame) {
    AXUIElementRef w = resolve_window(pid, wid);
    if (!w) return;

    CGPoint origin = frame.origin;
    CGSize  size   = frame.size;
    AXValueRef posVal  = AXValueCreate(kAXValueCGPointType, &origin);
    AXValueRef sizeVal = AXValueCreate(kAXValueCGSizeType, &size);

    // Set size, then position, then size again: some apps clamp the position to
    // the old (smaller/larger) size on the first pass, and some clamp the size
    // to the old position; the second size pass settles both.
    AXUIElementSetAttributeValue(w, kAXSizeAttribute, sizeVal);
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, posVal);
    AXUIElementSetAttributeValue(w, kAXSizeAttribute, sizeVal);

    CFRelease(posVal);
    CFRelease(sizeVal);
}

bool ax_window_frame(pid_t pid, CGWindowID wid, CGRect *out) {
    AXUIElementRef w = resolve_window(pid, wid);
    if (!w) return false;

    CFTypeRef posv = NULL, sizev = NULL;
    CGPoint pos = {0};
    CGSize  size = {0};
    bool ok = false;
    if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &posv) == kAXErrorSuccess && posv &&
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sizev) == kAXErrorSuccess && sizev) {
        AXValueGetValue(posv, kAXValueCGPointType, &pos);
        AXValueGetValue(sizev, kAXValueCGSizeType, &size);
        *out = (CGRect){ pos, size };
        ok = true;
    }
    if (posv) CFRelease(posv);
    if (sizev) CFRelease(sizev);
    return ok;
}

void ax_window_raise_focus(pid_t pid, CGWindowID wid) {
    AXUIElementRef w = resolve_window(pid, wid);
    if (w) {
        AXUIElementPerformAction(w, kAXRaiseAction);
        AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
    }
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    [app activateWithOptions:NSApplicationActivateAllWindows];
}

bool ax_window_focused(pid_t *out_pid, CGWindowID *out_wid) {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front) return false;
    pid_t pid = (pid_t)front.processIdentifier;

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return false;

    AXUIElementRef win = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&win) != kAXErrorSuccess)
        win = NULL;
    if (!win) AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, (CFTypeRef *)&win);
    CFRelease(app);
    if (!win) return false;

    CGWindowID wid = 0;
    _AXUIElementGetWindow(win, &wid);
    CFRelease(win);
    if (wid == 0) return false;

    if (out_pid) *out_pid = pid;
    if (out_wid) *out_wid = wid;
    return true;
}
