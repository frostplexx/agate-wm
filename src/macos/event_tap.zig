//! Hand-written `extern` declarations for CoreGraphics' event-tap API
//! (`CGEventTap*`). `<CoreGraphics/CGEvent.h>` can't go through `@cImport` (the
//! CoreGraphics umbrella defeats translate-c — see `c.zig`), so the small slice
//! we need is declared here. Symbols resolve from CoreGraphics, which is linked.
//!
//! We use this read-only (listen-only) to learn when the user presses and
//! releases the left mouse button, so window drags are applied on mouse-up
//! rather than on a timer — the role yabai's mouse event tap plays
//! (koekeishiya/yabai, src/mouse_handler.c).
const std = @import("std");
const c = @import("c.zig").c;

pub const EventRef = ?*anyopaque;
pub const EventTapProxy = ?*anyopaque;
pub const MachPortRef = ?*anyopaque;

pub const EventType = u32;
pub const kCGEventLeftMouseDown: EventType = 1;
pub const kCGEventLeftMouseUp: EventType = 2;
pub const kCGEventLeftMouseDragged: EventType = 6;
pub const kCGEventScrollWheel: EventType = 22;
pub const kCGEventKeyDown: EventType = 10;
pub const kCGEventKeyUp: EventType = 11;
pub const kCGEventFlagsChanged: EventType = 12;
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
pub const kCGHIDEventTap: TapLocation = 0; // lowest level — best for injecting real keystrokes
pub const kCGSessionEventTap: TapLocation = 1;
/// Downstream of all session taps: events here have already been annotated/
/// modified by other session taps (e.g. a key remapper like lazykeys). Tapping
/// here makes us see those modifications regardless of tap insertion order —
/// unlike a session tap, whose head/tail placement races other session taps.
pub const kCGAnnotatedSessionEventTap: TapLocation = 2;
pub const TapPlacement = u32;
pub const kCGHeadInsertEventTap: TapPlacement = 0; // runs before pre-existing taps
pub const kCGTailAppendEventTap: TapPlacement = 1; // runs after pre-existing taps
pub const TapOptions = u32;
pub const kCGEventTapOptionDefault: TapOptions = 0; // intercepting tap (can swallow events)
pub const kCGEventTapOptionListenOnly: TapOptions = 1;

// Modifier flag bits present in CGEventGetFlags output.
pub const kCGEventFlagMaskShift: u64 = 0x0002_0000;
pub const kCGEventFlagMaskControl: u64 = 0x0004_0000;
pub const kCGEventFlagMaskAlternate: u64 = 0x0008_0000; // Option key
pub const kCGEventFlagMaskCommand: u64 = 0x0010_0000;
/// Combined mask for all four standard modifier keys.
pub const kCGModifiersMask: u64 =
    kCGEventFlagMaskShift | kCGEventFlagMaskControl |
    kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;

// CGEventField enum value for the virtual key code.
pub const CGEventField = u32;
pub const kCGKeyboardEventKeycode: CGEventField = 9;

pub extern fn CGEventGetIntegerValueField(event: EventRef, field: CGEventField) i64;
pub extern fn CGEventGetFlags(event: EventRef) u64;
/// Overwrite an event's modifier flags. Used by the keyboard tap to inject the
/// hyper modifiers into a key event while the hyper key is held, so the focused
/// app receives the full chord (the built-in hyper key, ported from LazyKeys).
pub extern fn CGEventSetFlags(event: EventRef, flags: u64) void;

/// The *current* modifier-flag state for an event source, independent of any
/// particular event. We need this because a key remapper (lazykeys) can hold a
/// "hyper" chord whose flags never appear on the individual key event our tap
/// sees (tap-ordering against the remapper), yet the modifiers are active —
/// querying the combined session state recovers them. `stateID` 0 = combined
/// session state.
pub const CGEventSourceStateID = u32;
pub const kCGEventSourceStateCombinedSessionState: CGEventSourceStateID = 0;
pub const kCGEventSourceStateHIDSystemState: CGEventSourceStateID = 1;
pub extern fn CGEventSourceFlagsState(stateID: CGEventSourceStateID) u64;

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

