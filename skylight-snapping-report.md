# macOS Private Window Snapping API Research

**Host:** macOS 26.5 (25F71) · arm64e · SIP enabled  
**Frameworks:** SkyLight, WindowManagement (AppKit)  
**Method:** TBD symbol extraction + live `dlopen`/`class_copyMethodList` runtime probing  
**Date:** 2026-06-02

---

## What "native tiling" actually means

The feature controlled by "Drag windows to left or right edge of screen to tile" works through this pipeline:

```
User drags window to edge
      ↓
SkyLight detects hover via SLSSnappingInfo* (window server)
      ↓
WindowManager daemon calls SLSSpaceCreateTile → creates a SkyLight tile space
      ↓  XPC: com.apple.windowmanager.server
WMClientWindowManager delivers _WMRestoreTilingStateActionInfo to the window's owner process
      ↓
Owner process resizes window to fit; NSWindow._tileSpaceID becomes non-zero
      ↓
System knows windows are tiled: margins, live divider, coordinated resize all active
```

**What AX-based tools (Rectangle, Magnet, Moom) do** — and what this CLI does — is jump straight to step 5: resize the window frame directly via `AXUIElement`. No tile space is created, `_tileSpaceID` stays 0, "Tiled windows have margins" is ignored, and there is no live divider. The system never sees these windows as tiled.

**What blocks the full pipeline from a CLI:**  
Step 3 requires the calling process to be a registered WM client (Dock.app, Finder, SystemUIServer). `WMClientWindowManager` tries to establish a `BSXPCServiceConnectionProxy` for `WMXPCClientInterface` on the calling process, which crashes unless the process is properly bootstrapped as a WM client with the protocol's exported object configured. `SLSBridgedSpaceCreateTileOperation` and related bridged symbols are only available inside the WindowManager daemon, not in SkyLight.framework.

**The only way to trigger native tiling for a window in another process** without daemon-level registration is to press the "Tile Window to Left/Right of Screen" menu item via `AXUIElementPerformAction`, which runs `_tileLeft:`/`_tileRight:` inside the target app's own process. This requires the app to be front and results in an interactive window-picker for the paired window — it is not suitable for batch layout.

---

## Summary

macOS exposes three layers of private API for programmatic window snapping/tiling, each with different capabilities and access requirements:

| Tier | API surface | Works from CLI | Corner snap | Requires entitlement |
|---|---|---|---|---|
| 1 | `NSWindow` SPI | Own windows only | No (manual calc) | No |
| 2 | SkyLight C SPI | Via CGSConnection | Yes (via WM tiling) | No (for snap info) |
| 3 | WindowManagement XPC | No (process must be registered WM client) | Yes | Yes (implicitly) |

---

## Tier 1 — NSWindow SPI

### `-[NSWindow _zoomToScreenEdge:(NSRectEdge)edge]`

**Verified working on macOS 26.5.** The cleanest path for snapping a window you own. No entitlements, no XPC, no sandbox issues. Maps directly onto `NSRectEdge`.

```objc
// Edge constants (NSRectEdge)
// 0 = NSRectEdgeMinX → left half
// 1 = NSRectEdgeMinY → bottom half
// 2 = NSRectEdgeMaxX → right half
// 3 = NSRectEdgeMaxY → top half

[window _zoomToScreenEdge:0]; // snap left
[window _zoomToScreenEdge:2]; // snap right
```

```swift
// Swift — unsafe direct IMP call
typealias ZoomEdgeFn = @convention(c) (NSWindow, Selector, UInt64) -> Void
let sel = NSSelectorFromString("_zoomToScreenEdge:")
let fn  = unsafeBitCast(class_getMethodImplementation(NSWindow.self, sel)!, to: ZoomEdgeFn.self)
fn(window, sel, 2)   // 2 = right half
```

**Live-measured frames on a 2560×1080 display** (visible frame 2560×1050):

| Edge value | Name | Frame |
|---|---|---|
| 0 | left | `(0, 0, 1280, 1050)` |
| 1 | bottom | `(0, 0, 2560, 525)` |
| 2 | right | `(1280, 0, 1280, 1050)` |
| 3 | top | `(0, 525, 2560, 525)` |

### `-[NSWindow _divideFrameForEdge:(NSRectEdge)edge] → CGRect`

Read-only query — returns the frame the window *would* snap to without moving it. Useful for implementing preview overlays.

```objc
CGRect proposed = [window _divideFrameForEdge:2]; // query right-half rect
```

### Guard checks

```objc
BOOL canTile     = [window _canEnterTileMode];       // eligible for Sequoia tiling
BOOL allowsSnap  = [window _allowsSnapping];         // snapping enabled
BOOL implicit    = [window _implicitlyTileable];     // eligible without explicit opt-in
BOOL sizeSnap    = [window _allowsSizeSnapping];     // size-snap on resize enabled
```

