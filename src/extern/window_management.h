// window_management.h — WindowManagement.framework private API (Tier 3).
//
// Reference declarations for the daemon-level tiling path described in
// skylight-snapping-report.md. Per the report, the XPC server
// (com.apple.windowmanager.server) only accepts registered WM clients
// (Dock.app, Finder, SystemUIServer); a normal process crashes on the response
// path. These are here for completeness — classes are instantiated via
// NSClassFromString(), not linked directly.
//
// Objective-C only.

#ifndef EXTERN_WINDOW_MANAGEMENT_H
#define EXTERN_WINDOW_MANAGEMENT_H

#if defined(__OBJC__)
#import <Foundation/Foundation.h>

// WMWindowTilingPosition (uint64_t). From NSStringFromWMWindowTilingPosition().
typedef NS_ENUM(uint64_t, WMWindowTilingPosition) {
    WMWindowTilingPositionUnknown      = 0,
    WMWindowTilingPositionTop          = 1,
    WMWindowTilingPositionLeft         = 2,
    WMWindowTilingPositionBottom       = 3,
    WMWindowTilingPositionRight        = 4,
    WMWindowTilingPositionCenter       = 5,
    WMWindowTilingPositionFill         = 6,
    WMWindowTilingPositionUntile       = 7,
    WMWindowTilingPositionTopLeft      = 8,
    WMWindowTilingPositionTopRight     = 9,
    WMWindowTilingPositionBottomLeft   = 10,
    WMWindowTilingPositionBottomRight  = 11,
    WMWindowTilingPositionLeftAndRight = 12,
    WMWindowTilingPositionRightAndLeft = 13,
    WMWindowTilingPositionTopAndBottom = 14,
    WMWindowTilingPositionBottomAndTop = 15,
    WMWindowTilingPositionQuarters     = 16,
    WMWindowTilingPositionRightQuarters = 17,
    WMWindowTilingPositionLeftThreeUp  = 18,
    WMWindowTilingPositionRightThreeUp = 19,
    WMWindowTilingPositionTopThreeUp   = 20,
    WMWindowTilingPositionBottomThreeUp = 21,
};

// Usage sketch (see report for the full transaction flow):
//
//   id info = [[NSClassFromString(@"_WMRequestTilingPositionActionInfo") alloc]
//                 initWithWindowID:@"26816"          // [NSWindow windowNumber] as string
//                   tilingPosition:WMWindowTilingPositionTopRight];
//   id action = [NSClassFromString(@"WMWindowTransactionAction")
//                   actionForRequestTilingPositionActionInfo:info fences:nil];
//   id tx = [[NSClassFromString(@"WMWindowTransaction") alloc] init];
//   [tx addAction:action];
//   id mgr = [[NSClassFromString(@"WMClientWindowManager") alloc] init];
//   [mgr performWindowTransaction:tx];   // crashes from an unregistered client

#endif // __OBJC__
#endif // EXTERN_WINDOW_MANAGEMENT_H