// ---------------------------------------------------------------------------
// Synthetic Dock-swipe gesture (Space switching, macOS 27 / Golden Gate)
// ---------------------------------------------------------------------------
//
// macOS 27 moved the Space-swipe recognizer into Swift WindowManager.framework
// (`SpaceSwapSystemGesture` fed by `SystemGestureBase.handleEvent`). It calls
// `CGEventCopyIOHIDEvent` and reads the gesture from the IOHIDEvent *backing*
// the CGEvent — a synthetic CGEvent has no backing IOHIDEvent, so it is dropped.
//
// Fix discovered by FasterSwiper (jurplel): inject the private field 4205
// (`IOHIDSystemQueueElement`) into the CGEvent's serialized form. macOS 27 reads
// this field via `CGEventCreateFromData` instead of a live IOHIDEvent backing.
//
// Approach: create the CGEvent normally → serialize via `CGEventCreateData` →
// strip any existing field 4205 → build and append the field 4205 payload →
// deserialize via `CGEventCreateFromData` → post.

pub extern fn CGEventCreate(source: ?*anyopaque) EventRef;
pub extern fn CGEventSetIntegerValueField(event: EventRef, field: CGEventField, value: i64) void;
pub extern fn CGEventSetDoubleValueField(event: EventRef, field: CGEventField, value: f64) void;
pub extern fn CGEventPost(tap: TapLocation, event: EventRef) void;
pub extern fn CGEventSourceCreate(stateID: CGEventSourceStateID) ?*anyopaque;
pub extern fn CGEventCreateData(allocator: ?*const anyopaque, event: EventRef) c.CFDataRef;
pub extern fn CGEventCreateFromData(allocator: ?*const anyopaque, data: c.CFDataRef) EventRef;
pub extern fn CFDataCreate(allocator: ?*const anyopaque, bytes: [*]const u8, length: c.CFIndex) c.CFDataRef;
pub extern fn CFDataGetBytePtr(theData: c.CFDataRef) [*]const u8;
pub extern fn CFDataGetLength(theData: c.CFDataRef) c.CFIndex;
pub extern fn CGEventGetTimestamp(event: EventRef) u64;
extern fn mach_absolute_time() u64;

const kCGSEventTypeField: CGEventField = 55;
const kCGEventGestureHIDType: CGEventField = 110;
const kCGEventGestureSwipeMotion: CGEventField = 123;
const kCGEventGestureSwipeProgress: CGEventField = 124;
const kCGEventGestureSwipeVelocityX: CGEventField = 129;
const kCGEventGestureSwipeVelocityY: CGEventField = 130;
const kCGEventGesturePhase: CGEventField = 132;
/// Force source pid to 0 so the event looks like it came from the kernel HID path.
const kCGEventSourceUnixProcessID: CGEventField = 41;

const kCGSEventDockControl: i64 = 30;
const kIOHIDEventTypeDockSwipe: i64 = 23;
const kCGGestureMotionHorizontal: i64 = 1;

/// A swipe traverses Mission Control left or right.
pub const SwipeDirection = enum { left, right };
const GesturePhase = enum(i64) { began = 1, changed = 2, ended = 4 };

// ---------------------------------------------------------------------------
// IOHIDSystemQueueElement payload (field 4205) — little-endian.
// Reconstructed from FasterSwiper's gesture-serialization notes and the
// IOHIDFamily header layouts.
//
// extern struct gives the same layout as C with no extra padding for these
// structs (all fields naturally aligned, total sizes divisible by max align).
// IOHIDSystemQueueElementHeader has trailing padding in C ABI (28-byte members
// in an 8-byte-aligned struct → padded to 32); we write its 28 bytes manually.
// ---------------------------------------------------------------------------

const IOHIDEventBase = extern struct {
    size: u32,
    @"type": u32,
    options: u32, // gesture phase packed at bits 24-31: ((phase & 0xFF) << 24)
    depth: u8,
    reserved: [3]u8,
};
const IOHIDFluidTouchGestureData = extern struct {
    base: IOHIDEventBase,
    position_x: i32, // 16.16 fixed-point
    position_y: i32,
    position_z: i32,
    swipe_mask: u32,
    gesture_motion: u16,
    gesture_flavor: u16,
    swipe_progress: i32, // 16.16 fixed-point
};
const IOHIDVelocityEventData = extern struct {
    base: IOHIDEventBase,
    velocity_x: i32, // 16.16 fixed-point
    velocity_y: i32,
    velocity_z: i32,
};

