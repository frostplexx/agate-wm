//! SkyLight.framework / CoreGraphicsServices (CGS) private C SPI.
//!
//! These symbols aren't in any public SDK header, so — exactly like `ax.zig`
//! and `cg.zig` — they're hand-declared `extern`. The build links the private
//! `SkyLight` framework (the SDK ships a `SkyLight.tbd` stub under
//! PrivateFrameworks) plus CoreGraphics, which between them export every symbol
//! below. CF/CG value types are reused from the `@cImport` in `c.zig`.
//!
//! This is the window-server-level path used (à la yabai) to: read the active
//! space across displays, enumerate real windows on *any* space without
//! Accessibility, distinguish windows from tabs/sheets via parent ids, detect
//! native snap zones during a drag, and drive Sequoia tile spaces.
//!
//! Caveat: private symbols can change or vanish between macOS releases. Because
//! `extern` symbols are only resolved by the linker when referenced, declaring
//! one that doesn't exist on a given OS is harmless until you call it. If you'd
//! rather fail soft at runtime, resolve them with `std.c.dlsym` instead.
const c = @import("c.zig").c;
const cg = @import("cg.zig");

pub const ConnectionID = u32;
pub const SnappingInfoRef = ?*anyopaque;
pub const WindowID = cg.WindowID;

/// `CGError`; `<CoreGraphics/CGError.h>` isn't in our `@cImport`, so define the
/// one value we check. Non-zero is a failure.
pub const CGError = c_int;
pub const kCGErrorSuccess: CGError = 0;

/// Window-server connection for this process. Resolves via CoreGraphics.
pub extern fn CGSMainConnectionID() ConnectionID;

// --- Active space identity --------------------------------------------------

/// UUID of the display owning the active menu bar (the focused display). Caller
/// owns the returned CFString.
pub extern fn SLSCopyActiveMenuBarDisplayIdentifier(cid: ConnectionID) c.CFStringRef;
/// Current space id for the display with the given UUID.
pub extern fn SLSManagedDisplayGetCurrentSpace(cid: ConnectionID, uuid: c.CFStringRef) u64;
/// Switch the active Space on the given display to `space_id` directly. NOTE:
/// this bypasses Dock.app (which owns Mission Control and the menu bar), so it
/// leaves the menu bar stale — overlapping menus from multiple Spaces. We no
/// longer switch this way; space switching is done via a synthetic Dock-swipe
/// gesture (`event_tap.performSwitchGesture`), which drives Dock's own
/// transition. Kept here for reference / read parity with the getter above.
pub extern fn SLSManagedDisplaySetCurrentSpace(cid: ConnectionID, uuid: c.CFStringRef, space_id: u64) void;

// --- Window enumeration / iteration ----------------------------------------

/// All spaces across every display: an array of per-display dictionaries, each
/// with a "Spaces" array of space dicts keyed by "id64", "ManagedSpaceID",
/// "type". Caller owns the result.
pub extern fn SLSCopyManagedDisplaySpaces(cid: ConnectionID) c.CFArrayRef;

/// Window ids in the given spaces. `owner` 0 = any process; `options` 0x2 is
/// the usual "all windows in these spaces"; `set_tags`/`clear_tags` may be null.
/// Returns a CFArray of CFNumber window ids. Caller owns the result.
pub extern fn SLSCopyWindowsWithOptionsAndTags(
    cid: ConnectionID,
    owner: u32,
    spaces: c.CFArrayRef,
    options: u32,
    set_tags: ?*u64,
    clear_tags: ?*u64,
) c.CFArrayRef;

/// The managed-space ids a set of windows belong to. `mask` is a space-selector
/// bitmask; 0xFFFF_FFFF_FFFF_FFFF means "all spaces". Caller owns the result.
pub extern fn SLSCopySpacesForWindows(cid: ConnectionID, mask: u64, windows: c.CFArrayRef) c.CFArrayRef;

