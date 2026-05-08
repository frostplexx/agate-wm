// nswindow_spi.h — private NSWindow tiling/snapping SPI (AppKit).
//
// Tier 1 of skylight-snapping-report.md: the cleanest path to snap a window
// you OWN. No entitlements, no XPC. Objective-C only — include from a .m file.
// No extra link flags (AppKit selectors).
//
// _zoomToScreenEdge: takes an NSRectEdge:
//   NSRectEdgeMinX (0) = left,  NSRectEdgeMinY (1) = bottom,
//   NSRectEdgeMaxX (2) = right, NSRectEdgeMaxY (3) = top.

#ifndef EXTERN_NSWINDOW_SPI_H
#define EXTERN_NSWINDOW_SPI_H

#if defined(__OBJC__)
#import <AppKit/AppKit.h>

@interface NSWindow (PrivateTilingSPI)

// Snap / zoom
- (void)_zoomToScreenEdge:(NSRectEdge)edge;
- (CGRect)_divideFrameForEdge:(NSRectEdge)edge; // query target rect without moving
- (void)_tileLeft:(id)sender;
- (void)_tileRight:(id)sender;
- (void)_maximizeTileToFillScreen;
- (void)_changeWindowTileLocation:(id)sender;
- (void)_enterATUWithTileOnLeft:(BOOL)onLeft;
- (void)_doSnapToFrame;

// Tile-mode state / eligibility
- (BOOL)_canEnterTileMode;
- (BOOL)_canEnterTileModeForBehavior:(uint64_t)behavior;
- (BOOL)_allowsSnapping;
- (BOOL)_implicitlyTileable;
- (BOOL)_allowsSizeSnapping;
- (BOOL)_validateTile;
- (BOOL)_validateTileChange;
- (BOOL)_canBeSnappingTarget;
- (BOOL)_resizingShouldSnapToWindows;
- (uint64_t)_tileSpaceID;                 // 0 when the window is not in a tile space
- (uint64_t)_preferredPositionForTileJoin;

// Full-screen / tile-space frames
- (CGRect)_tileFrameForFullScreen;
- (CGRect)_fullScreenTileFrame;
- (void)_joinTiledFullScreenSpace:(uint64_t)spaceID usingPosition:(uint64_t)position;
- (void)_createSiblingTileForWindow:(id)window
                  preferredPositions:(id)positions
                     responseHandler:(void (^)(id response))handler;
- (void)_enterFullScreenModeOnTileSpaceWithName:(NSString *)name;
- (void)_enterFullScreenModeOnTileSpaceWithName:(NSString *)name takeOwnership:(BOOL)takeOwnership;

// Preferred tile sizing
- (void)_setTileMinSize:(CGSize)minSize tileMaxSize:(CGSize)maxSize tilePreferredSize:(CGSize)preferred;
- (CGSize)_tilePreferredSize;
- (void)_saveTilePreferredSize;

// Size-snap during resize
- (void)_attemptToSnapWindowSizeWithEvent:(NSEvent *)event;
- (BOOL)_snapWindowSizeInDirection:(int64_t)direction withEvent:(NSEvent *)event;

// Unsnapped (pre-tile) frame bookkeeping
- (CGRect)unsnappedFrame;
- (void)setUnsnappedFrame:(CGRect)frame;

@end

#endif // __OBJC__
#endif // EXTERN_NSWINDOW_SPI_H
