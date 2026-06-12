// Diagnostic: can this process set window-server transforms, and what is the
// resting-transform convention? Reads a window's current transform and writes
// the SAME value back (visual no-op), on (a) a window we own and (b) a
// foreign window, via both the direct call and a transaction. Prints error
// codes. Build/run:
//   clang -fobjc-arc -F"$SDKROOT/System/Library/PrivateFrameworks" \
//     -framework AppKit -framework CoreGraphics -framework SkyLight \
//     tools/transform_probe.m -o /tmp/transform_probe && /tmp/transform_probe
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);

typedef CGError (*GetTransformFn)(CGSConnectionID, uint32_t, CGAffineTransform *);
typedef CGError (*SetTransformFn)(CGSConnectionID, uint32_t, CGAffineTransform);
typedef CFTypeRef (*TxnCreateFn)(CGSConnectionID);
typedef void (*TxnSetTransformFn)(CFTypeRef, uint32_t, int, int, CGAffineTransform);
typedef CGError (*TxnCommitFn)(CFTypeRef, int);

static void *sym(const char *a, const char *b) {
    void *p = dlsym(RTLD_DEFAULT, a);
    if (!p && b) p = dlsym(RTLD_DEFAULT, b);
    return p;
}

static void probe(const char *label, uint32_t wid, CGRect frame) {
    CGSConnectionID cid = CGSMainConnectionID();
    GetTransformFn get = (GetTransformFn)sym("SLSGetWindowTransform", "CGSGetWindowTransform");
    SetTransformFn set = (SetTransformFn)sym("SLSSetWindowTransform", "CGSSetWindowTransform");
    printf("== %s wid=%u frame=(%.0f,%.0f %.0fx%.0f)\n", label, wid,
           frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    if (!get || !set) { printf("  symbols: get=%p set=%p\n", get, set); return; }

    CGAffineTransform t = CGAffineTransformIdentity;
    CGError gerr = get(cid, wid, &t);
    printf("  get err=%d t=[a=%.3f b=%.3f c=%.3f d=%.3f tx=%.1f ty=%.1f]\n",
           gerr, t.a, t.b, t.c, t.d, t.tx, t.ty);
    if (gerr != kCGErrorSuccess) t = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);

    CGError serr = set(cid, wid, t);
    printf("  set(same) err=%d\n", serr);

    TxnCreateFn txc = (TxnCreateFn)sym("SLSTransactionCreate", NULL);
    TxnSetTransformFn txt = (TxnSetTransformFn)sym("SLSTransactionSetWindowTransform", NULL);
    TxnCommitFn txm = (TxnCommitFn)sym("SLSTransactionCommit", NULL);
    if (txc && txt && txm) {
        CFTypeRef txn = txc(cid);
        if (txn) {
            txt(txn, wid, 0, 0, t);
            CGError terr = txm(txn, 0);
            printf("  txn set(same)+commit err=%d\n", terr);
        } else {
            printf("  txn create returned NULL\n");
        }
    } else {
        printf("  txn symbols missing: create=%p set=%p commit=%p\n", txc, txt, txm);
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 280, 180)
                                                  styleMask:0
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [w orderFrontRegardless];
        // Give the server a beat to register the window.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        // Top-left global coords for the resting-transform comparison.
        NSScreen *primary = NSScreen.screens.firstObject;
        CGRect f = w.frame;
        f.origin.y = primary.frame.size.height - (f.origin.y + f.size.height);
        probe("own window", (uint32_t)w.windowNumber, f);

        // A foreign, layer-0, on-screen window.
        CFArrayRef list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        pid_t me = getpid();
        for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            if ([info[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
            if ([info[(__bridge NSString *)kCGWindowOwnerPID] intValue] == me) continue;
            CGRect fr;
            CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &fr);
            probe("foreign window", [info[(__bridge NSString *)kCGWindowNumber] unsignedIntValue], fr);
            break;
        }
        if (list) CFRelease(list);
    }
    return 0;
}