/// Build a query over an array of window ids, then iterate the result.
pub extern fn SLSWindowQueryWindows(cid: ConnectionID, windows: c.CFArrayRef, count: c_int) c.CFTypeRef;
pub extern fn SLSWindowQueryResultCopyWindows(window_query: c.CFTypeRef) c.CFTypeRef;

/// Whether a window is "ordered in" (mapped/rendered) right now — the window
/// server's own visibility bit, and the reliable way to tell a real window from
/// a background tab. Writes to `out`; returns `kCGErrorSuccess` on success.
pub extern fn SLSWindowIsOrderedIn(cid: ConnectionID, wid: WindowID, out: *bool) CGError;

pub extern fn SLSWindowIteratorGetCount(iterator: c.CFTypeRef) c_int;
pub extern fn SLSWindowIteratorAdvance(iterator: c.CFTypeRef) bool;
pub extern fn SLSWindowIteratorGetWindowID(iterator: c.CFTypeRef) u32;
/// 0 for top-level windows; non-zero means a child window (sheet/drawer/tab).
pub extern fn SLSWindowIteratorGetParentID(iterator: c.CFTypeRef) u32;
pub extern fn SLSWindowIteratorGetTags(iterator: c.CFTypeRef) u64;
pub extern fn SLSWindowIteratorGetAttributes(iterator: c.CFTypeRef) u64;
pub extern fn SLSWindowIteratorGetLevel(iterator: c.CFTypeRef) c_int;

// --- Snap-zone detection during a drag -------------------------------------

pub extern fn SLSSnappingInfoCreate(cid: ConnectionID, wid: WindowID) SnappingInfoRef;
pub extern fn SLSSnappingInfoRelease(ref: SnappingInfoRef) void;
pub extern fn SLSSnappingInfoSetPrefs(ref: SnappingInfoRef, prefs: c.CFDictionaryRef) void;
pub extern fn SLSSnappingInfoSetIsForResizing(ref: SnappingInfoRef, resizing: bool) void;
pub extern fn SLSSnappingInfoSetSnappedEdges(ref: SnappingInfoRef, edges: u32) void;
pub extern fn SLSSnappingInfoAddMovement(ref: SnappingInfoRef, pt: c.CGPoint, vel: c.CGVector) void;
pub extern fn SLSSnappingInfoResetMovement(ref: SnappingInfoRef) void;

pub extern fn SLSSnappingInfoGetCurrentSnappedEdgesForRect(ref: SnappingInfoRef, frame: c.CGRect) u32;
pub extern fn SLSSnappingInfoGetSnappedEdges(ref: SnappingInfoRef) u32;
pub extern fn SLSSnappingInfoGetLastSnappedRect(ref: SnappingInfoRef) c.CGRect;
pub extern fn SLSSnappingInfoGetSizeSnapRectForFrame(ref: SnappingInfoRef, frame: c.CGRect) c.CGRect;
pub extern fn SLSSnappingInfoSnapOriginWithFrame(ref: SnappingInfoRef, origin: c.CGPoint, frame: c.CGRect) c.CGPoint;
pub extern fn SLSSnappingInfoSnapFrameForResizing(ref: SnappingInfoRef, frame: c.CGRect) c.CGRect;
pub extern fn SLSSnappingInfoGetCurrentVelocity(ref: SnappingInfoRef) c.CGVector;
/// `handler` is an Objective-C block `void (^)(CGRect)`. Build one with the
/// `objc` package's `Block` and pass its pointer here.
pub extern fn SLSSnappingInfoEnumerateSnappingRects(ref: SnappingInfoRef, handler: *const anyopaque) void;

// --- Native tile spaces (Sequoia split-screen with live divider) -----------
// NOTE: producing a usable tiled state generally requires running as a
// registered WindowManager client; from a normal process these create the
// space but it won't behave.

