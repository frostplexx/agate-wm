//! agate's native macOS interop layer.
//!
//! Strategy (mirrors Ghostty's `pkg/macos`):
//!   * `c` consolidates every C framework header into a single `@cImport`.
//!   * Pure-C frameworks (CoreFoundation, CoreGraphics, the Accessibility API)
//!     get hand-written, idiomatic Zig wrappers on top of `c`.
//!   * Objective-C classes (AppKit's NSWorkspace &c.) are reached through the
//!     Objective-C runtime via the `objc` package, not `@cImport`.
//!
//! The build wires this module to the active Apple SDK (`addAppleSDK`) and
//! links the frameworks, so `@cImport` resolves the umbrella headers.

/// Raw, translate-c'd framework decls. Prefer the typed wrappers below; reach
/// for `c` only for APIs not yet wrapped.
pub const c = @import("c.zig").c;

/// Hand-written `extern` decls for the Accessibility C API (see `ax.zig`).
pub const ax = @import("ax.zig");
/// Hand-written `extern` decls for the CoreGraphics window-list API (`cg.zig`).
pub const cg = @import("cg.zig");
/// SkyLight / CoreGraphicsServices private window-server SPI (`skylight.zig`).
pub const skylight = @import("skylight.zig");

pub const foundation = @import("foundation.zig");
pub const accessibility = @import("accessibility.zig");
pub const workspace = @import("workspace.zig");
pub const window_list = @import("window_list.zig");
/// Per-Space window enumeration via SkyLight (spans all Spaces/displays).
pub const spaces = @import("spaces.zig");
/// Display geometry (NSScreen visible frame, AX coordinates).
pub const display = @import("display.zig");
/// Monotonic millisecond clock.
pub const clock = @import("clock.zig");
/// CoreGraphics event tap (listen-only mouse up/down).
pub const event_tap = @import("event_tap.zig");
/// IOHIDEvent SPI: synthesize Space-switch gestures (iohid.zig).
pub const iohid = @import("iohid.zig");
/// NSWorkspace app launch/terminate notifications (event-driven, real-time).
pub const app_watch = @import("app_watch.zig");

// Common conveniences re-exported at the top level.
pub const String = foundation.String;
pub const Element = accessibility.Element;
pub const isProcessTrusted = accessibility.isProcessTrusted;
pub const isProcessTrustedPrompt = accessibility.isProcessTrustedPrompt;

test {
    @import("std").testing.refAllDecls(@This());
}
