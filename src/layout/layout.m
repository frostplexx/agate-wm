#import "layout.h"
#import "../extern/skylight.h"
#import "../window/ax_window.h"

#import <AppKit/AppKit.h>

LayoutGaps g_layout_gaps = { .inner = 8, .outer = 8 };

// UUID string of the display that owns space `sid`, or nil.
static NSString *display_uuid_for_space(uint64_t sid) {
    SLSConnectionID cid = CGSMainConnectionID();
    CFArrayRef disp = SLSCopyManagedDisplaySpaces(cid);
    if (!disp) return nil;

    NSString *uuid = nil;
    for (CFIndex d = 0; d < CFArrayGetCount(disp) && !uuid; d++) {
        NSDictionary *dd = (__bridge NSDictionary *)CFArrayGetValueAtIndex(disp, d);
        for (NSDictionary *s in dd[@"Spaces"]) {
            uint64_t x = [s[@"ManagedSpaceID"] unsignedLongLongValue] ?: [s[@"id64"] unsignedLongLongValue];
            if (x == sid) { uuid = dd[@"Display Identifier"]; break; }
        }
    }
    if (uuid) uuid = [uuid copy]; // outlive the CFRelease below
    CFRelease(disp);
    return uuid;
}

// NSScreen whose CGDirectDisplayID matches the display with UUID `uuid`.
static NSScreen *screen_for_uuid(NSString *uuid) {
    if (!uuid) return nil;
    CGDirectDisplayID ids[16]; uint32_t n = 0;
    if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess) return nil;

    CGDirectDisplayID match = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++) {
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if (!u) continue;
        CFStringRef str = CFUUIDCreateString(NULL, u);
        if (str && [uuid isEqualToString:(__bridge NSString *)str]) match = ids[i];
        if (str) CFRelease(str);
        CFRelease(u);
        if (match != kCGNullDirectDisplay) break;
    }
    if (match == kCGNullDirectDisplay) return nil;

    for (NSScreen *scr in NSScreen.screens) {
        if ([scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == match) return scr;
    }
    return nil;
}

CGRect layout_usable_rect(uint64_t sid) {
    NSScreen *screen = screen_for_uuid(display_uuid_for_space(sid));
    if (!screen) screen = NSScreen.mainScreen;
    if (!screen) return CGRectNull;

    // visibleFrame excludes the menu bar and Dock, but is in bottom-left global
    // coordinates. Flip to the top-left AX/CG space used everywhere else,
    // relative to the primary (menu-bar) screen's height.
    CGFloat primaryH = NSScreen.screens.firstObject.frame.size.height;
    NSRect vf = screen.visibleFrame;
    CGRect r = CGRectMake(vf.origin.x,
                          primaryH - (vf.origin.y + vf.size.height),
                          vf.size.width, vf.size.height);

    return CGRectInset(r, g_layout_gaps.outer, g_layout_gaps.outer);
}

void layout_apply(Node *root, CGRect rect) {
    if (!root || CGRectIsNull(rect)) return;

    root->frame = rect; // remembered for interactive resize weight recompute

    if (root->type == NODE_WINDOW) {
        ax_window_set_frame(root->pid, root->wid, rect);
        return;
    }
    if (root->child_count == 0) return;

    bool horizontal = layout_is_horizontal(root->layout);
    int  gap        = g_layout_gaps.inner;

    double total_weight = 0;
    for (size_t i = 0; i < root->child_count; i++) total_weight += root->children[i]->weight;
    if (total_weight <= 0) total_weight = (double)root->child_count;

    // Distribute the axis length minus the gaps between children.
    double axis      = horizontal ? rect.size.width : rect.size.height;
    double available = axis - gap * (double)(root->child_count - 1);
    if (available < 0) available = 0;

    double offset = horizontal ? rect.origin.x : rect.origin.y;
    for (size_t i = 0; i < root->child_count; i++) {
        Node  *child = root->children[i];
        double len   = available * (child->weight / total_weight);

        CGRect childRect = horizontal
            ? CGRectMake(offset, rect.origin.y, len, rect.size.height)
            : CGRectMake(rect.origin.x, offset, rect.size.width, len);

        layout_apply(child, childRect);
        offset += len + gap;
    }
}