comptime {
    std.debug.assert(@sizeOf(IOHIDEventBase) == 16);
    std.debug.assert(@sizeOf(IOHIDFluidTouchGestureData) == 40);
    std.debug.assert(@sizeOf(IOHIDVelocityEventData) == 28);
}

fn writeLE32(buf: []u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn writeLE64(buf: []u8, val: u64) void {
    writeLE32(buf[0..], @truncate(val));
    writeLE32(buf[4..], @truncate(val >> 32));
}

/// Convert a float to 16.16 fixed-point. Values that round to 0 are clamped to
/// ±1 so direction information survives the precision loss.
fn toFixed16_16(val: f64) i32 {
    const fixed: i32 = @intFromFloat(val * 65536.0);
    if (fixed == 0 and @abs(val) > 0.0) return if (val > 0.0) 1 else -1;
    return fixed;
}

/// Create a CGEvent with the standard Dock-swipe fields, inject the field 4205
/// IOHIDSystemQueueElement payload into its serialized form, deserialize, and post.
fn postPhase(phase: GesturePhase, dir: SwipeDirection, progress: f64, vel_x: f64) void {
    const src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    defer if (src) |s| c.CFRelease(@ptrCast(s));
    const ev = CGEventCreate(src) orelse return;
    defer c.CFRelease(@ptrCast(ev));

    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, @intFromEnum(phase));
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel_x);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, 0.0);
    CGEventSetIntegerValueField(ev, kCGEventSourceUnixProcessID, 0);

    // Serialize the base event.
    const cf_src = CGEventCreateData(null, ev) orelse return;
    defer c.CFRelease(@ptrCast(cf_src));
    const raw: []const u8 = CFDataGetBytePtr(cf_src)[0..@intCast(CFDataGetLength(cf_src))];
    if (raw.len < 4) return;

    // Rebuild without any pre-existing field 4205 (shouldn't be present, but strip defensively).
    var buf: [4096]u8 = undefined;
    var out: usize = 0;

    @memcpy(buf[0..4], raw[0..4]); // version header
    out = 4;

    var idx: usize = 4;
    while (idx + 4 <= raw.len) {
        const size_words: u16 = (@as(u16, raw[idx]) << 8) | @as(u16, raw[idx + 1]);
        const tag_word: u16 = (@as(u16, raw[idx + 2]) << 8) | @as(u16, raw[idx + 3]);
        const field_id: u16 = tag_word & 0x3FFF;
        const type_bits: u2 = @truncate(tag_word >> 14);

        const payload: usize = switch (type_bits) {
            0 => if (size_words == 1) 8 else (@as(usize, size_words) + 3) & ~@as(usize, 3),
            1, 3 => @as(usize, size_words) * 4,
            2 => 0,
        };
        if (idx + 4 + payload > raw.len) break;

        if (field_id != 4205) {
            const entry = 4 + payload;
            if (out + entry > buf.len) return;
            @memcpy(buf[out .. out + entry], raw[idx .. idx + entry]);
            out += entry;
        }
        idx += 4 + payload;
    }

    // Append field 4205.
    var ts = CGEventGetTimestamp(ev);
    if (ts == 0) ts = mach_absolute_time();

    const has_vel = vel_x != 0.0 or phase == .ended;
    const payload_size: u16 = if (has_vel) 96 else 68;
    const event_count: u32 = if (has_vel) 2 else 1;
    const swipe_mask: u32 = if (dir == .right) 0x8 else 0x4;
    const phase_opts: u32 = @as(u32, @intCast(@intFromEnum(phase) & 0xFF)) << 24;

    if (out + 4 + payload_size > buf.len) return;

    // Tag: big-endian size_words (= byte count for binary fields) and field id.
    buf[out + 0] = @intCast((payload_size >> 8) & 0xFF);
    buf[out + 1] = @intCast(payload_size & 0xFF);
    buf[out + 2] = 0x10; // (4205 >> 8) & 0xFF
    buf[out + 3] = 0x6D; // 4205 & 0xFF
    out += 4;

    // IOHIDSystemQueueElementHeader — 28 bytes, little-endian (native on Apple Silicon).
    // Written manually: C-ABI extern struct would add 4 bytes of trailing padding
    // (struct alignment is 8 due to u64 fields, 28 bytes rounds up to 32).
    writeLE64(buf[out..], ts);
    out += 8;
    writeLE64(buf[out..], 0x100003416); // horizontal gesture registry entry
    out += 8;
    writeLE32(buf[out..], 0); // options
    out += 4;
    writeLE32(buf[out..], 0); // attribute_length
    out += 4;
    writeLE32(buf[out..], event_count);
    out += 4;

    // IOHIDFluidTouchGestureData — 40 bytes via extern struct.
    const inner1 = IOHIDFluidTouchGestureData{
        .base = .{
            .size = 40,
            .@"type" = 23, // kIOHIDEventTypeFluidTouchGesture
            .options = phase_opts,
            .depth = 0,
            .reserved = .{ 0, 0, 0 },
        },
        .position_x = 0,
        .position_y = 0,
        .position_z = 0,
        .swipe_mask = swipe_mask,
        .gesture_motion = 1, // kIOHIDGestureMotionHorizontalX
        .gesture_flavor = 3, // kIOHIDGestureFlavorDockPrimary
        .swipe_progress = toFixed16_16(progress),
    };
    const i1_b = std.mem.asBytes(&inner1);
    @memcpy(buf[out .. out + i1_b.len], i1_b);
    out += i1_b.len;

    if (has_vel) {
        const inner2 = IOHIDVelocityEventData{
            .base = .{
                .size = 28,
                .@"type" = 9, // kIOHIDEventTypeVelocity
                .options = 0,
                .depth = 1,
                .reserved = .{ 0, 0, 0 },
            },
            .velocity_x = toFixed16_16(vel_x),
            .velocity_y = 0,
            .velocity_z = 0,
        };
        const i2_b = std.mem.asBytes(&inner2);
        @memcpy(buf[out .. out + i2_b.len], i2_b);
        out += i2_b.len;
    }

    // Deserialize the augmented event and post at the session tap level, where
    // Dock.app processes DockControl gestures (matches yabai's #2781 technique).
    const new_cf = CFDataCreate(null, buf[0..out].ptr, @intCast(out)) orelse return;
    defer c.CFRelease(@ptrCast(new_cf));
    const new_ev = CGEventCreateFromData(null, new_cf) orelse return;
    defer c.CFRelease(@ptrCast(new_ev));
    CGEventPost(kCGSessionEventTap, new_ev);
}

