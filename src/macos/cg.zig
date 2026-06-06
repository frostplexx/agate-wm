//! Hand-written `extern` declarations for the CoreGraphics window-server query
//! (`CGWindowList*`). `<CoreGraphics/CGWindow.h>` transitively includes CGImage
//! → CGColorSpace, which translate-c can't process (see `c.zig`), so this small
//! ABI-stable slice is declared by hand. Symbols are exported by CoreGraphics,
//! which the build links. CF/CG types are reused from the `@cImport` in `c.zig`.
const c = @import("c.zig").c;

pub const WindowID = u32;
pub const WindowListOption = u32;

// From CGWindow.h's CGWindowListOption enum.
/// All windows in the session, including those on other Spaces / off-screen.
pub const kCGWindowListOptionAll: WindowListOption = 0;
pub const kCGWindowListOptionOnScreenOnly: WindowListOption = 1 << 0;
/// With `relativeToWindow` set to a window id, return just that window's info.
pub const kCGWindowListOptionIncludingWindow: WindowListOption = 1 << 3;
pub const kCGWindowListExcludeDesktopElements: WindowListOption = 1 << 4;

pub const kCGNullWindowID: WindowID = 0;

pub extern fn CGWindowListCopyWindowInfo(
    option: WindowListOption,
    relativeToWindow: WindowID,
) c.CFArrayRef;

// Window-info dictionary keys (exported `CFStringRef` globals).
pub extern const kCGWindowNumber: c.CFStringRef;
pub extern const kCGWindowOwnerName: c.CFStringRef;
pub extern const kCGWindowOwnerPID: c.CFStringRef;
pub extern const kCGWindowLayer: c.CFStringRef;
pub extern const kCGWindowBounds: c.CFStringRef;