pub extern fn SLSSpaceCanCreateTile(space_id: u64) bool;
pub extern fn SLSSpaceCreateTile(cid: ConnectionID, space_id: u64, wid: WindowID, position: u32) u64;
pub extern fn SLSSpaceCopyTileSpaces(cid: ConnectionID, space_id: u64) c.CFArrayRef;

pub extern fn SLSTileSpaceTakeOwnership(cid: ConnectionID, tile_space_id: u64) void;
pub extern fn SLSTileSpaceSetDividerWindow(cid: ConnectionID, space_id: u64, divider_window_id: WindowID) void;

pub extern fn SLSWindowGetTileRect(cid: ConnectionID, wid: WindowID) c.CGRect;
pub extern fn SLSSpaceGetSizeForProposedTile(cid: ConnectionID, space_id: u64) c.CGSize;
pub extern fn SLSTileSpaceMoveSpacersForSize(cid: ConnectionID, space_id: u64, size: c.CGSize) void;
pub extern fn SLSTileSpaceMoveSpacersForSizeFenced(cid: ConnectionID, space_id: u64, size: c.CGSize) void;
pub extern fn SLSSpaceFinishedResizeForRect(cid: ConnectionID, space_id: u64, rect: c.CGRect) void;
pub extern fn SLSGetTileSpaceDividerDirections(cid: ConnectionID, space_id: u64) u32;
pub extern fn SLSSpaceSetInterTileSpacing(cid: ConnectionID, space_id: u64, spacing: c.CGFloat) void;
pub extern fn SLSSpaceGetInterTileSpacing(cid: ConnectionID, space_id: u64) c.CGFloat;

// --- Record accessors for tile-resize notifications ------------------------

pub extern fn SLSTileEvictionRecordGetTileID(record: c.CFTypeRef) WindowID;
pub extern fn SLSTileEvictionRecordGetManagedSpaceID(record: c.CFTypeRef) u64;
pub extern fn SLSTileOwnerChangeRecordGetTileID(record: c.CFTypeRef) WindowID;
pub extern fn SLSTileOwnerChangeRecordGetNewOwner(record: c.CFTypeRef) c.pid_t;
pub extern fn SLSTileOwnerChangeRecordGetOldOwner(record: c.CFTypeRef) c.pid_t;
pub extern fn SLSTileOwnerChangeRecordGetManagedSpaceID(record: c.CFTypeRef) u64;
pub extern fn SLSTileSpaceResizeRecordGetSpaceID(record: c.CFTypeRef) u64;
pub extern fn SLSTileSpaceResizeRecordGetParentSpaceID(record: c.CFTypeRef) u64;
pub extern fn SLSTileSpaceResizeRecordIsLiveResizing(record: c.CFTypeRef) bool;

// --- Constants -------------------------------------------------------------
// Per-window snapping opt-out keys (set via CGSWindow properties).

/// Opt this window out of snapping.
pub extern const _SLWindowDisallowSnappingKey: c.CFStringRef;
/// Stop other windows snapping to this window.
pub extern const _SLWindowDisallowSnappingTargetKey: c.CFStringRef;
/// Posted when a tiled pair is live-resized.
pub extern const _kSLSCoordinatedTileResizeNotificationName: c.CFStringRef;

// --- Window-server event notifications (CoreGraphicsServices) --------------

/// C callback for low-level window-server events. Called on the main thread
/// while the run loop runs.
pub const NotifyProcPtr = *const fn (
    type: u32,
    data: ?*anyopaque,
    data_length: usize,
    userdata: ?*anyopaque,
) callconv(.c) void;

/// Register a callback for a window-server event `type`. Resolves via
/// CoreGraphics (no extra framework needed).
pub extern fn CGSRegisterNotifyProc(proc: NotifyProcPtr, type: u32, userdata: ?*anyopaque) CGError;

/// Window-server event type for Mission Control space changes.
pub const kCGSNotificationSpaceChanged: u32 = 1401;
