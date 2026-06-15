//! The swipe affordance: a single Liquid Glass circle with a directional SF
//! Symbol chevron, flashed at the screen edge once a trackpad swipe has
//! travelled far enough to commit — exactly the back/forward arrow Safari,
//! Chrome and Firefox show on a two-finger swipe. It appears when you cross the
//! threshold and disappears when you fall back under it or lift; there is no
//! per-frame drawing, so it stays cheap and lag-free.
//!
//! Built on macOS 26's public `NSGlassEffectView` for the real Liquid Glass
//! material, falling back to `NSVisualEffectView` (the HUD-window blur) on
//! anything older or if the class is unavailable, so the WM never hard-depends
//! on it. Everything is driven through the Obj-C runtime, the same strategy as
//! `overlay.zig`; AppKit is main-thread-only, so every entry point here must be
//! called from the run loop (`wm/gestures.zig` marshals for us).
const objc = @import("objc");
const c = @import("c.zig").c;

/// The edge the arrow hugs and points toward.
pub const Dir = enum { left, right, up, down };

// Circle geometry (points).
const size: f64 = 64;
const corner: f64 = size / 2;
/// Padding between the circle's edge and the SF Symbol. Sized so the chevron's
/// box is ~half the circle, leaving it small and centered.
const glyph_inset: f64 = 20;
/// Inset of the circle's near edge from the screen edge it hugs.
const edge_inset: f64 = 16;
/// How far the circle slides in from the edge as it appears.
const slide_in: f64 = 22;
const fade: f64 = 0.16; // show/hide fade duration (seconds)

var g_window: ?objc.Object = null;
var g_glass: bool = false; // true if real NSGlassEffectView, false if fallback
var g_arrow: ?objc.Object = null; // the NSImageView holding the chevron symbol

fn nsString(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse return .{ .value = null };
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

/// SF Symbol names for a direction, preferring the double chevron ("two arrows")
/// and falling back to the single chevron if that symbol is unavailable.
fn symbolNames(dir: Dir) [2][*:0]const u8 {
    return switch (dir) {
        .left => .{ "chevron.left.2", "chevron.left" },
        .right => .{ "chevron.right.2", "chevron.right" },
        .up => .{ "chevron.up.2", "chevron.up" },
        .down => .{ "chevron.down.2", "chevron.down" },
    };
}

/// Load the first available SF Symbol from `names` as a template NSImage.
fn makeSymbol(names: [2][*:0]const u8) ?objc.Object {
    const NSImage = objc.getClass("NSImage") orelse return null;
    for (names) |n| {
        const img = NSImage.msgSend(objc.Object, "imageWithSystemSymbolName:accessibilityDescription:", .{
            nsString(n), @as(?*anyopaque, null),
        });
        if (img.value != null) return img;
    }
    return null;
}

/// Build the window, glass material, and the arrow image view once. Returns the
/// window, or null if AppKit/runtime calls fail (the HUD then silently no-ops).
fn ensureWindow() ?objc.Object {
    if (g_window) |w| return w;

    const NSApplication = objc.getClass("NSApplication") orelse return null;
    _ = NSApplication.msgSend(objc.Object, "sharedApplication", .{});

    const NSWindow = objc.getClass("NSWindow") orelse return null;
    const allocd = NSWindow.msgSend(objc.Object, "alloc", .{});
    if (allocd.value == null) return null;
    const frame = c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = size, .height = size } };
    // styleMask 0 = borderless, backing 2 = buffered.
    const win = allocd.msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
        frame, @as(u64, 0), @as(u64, 2), false,
    });
    if (win.value == null) return null;

    win.msgSend(void, "setOpaque:", .{false});
    win.msgSend(void, "setHasShadow:", .{true});
    win.msgSend(void, "setIgnoresMouseEvents:", .{true});
    win.msgSend(void, "setReleasedWhenClosed:", .{false});
    win.msgSend(void, "setAlphaValue:", .{@as(f64, 0)});
    const NSColor = objc.getClass("NSColor") orelse return null;
    win.msgSend(void, "setBackgroundColor:", .{NSColor.msgSend(objc.Object, "clearColor", .{})});
    // 101 = NSPopUpMenuWindowLevel: above normal windows, below the screensaver.
    win.msgSend(void, "setLevel:", .{@as(i64, 101)});
    // CanJoinAllSpaces (1<<0) | Transient (1<<3) | IgnoresCycle (1<<6): pure
    // chrome — every Space, hidden from Mission Control and the window cycle.
    win.msgSend(void, "setCollectionBehavior:", .{@as(u64, (1 << 0) | (1 << 3) | (1 << 6))});

    // The Liquid Glass material (macOS 26+), or the HUD blur as a fallback.
    const glass_view = makeGlass(frame) orelse return null;

    // A tinted SF Symbol chevron, inset by `glyph_inset`, composited over the
    // glass. Both glass classes are NSViews, so addSubview: works for either;
    // NSGlassEffectView also exposes -setContentView: for proper over-glass
    // compositing, which we prefer when present.
    const NSImageView = objc.getClass("NSImageView") orelse return null;
    const iv = NSImageView.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{c.CGRect{
        .origin = .{ .x = glyph_inset, .y = glyph_inset },
        .size = .{ .width = size - 2 * glyph_inset, .height = size - 2 * glyph_inset },
    }});
    // 3 = NSImageScaleProportionallyUpOrDown: the chevron fills the inset box.
    iv.msgSend(void, "setImageScaling:", .{@as(u64, 3)});
    iv.msgSend(void, "setContentTintColor:", .{NSColor.msgSend(objc.Object, "whiteColor", .{})});
    g_arrow = iv;

    if (g_glass) {
        glass_view.msgSend(void, "setContentView:", .{iv});
    } else {
        glass_view.msgSend(void, "addSubview:", .{iv});
    }
    win.msgSend(void, "setContentView:", .{glass_view});

    g_window = win;
    return win;
}