### Full inventory of NSWindow tiling SPI

```
-[NSWindow _tileLeft:(id)sender]
-[NSWindow _tileRight:(id)sender]
-[NSWindow _maximizeTileToFillScreen]
-[NSWindow _changeWindowTileLocation:(id)]
-[NSWindow _enterATUWithTileOnLeft:(BOOL)]
-[NSWindow _tileSpaceID]  → UInt64                    (0 if not in a tile space)
-[NSWindow _tileFrameForFullScreen]  → CGRect
-[NSWindow _fullScreenTileFrame]  → CGRect
-[NSWindow _preferredPositionForTileJoin]  → UInt64
-[NSWindow _canEnterTileModeForBehavior:(UInt64)]
-[NSWindow _joinTiledFullScreenSpace:(UInt64)spaceID usingPosition:(UInt64)pos]
-[NSWindow _createSiblingTileForWindow:preferredPositions:responseHandler:]
-[NSWindow _enterFullScreenModeOnTileSpaceWithName:(NSString*)]
-[NSWindow _enterFullScreenModeOnTileSpaceWithName:takeOwnership:]
-[NSWindow _validateTile]  → BOOL
-[NSWindow _validateTileChange]  → BOOL
-[NSWindow _setTileMinSize:tileMaxSize:tilePreferredSize:]
-[NSWindow _tilePreferredSize]  → CGSize
-[NSWindow _saveTilePreferredSize]
-[NSWindow setUnsnappedFrame:(CGRect)]
-[NSWindow unsnappedFrame]  → CGRect
-[NSWindow _doSnapToFrame]
-[NSWindow _attemptToSnapWindowSizeWithEvent:]
-[NSWindow _snapWindowSizeInDirection:(Int64)direction withEvent:]  → BOOL
-[NSWindow _resizingShouldSnapToWindows]  → BOOL
-[NSWindow _canBeSnappingTarget]  → BOOL
```

### Corner / quarter snapping

`_zoomToScreenEdge:` only supports the 4 half-screen positions (values 0–3; higher values are no-ops). For corners, compute the frame manually:

```swift
let screen = NSScreen.main!.visibleFrame
let half   = CGSize(width: screen.width / 2, height: screen.height / 2)

let frames: [String: CGRect] = [
    "topLeft":     CGRect(origin: CGPoint(x: screen.minX, y: screen.midY), size: half),
    "topRight":    CGRect(origin: CGPoint(x: screen.midX, y: screen.midY), size: half),
    "bottomLeft":  CGRect(origin: CGPoint(x: screen.minX, y: screen.minY), size: half),
    "bottomRight": CGRect(origin: CGPoint(x: screen.midX, y: screen.minY), size: half),
]
window.setFrame(frames["topRight"]!, display: true, animate: true)
```

---

## Tier 2 — SkyLight C SPI

Framework: `/System/Library/PrivateFrameworks/SkyLight.framework`

### Snap detection during drag

These functions implement the drag-hover snap-zone detection the system uses internally. Feed synthetic movement to query whether a given drag position would trigger snapping and what rect it would snap to.

```c
typedef void*    SLSSnappingInfoRef;
typedef uint32_t SLSConnectionID;  // from CGSMainConnectionID()

SLSSnappingInfoRef SLSSnappingInfoCreate(SLSConnectionID cid, CGWindowID wid);
void  SLSSnappingInfoRelease(SLSSnappingInfoRef ref);
void  SLSSnappingInfoSetPrefs(SLSSnappingInfoRef ref, CFDictionaryRef prefs);
void  SLSSnappingInfoSetIsForResizing(SLSSnappingInfoRef ref, bool resizing);
void  SLSSnappingInfoSetSnappedEdges(SLSSnappingInfoRef ref, uint32_t edges);
void  SLSSnappingInfoAddMovement(SLSSnappingInfoRef ref, CGPoint pt, CGVector vel);
void  SLSSnappingInfoResetMovement(SLSSnappingInfoRef ref);

// Query snap state
uint32_t SLSSnappingInfoGetCurrentSnappedEdgesForRect(SLSSnappingInfoRef ref, CGRect frame);
uint32_t SLSSnappingInfoGetSnappedEdges(SLSSnappingInfoRef ref);
CGRect   SLSSnappingInfoGetLastSnappedRect(SLSSnappingInfoRef ref);
CGRect   SLSSnappingInfoGetSizeSnapRectForFrame(SLSSnappingInfoRef ref, CGRect frame);
CGPoint  SLSSnappingInfoSnapOriginWithFrame(SLSSnappingInfoRef ref, CGPoint origin, CGRect frame);
CGRect   SLSSnappingInfoSnapFrameForResizing(SLSSnappingInfoRef ref, CGRect frame);
CGVector SLSSnappingInfoGetCurrentVelocity(SLSSnappingInfoRef ref);
void     SLSSnappingInfoEnumerateSnappingRects(SLSSnappingInfoRef ref,
                                               void (^handler)(CGRect rect));
```

