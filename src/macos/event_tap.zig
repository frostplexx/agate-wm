//! Hand-written `extern` declarations for CoreGraphics' event-tap API
//! (`CGEventTap*`). `<CoreGraphics/CGEvent.h>` can't go through `@cImport` (the
//! CoreGraphics umbrella defeats translate-c — see `c.zig`), so the small slice
//! we need is declared here. Symbols resolve from CoreGraphics, which is linked.
//!
//! We use this read-only (listen-only) to learn when the user presses and
//! releases the left mouse button, so window drags are applied on mouse-up
//! rather than on a timer — the role yabai's mouse event tap plays
//! (koekeishiya/yabai, src/mouse_handler.c).
const c = @import("c.zig").c;

pub const EventRef = ?*anyopaque;
pub const EventTapProxy = ?*anyopaque;
pub const MachPortRef = ?*anyopaque;

pub const EventType = u32;
pub const kCGEventLeftMouseDown: EventType = 1;
pub const kCGEventLeftMouseUp: EventType = 2;
pub const kCGEventLeftMouseDragged: EventType = 6;
// The system disables a tap that is too slow or interrupted; the callback must
// re-enable it (yabai, src/mouse_handler.c).
pub const kCGEventTapDisabledByTimeout: EventType = 0xFFFFFFFE;
pub const kCGEventTapDisabledByUserInput: EventType = 0xFFFFFFFF;

pub const EventMask = u64;
/// The event-mask bit for an event type.
pub fn mask(t: EventType) EventMask {
    return @as(EventMask, 1) << @intCast(t);
}

pub const TapLocation = u32;
pub const kCGSessionEventTap: TapLocation = 1;
pub const TapPlacement = u32;
pub const kCGHeadInsertEventTap: TapPlacement = 0;
pub const TapOptions = u32;
pub const kCGEventTapOptionListenOnly: TapOptions = 1;

/// Listen-only callback. Return `event` unchanged (we don't modify the stream).
pub const TapCallBack = *const fn (
    proxy: EventTapProxy,
    type: EventType,
    event: EventRef,
    userInfo: ?*anyopaque,
) callconv(.c) EventRef;

pub extern fn CGEventTapCreate(
    tap: TapLocation,
    place: TapPlacement,
    options: TapOptions,
    eventsOfInterest: EventMask,
    callback: TapCallBack,
    userInfo: ?*anyopaque,
) MachPortRef;
pub extern fn CGEventTapEnable(tap: MachPortRef, enable: bool) void;
/// The cursor location (global, top-left origin) carried by a mouse event.
pub extern fn CGEventGetLocation(event: EventRef) c.CGPoint;
pub extern fn CFMachPortCreateRunLoopSource(
    allocator: ?*const anyopaque,
    port: MachPortRef,
    order: c.CFIndex,
) c.CFRunLoopSourceRef;