/// Create the glass material view sized to `frame`. Sets `g_glass` to whether
/// we got the real `NSGlassEffectView`.
fn makeGlass(frame: c.CGRect) ?objc.Object {
    if (objc.getClass("NSGlassEffectView")) |Glass| {
        const v = Glass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{frame});
        if (v.value != null) {
            v.msgSend(void, "setCornerRadius:", .{corner});
            g_glass = true;
            return v;
        }
    }
    // Fallback: NSVisualEffectView with the HUD material, rounded by its layer.
    const Visual = objc.getClass("NSVisualEffectView") orelse return null;
    const v = Visual.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{frame});
    if (v.value == null) return null;
    // material 13 = HUDWindow, blendingMode 0 = behindWindow, state 1 = active.
    v.msgSend(void, "setMaterial:", .{@as(i64, 13)});
    v.msgSend(void, "setBlendingMode:", .{@as(i64, 0)});
    v.msgSend(void, "setState:", .{@as(i64, 1)});
    v.msgSend(void, "setWantsLayer:", .{true});
    const layer = v.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setCornerRadius:", .{corner});
        layer.msgSend(void, "setMasksToBounds:", .{true});
    }
    g_glass = false;
    return v;
}

/// Resting origin of the circle against the screen edge for `dir`, in AppKit
/// global (bottom-left) coordinates.
fn restingOrigin(dir: Dir) ?c.CGPoint {
    const NSScreen = objc.getClass("NSScreen") orelse return null;
    const screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (screen.value == null) return null;
    const f = screen.msgSend(c.CGRect, "frame", .{});
    const cx = f.origin.x + (f.size.width - size) / 2;
    const cy = f.origin.y + (f.size.height - size) / 2;
    return switch (dir) {
        .left => .{ .x = f.origin.x + edge_inset, .y = cy },
        .right => .{ .x = f.origin.x + f.size.width - size - edge_inset, .y = cy },
        .up => .{ .x = cx, .y = f.origin.y + f.size.height - size - edge_inset },
        .down => .{ .x = cx, .y = f.origin.y + edge_inset },
    };
}

/// Animate the window's alpha (and optionally its origin, for the slide) via the
/// animator proxy. No completion block needed — hidden just means alpha 0.
fn animate(win: objc.Object, target_alpha: f64, origin: ?c.CGPoint) void {
    const NSAnimationContext = objc.getClass("NSAnimationContext") orelse {
        win.msgSend(void, "setAlphaValue:", .{target_alpha});
        if (origin) |o| win.msgSend(void, "setFrameOrigin:", .{o});
        return;
    };
    NSAnimationContext.msgSend(void, "beginGrouping", .{});
    NSAnimationContext.msgSend(objc.Object, "currentContext", .{}).msgSend(void, "setDuration:", .{fade});
    const animator = win.msgSend(objc.Object, "animator", .{});
    animator.msgSend(void, "setAlphaValue:", .{target_alpha});
    if (origin) |o| animator.msgSend(void, "setFrameOrigin:", .{o});
    NSAnimationContext.msgSend(void, "endGrouping", .{});
}

/// Show the arrow for `dir`, sliding it in from the screen edge. Idempotent
/// enough to call once per threshold crossing; callers should avoid re-calling
/// while it's already up for the same direction.
pub fn show(dir: Dir) void {
    const win = ensureWindow() orelse return;
    if (g_arrow) |iv| if (makeSymbol(symbolNames(dir))) |img| iv.msgSend(void, "setImage:", .{img});
    const rest = restingOrigin(dir) orelse return;
    // Start a touch toward the edge, then slide to the resting spot.
    const start: c.CGPoint = switch (dir) {
        .left => .{ .x = rest.x - slide_in, .y = rest.y },
        .right => .{ .x = rest.x + slide_in, .y = rest.y },
        .up => .{ .x = rest.x, .y = rest.y + slide_in },
        .down => .{ .x = rest.x, .y = rest.y - slide_in },
    };
    win.msgSend(void, "setFrameOrigin:", .{start});
    win.msgSend(void, "orderFrontRegardless", .{});
    animate(win, 1.0, rest);
}

/// Hide the arrow, fading it out. Cheap if already hidden.
pub fn hide() void {
    const win = g_window orelse return;
    animate(win, 0.0, null);
}
