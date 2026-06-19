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
const std = @import("std");
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
// NOTE: agate switches Spaces *only* by synthesizing the native Dock-swipe
// gesture (see `macos/event_tap.zig` + `macos/spaces.zig`). The SkyLight
// "set current space" SPIs (`SLSManagedDisplaySetCurrentSpace` and the atomic
// `SLSTransaction*` "Tahoe path") were explored as a non-gesture fallback but
// never shipped — they leave the menu bar stale on macOS 26/27 — and have been
// removed so there is one switch path and no fallback to drift out of sync.

// --- Window transforms (visual-only move/scale) — DEAD END for foreign windows
//
// The window server positions every window through an affine transform mapping
// *screen* points to *window-local* points: a window resting at frame F
// carries `translate(-F.x, -F.y)` (scale 1). Overriding it would redraw the
// window anywhere without involving the owning app — yabai's animation
// primitive (koekeishiya/yabai, src/window_manager.c).
//
// PROBED on this machine (macOS 27, tools/transform_probe.m, June 2026):
// both `SLSSetWindowTransform` and `SLSTransactionSetWindowTransform`+commit
// return success for windows of OTHER processes but the write is silently
// IGNORED (read-back unchanged; own-window writes store and apply). No
// `SLSBridged*` per-window transform operation exists either (all bridged ops
// are space-level). This is why yabai's animations need its Dock-injected
// scripting addition. agate's animations therefore interpolate via AX
// (`wm/animate.zig`) instead. Declarations kept for the probe and future RE.

/// CGAffineTransform (CoreGraphics/CGAffineTransform.h — hand-declared; the
/// header isn't in our @cImport). Maps p' = (a·x + c·y + tx, b·x + d·y + ty).
pub const CGAffineTransform = extern struct {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    tx: f64,
    ty: f64,
};

/// Set window `wid`'s screen→window transform. Returns 0 even when ignored —
/// success is NOT evidence the write landed (see probe note above); verify
/// with `SLSGetWindowTransform` read-back.
pub extern fn SLSSetWindowTransform(cid: ConnectionID, wid: WindowID, transform: CGAffineTransform) CGError;
pub extern fn SLSGetWindowTransform(cid: ConnectionID, wid: WindowID, out: *CGAffineTransform) CGError;

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

/// Schedule a bridged window-management operation against the WindowServer.
/// macOS 26+ Tahoe routes cross-space window reassignment through this entry
/// point; pair with `SLSBridgedMoveWindowsToManagedSpaceOperation` (allocated
/// via the Obj-C runtime, `initWithWindows:spaceID:`).
///
/// The real symbol is a C++ file-local (mangled `_ZL…`), so `dlsym` can't see
/// it. We mirror yabai's trick (koekeishiya/yabai, src/misc/macho_dlsym.h) and
/// walk SkyLight's `LC_SYMTAB` directly.
pub const SLSPerformAsynchronousBridgedWindowManagementOperationFn = *const fn (op: ?*anyopaque) callconv(.c) void;
pub fn slsPerformAsynchronousBridgedWindowManagementOperation() ?SLSPerformAsynchronousBridgedWindowManagementOperationFn {
    const S = struct {
        var resolved: bool = false;
        var fp: ?SLSPerformAsynchronousBridgedWindowManagementOperationFn = null;
    };
    if (!S.resolved) {
        S.resolved = true;
        const mangled = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
        if (machoFindSkyLightSymbol(mangled)) |sym| {
            S.fp = @ptrCast(@alignCast(sym));
        }
    }
    return S.fp;
}

// --- Mach-O symbol-table walker (ported from yabai's macho_dlsym.h) ---------
// `dlsym` only resolves externally-visible symbols. The one we need
// (`__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47…`) is a
// C++ file-local inside SkyLight, so we have to read its `LC_SYMTAB` ourselves.

const macho = std.macho;

extern fn _dyld_image_count() u32;
extern fn _dyld_get_image_name(image_index: u32) ?[*:0]const u8;
extern fn _dyld_get_image_header(image_index: u32) ?*const macho.mach_header_64;
extern fn _dyld_get_image_vmaddr_slide(image_index: u32) usize;

/// The runtime address of `name` inside the loaded SkyLight image, or null if
/// the framework isn't mapped or the symbol isn't present. Linear scan of every
/// nlist_64 entry — fine because we only call it once at first use.
fn machoFindSkyLightSymbol(name: []const u8) ?*anyopaque {
    const target = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
    const image_count = _dyld_image_count();

    var i: u32 = 0;
    while (i < image_count) : (i += 1) {
        const img_name_ptr = _dyld_get_image_name(i) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(img_name_ptr), target)) continue;

        const header = _dyld_get_image_header(i) orelse return null;
        const slide = _dyld_get_image_vmaddr_slide(i);

        var linkedit: ?*const macho.segment_command_64 = null;
        var symtab: ?*const macho.symtab_command = null;

        var cmd_addr: usize = @intFromPtr(header) + @sizeOf(macho.mach_header_64);
        var ci: u32 = 0;
        while (ci < header.ncmds) : (ci += 1) {
            const cmd: *const macho.load_command = @ptrFromInt(cmd_addr);
            if (cmd.cmd == .SEGMENT_64) {
                const seg: *const macho.segment_command_64 = @ptrFromInt(cmd_addr);
                if (std.mem.eql(u8, std.mem.sliceTo(&seg.segname, 0), "__LINKEDIT")) {
                    linkedit = seg;
                }
            } else if (cmd.cmd == .SYMTAB) {
                symtab = @ptrFromInt(cmd_addr);
            }
            cmd_addr += cmd.cmdsize;
        }

        const le = linkedit orelse return null;
        const st = symtab orelse return null;

        // The __LINKEDIT segment maps the symbol/string tables; this is the
        // standard "fileoff is the offset within __LINKEDIT" trick.
        const base: usize = @as(usize, @intCast(le.vmaddr - le.fileoff)) + slide;
        const strs: [*]const u8 = @ptrFromInt(base + st.stroff);
        const syms: [*]const macho.nlist_64 = @ptrFromInt(base + st.symoff);

        var s: u32 = 0;
        while (s < st.nsyms) : (s += 1) {
            const sym = syms[s];
            const sname = std.mem.span(@as([*:0]const u8, @ptrCast(strs + sym.n_strx)));
            if (std.mem.eql(u8, sname, name)) {
                return @ptrFromInt(@as(usize, @intCast(sym.n_value)) + slide);
            }
        }
        return null;
    }
    return null;
}

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