/// How fast a synthetic Space switch completes. The gesture recognizer animates
/// the remaining transition at the velocity carried by the `ended` phase, so the
/// velocity is the speed knob: enormous velocity ≈ no visible animation.
pub const SwitchSpeed = enum {
    /// Quick but visibly animated slide.
    fast,
    /// A blink of a slide.
    very_fast,
    /// Snap with no perceptible animation (yabai #2781 behaviour).
    instant,

    fn velocity(self: SwitchSpeed) f64 {
        return switch (self) {
            .fast => 1.5,
            .very_fast => 4.0,
            .instant => 9999.0,
        };
    }
};

/// The speed used for every synthetic Space switch. Set from the Lua config
/// (`agate.config{ space_animation = "fast" | "very_fast" | "instant" }`).
pub var switch_speed: SwitchSpeed = .instant;

/// Synthesize a began→ended Dock-swipe gesture sequence that switches one
/// Space in `dir`. Matches yabai's technique (#2781): two phases only, the
/// `ended` velocity (see `switch_speed`) deciding how much transition
/// animation plays. Uses the field 4205 IOHIDSystemQueueElement injection
/// required by macOS 27 / Golden Gate.
///
/// `dir == .right` → positive progress → higher Mission Control index (next space).
/// `dir == .left`  → negative progress → lower Mission Control index (prev space).
pub fn performSwitchGesture(dir: SwipeDirection) void {
    // Tiny progress means no visible drag — the velocity on `ended` carries
    // the recognizer the rest of the way to the adjacent space (yabai #2781).
    const espilon: f64 = std.math.floatTrueMin(f32);
    const progress: f64 = if (dir == .right) espilon else -espilon;
    const sign: f64 = if (dir == .right) 1.0 else -1.0;
    postPhase(.began, dir, progress, 0.0);
    postPhase(.ended, dir, progress, sign * switch_speed.velocity());
}