### Native tile space management (Sequoia split-screen with live divider)

These are the lowest-level functions backing the native tiling UI — the same ones called when you drag a window to a screen edge in macOS Sequoia/26.

```c
// Prerequisites
bool     SLSSpaceCanCreateTile(uint64_t spaceID);

// Create / enumerate tile spaces
uint64_t  SLSSpaceCreateTile(SLSConnectionID cid, uint64_t spaceID,
                              CGWindowID wid, uint32_t position);
CFArrayRef SLSSpaceCopyTileSpaces(SLSConnectionID cid, uint64_t spaceID);

// Take ownership and configure divider
void     SLSTileSpaceTakeOwnership(SLSConnectionID cid, uint64_t tileSpaceID);
void     SLSTileSpaceSetDividerWindow(SLSConnectionID cid, uint64_t spaceID,
                                      CGWindowID dividerWindowID);

// Resize / layout
CGRect   SLSWindowGetTileRect(SLSConnectionID cid, CGWindowID wid);
CGSize   SLSSpaceGetSizeForProposedTile(SLSConnectionID cid, uint64_t spaceID);
void     SLSTileSpaceMoveSpacersForSize(SLSConnectionID cid, uint64_t spaceID, CGSize size);
void     SLSTileSpaceMoveSpacersForSizeFenced(SLSConnectionID cid, uint64_t spaceID, CGSize size);
void     SLSSpaceFinishedResizeForRect(SLSConnectionID cid, uint64_t spaceID, CGRect rect);
uint32_t SLSGetTileSpaceDividerDirections(SLSConnectionID cid, uint64_t spaceID);
void     SLSSpaceSetInterTileSpacing(SLSConnectionID cid, uint64_t spaceID, CGFloat spacing);
CGFloat  SLSSpaceGetInterTileSpacing(SLSConnectionID cid, uint64_t spaceID);

// Record types returned by tile-resize notifications
CGWindowID SLSTileEvictionRecordGetTileID(CFTypeRef record);
uint64_t   SLSTileEvictionRecordGetManagedSpaceID(CFTypeRef record);
CGWindowID SLSTileOwnerChangeRecordGetTileID(CFTypeRef record);
pid_t      SLSTileOwnerChangeRecordGetNewOwner(CFTypeRef record);
pid_t      SLSTileOwnerChangeRecordGetOldOwner(CFTypeRef record);
uint64_t   SLSTileOwnerChangeRecordGetManagedSpaceID(CFTypeRef record);
uint64_t   SLSTileSpaceResizeRecordGetSpaceID(CFTypeRef record);
uint64_t   SLSTileSpaceResizeRecordGetParentSpaceID(CFTypeRef record);
bool       SLSTileSpaceResizeRecordIsLiveResizing(CFTypeRef record);

// Per-window snapping opt-out property keys
extern CFStringRef _SLWindowDisallowSnappingKey;        // disable snap for this window
extern CFStringRef _SLWindowDisallowSnappingTargetKey;  // prevent others snapping to this window

// Coordinated resize notification
extern CFStringRef _kSLSCoordinatedTileResizeNotificationName;
```

`SLSConnectionID` is obtained from `CGSMainConnectionID()` — declare it as `extern uint32_t CGSMainConnectionID(void)` and link against `CoreGraphics.framework`.

---

## Tier 3 — WindowManagement XPC (daemon / orchestrator role)

Framework: `/System/Library/PrivateFrameworks/WindowManagement.framework`  
XPC service: `com.apple.windowmanager.server`  
BS domain: `com.apple.windowmanager`

> **Access note:** `WMClientWindowManager` connects to `com.apple.windowmanager.server` via BoardServices XPC. The server validates the client via the process's BSServiceConnectionEndpoint. Regular processes crash on the XPC response path because the server sends back protocol messages the unregistered client cannot decode. Dock.app, Finder, and SystemUIServer are the intended clients.

### `WMWindowTilingPosition` enum

Obtained via live call to `NSStringFromWMWindowTilingPosition()`:

```
 0 = unknown       8 = topLeft       16 = quarters
 1 = top           9 = topRight      17 = rightQuarters
 2 = left         10 = bottomLeft    18 = leftThreeUp
 3 = bottom       11 = bottomRight   19 = rightThreeUp
 4 = right        12 = leftAndRight  20 = topThreeUp
 5 = center       13 = rightAndLeft  21 = bottomThreeUp
 6 = fill         14 = topAndBottom
 7 = untile       15 = bottomAndTop
```

### Key classes and their verified methods

#### `_WMRequestTilingPositionActionInfo` — request the WM server to tile a window

