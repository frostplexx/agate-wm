// skylight.h — SkyLight.framework / CoreGraphicsServices private C SPI.
//
// Tier 2 of skylight-snapping-report.md: window-server snap detection and
// native (Sequoia) tile-space management.
//
// Link: -F /System/Library/PrivateFrameworks -framework SkyLight
// The connection id (SLSConnectionID) comes from CGSMainConnectionID(), which
// resolves via CoreGraphics.

#ifndef EXTERN_SKYLIGHT_H
#define EXTERN_SKYLIGHT_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t SLSConnectionID;
typedef void    *SLSSnappingInfoRef;

// Window-server connection for this process.
extern SLSConnectionID CGSMainConnectionID(void);

// --- Window enumeration / iteration ----------------------------------------
// The window server's own window query — the robust way (used by yabai) to
// enumerate real windows and read their parent id, level, tags and attributes
// WITHOUT going through Accessibility. Key for the windows-vs-tabs/sheets
// problem: AX reports tab siblings and sheets as separate windows, but a
// SkyLight query gives you the parent id and attribute flags to tell them
// apart. Pair with CGWindowList (which only reports the rendered tab) and the
// AXTabbedWindows attribute for tab-group heads.
//
// All spaces, across every display — the way to reach windows that aren't on
// the current Mission Control space (CGWindowList's on-screen list can't).
// Returns an array of per-display dictionaries; each has a "Spaces" array of
// space dictionaries keyed by "id64" (int64 space id), "ManagedSpaceID", and
// "type". Feed those space ids to SLSCopyWindowsWithOptionsAndTags.
extern CFArrayRef SLSCopyManagedDisplaySpaces(SLSConnectionID cid);

// Window ids in the given spaces. `owner` 0 = any process; `options` 0x2 is the
// usual "all windows in these spaces"; `setTags`/`clearTags` may point to 0.
// Returns a CFArray of CFNumber window ids.
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(SLSConnectionID cid, uint32_t owner,
                                                   CFArrayRef spaces, uint32_t options,
                                                   uint64_t *setTags, uint64_t *clearTags);

// Build a query over an array of CGWindowIDs, then iterate the result.
extern CFTypeRef SLSWindowQueryWindows(SLSConnectionID cid, CFArrayRef windows, int count);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef windowQuery);

extern int      SLSWindowIteratorGetCount(CFTypeRef iterator);
extern bool     SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator); // 0 for top-level windows
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern int      SLSWindowIteratorGetLevel(CFTypeRef iterator);

// --- Snap-zone detection during a drag -------------------------------------
// Feed synthetic movement to ask whether a drag position would snap, and to
// what rect — the same machinery the system uses for edge tiling.
extern SLSSnappingInfoRef SLSSnappingInfoCreate(SLSConnectionID cid, CGWindowID wid);
extern void     SLSSnappingInfoRelease(SLSSnappingInfoRef ref);
extern void     SLSSnappingInfoSetPrefs(SLSSnappingInfoRef ref, CFDictionaryRef prefs);
extern void     SLSSnappingInfoSetIsForResizing(SLSSnappingInfoRef ref, bool resizing);
extern void     SLSSnappingInfoSetSnappedEdges(SLSSnappingInfoRef ref, uint32_t edges);
extern void     SLSSnappingInfoAddMovement(SLSSnappingInfoRef ref, CGPoint pt, CGVector vel);
extern void     SLSSnappingInfoResetMovement(SLSSnappingInfoRef ref);