```objc
// Instantiate
_WMRequestTilingPositionActionInfo *info =
    [[NSClassFromString(@"_WMRequestTilingPositionActionInfo") alloc]
        initWithWindowID:@"26816"   // NSString of [NSWindow windowNumber]
        tilingPosition:9];          // WMWindowTilingPosition (uint64_t), 9 = topRight

// Ivars: _windowID (NSString), _tilingPosition (uint64_t Q)
```

#### `_WMWindowTilingState` — snapshot of a window's current tiling state

```objc
_WMWindowTilingState *state =
    [[NSClassFromString(@"_WMWindowTilingState") alloc]
        initWithTilingPosition:4        // int64_t
        untiledFrame:window.frame       // CGRect — frame before tiling
        normalizedSize:0.5];            // CGFloat — fraction of screen occupied

// Additional accessors:
// -tilingPosition → int64_t
// -untiledFrame   → CGRect
// -normalizedSize → CGFloat
// -propertyListValue / -initWithPropertyListValue: (for serialisation)
```

#### `_WMRestoreTilingStateActionInfo` — tell the WM this window IS tiled (owner-side)

```objc
_WMRestoreTilingStateActionInfo *info =
    [[NSClassFromString(@"_WMRestoreTilingStateActionInfo") alloc]
        initWithWindowID:@"26816"
        tilingState:state
        useVisibilityBasedFencing:NO];

// initWithRequestID:windowID:tilingState:useVisibilityBasedFencing: — server-assigned request ID variant
```

#### `WMWindowTransactionAction` — wrapper that gets sent over XPC

```objc
// Request path (sent by orchestrator to WM server):
WMWindowTransactionAction *action =
    [NSClassFromString(@"WMWindowTransactionAction")
        actionForRequestTilingPositionActionInfo:info fences:nil];

// Restore path (sent by window owner to WM server):
WMWindowTransactionAction *action =
    [NSClassFromString(@"WMWindowTransactionAction")
        actionForRestoreTilingStateActionInfo:info fences:nil];
```

Other factory methods on `WMWindowTransactionAction`:
```
+actionForCreatingWindow:fences:
+actionForDestroyingWindow:fences:
+actionForUpdatingWindow:updatedProperties:fences:
+actionForOrderingWindowWithInfo:fences:
+actionForOrderingAllWindowsFrontWithFences:
+actionForMiniaturizingWindows:fences:
+actionForDeminiaturizingWindows:fences:
+actionForDidEnterFullscreen:fences:
+actionForDidExitFullscreen:toSpace:fences:
+actionForAssignToSpacesActionInfo:fences:
+actionForResetSpacesForWindows:fences:
+actionForProposingKeyWindowWithInfo:fences:
+actionForCyclingWindowsForwardWithFences:
+actionForHidingApplicationWithFences:
+actionForUnhidingApplicationWithFences:
```

#### `WMWindowTransaction` + `WMClientWindowManager` — transport

```objc
WMWindowTransaction *tx = [[NSClassFromString(@"WMWindowTransaction") alloc] init];
[tx addAction:action];

WMClientWindowManager *mgr = [[NSClassFromString(@"WMClientWindowManager") alloc] init];
[mgr performWindowTransaction:tx];  // synchronous
// [mgr sendWindowTransaction:tx];  // asynchronous
// [mgr prepareWindowTransaction:tx]; // prepare only
```

`WMClientWindowManager` also exposes callbacks for responding to server-driven resize/tiling:
```
-handleRestoreTilingStateActionResponse:
-performResizeWindowRequest:
-applyAgentPropertySnapshots:
-makeKeyWindowWithWindowIdentifier:
-windowMiniaturizationResponse:
-windowDeminiaturizationResponse:
```

---

## Decision guide

```
Do you own the window?
├── YES → use -[NSWindow _zoomToScreenEdge:] (Tier 1)
│         For corners: setFrame:display:animate: with manually computed quarter rect
│
└── NO  → Do you need the native Sequoia tile divider UI?
          ├── YES → SLSSpaceCreateTile / SLSTileSpaceTakeOwnership (Tier 2)
          │         Requires CGSMainConnectionID() and window server access
          │
          └── NO  → Use Accessibility API (AXUIElement) to set position + size
                    For programmatic layout tools this is the practical path
                    WMClientWindowManager (Tier 3) is for system daemons only
```

---

## Key constants

```c
// CFStringRef keys for per-window snapping behaviour (set via CGSWindow properties)
_SLWindowDisallowSnappingKey          // set to kCFBooleanTrue to opt this window out
_SLWindowDisallowSnappingTargetKey    // prevent other windows from snapping to this one

// CFNotificationCenter name
_kSLSCoordinatedTileResizeNotificationName   // posted when a tiled pair is live-resized
```