extern uint32_t SLSSnappingInfoGetCurrentSnappedEdgesForRect(SLSSnappingInfoRef ref, CGRect frame);
extern uint32_t SLSSnappingInfoGetSnappedEdges(SLSSnappingInfoRef ref);
extern CGRect   SLSSnappingInfoGetLastSnappedRect(SLSSnappingInfoRef ref);
extern CGRect   SLSSnappingInfoGetSizeSnapRectForFrame(SLSSnappingInfoRef ref, CGRect frame);
extern CGPoint  SLSSnappingInfoSnapOriginWithFrame(SLSSnappingInfoRef ref, CGPoint origin, CGRect frame);
extern CGRect   SLSSnappingInfoSnapFrameForResizing(SLSSnappingInfoRef ref, CGRect frame);
extern CGVector SLSSnappingInfoGetCurrentVelocity(SLSSnappingInfoRef ref);
extern void     SLSSnappingInfoEnumerateSnappingRects(SLSSnappingInfoRef ref,
                                                      void (^handler)(CGRect rect));

// --- Native tile spaces (Sequoia split-screen with live divider) -----------
// Backing functions for the native tiling UI. NOTE (per report): producing a
// usable tiled state generally requires running as a registered WindowManager
// client; from a normal process these create the space but it won't behave.
extern bool       SLSSpaceCanCreateTile(uint64_t spaceID);
extern uint64_t   SLSSpaceCreateTile(SLSConnectionID cid, uint64_t spaceID, CGWindowID wid,
                                     uint32_t position);
extern CFArrayRef SLSSpaceCopyTileSpaces(SLSConnectionID cid, uint64_t spaceID);

extern void     SLSTileSpaceTakeOwnership(SLSConnectionID cid, uint64_t tileSpaceID);
extern void     SLSTileSpaceSetDividerWindow(SLSConnectionID cid, uint64_t spaceID,
                                             CGWindowID dividerWindowID);

extern CGRect   SLSWindowGetTileRect(SLSConnectionID cid, CGWindowID wid);
extern CGSize   SLSSpaceGetSizeForProposedTile(SLSConnectionID cid, uint64_t spaceID);
extern void     SLSTileSpaceMoveSpacersForSize(SLSConnectionID cid, uint64_t spaceID, CGSize size);
extern void     SLSTileSpaceMoveSpacersForSizeFenced(SLSConnectionID cid, uint64_t spaceID, CGSize size);
extern void     SLSSpaceFinishedResizeForRect(SLSConnectionID cid, uint64_t spaceID, CGRect rect);
extern uint32_t SLSGetTileSpaceDividerDirections(SLSConnectionID cid, uint64_t spaceID);
extern void     SLSSpaceSetInterTileSpacing(SLSConnectionID cid, uint64_t spaceID, CGFloat spacing);
extern CGFloat  SLSSpaceGetInterTileSpacing(SLSConnectionID cid, uint64_t spaceID);

// --- Record accessors for tile-resize notifications ------------------------
extern CGWindowID SLSTileEvictionRecordGetTileID(CFTypeRef record);
extern uint64_t   SLSTileEvictionRecordGetManagedSpaceID(CFTypeRef record);
extern CGWindowID SLSTileOwnerChangeRecordGetTileID(CFTypeRef record);
extern pid_t      SLSTileOwnerChangeRecordGetNewOwner(CFTypeRef record);
extern pid_t      SLSTileOwnerChangeRecordGetOldOwner(CFTypeRef record);
extern uint64_t   SLSTileOwnerChangeRecordGetManagedSpaceID(CFTypeRef record);
extern uint64_t   SLSTileSpaceResizeRecordGetSpaceID(CFTypeRef record);
extern uint64_t   SLSTileSpaceResizeRecordGetParentSpaceID(CFTypeRef record);
extern bool       SLSTileSpaceResizeRecordIsLiveResizing(CFTypeRef record);

// --- Constants -------------------------------------------------------------
// Per-window snapping opt-out keys (set via CGSWindow properties).
extern CFStringRef _SLWindowDisallowSnappingKey;       // opt this window out of snapping
extern CFStringRef _SLWindowDisallowSnappingTargetKey; // stop others snapping to this window
// Posted when a tiled pair is live-resized.
extern CFStringRef _kSLSCoordinatedTileResizeNotificationName;

#ifdef __cplusplus
}
#endif

#endif // EXTERN_SKYLIGHT_H
