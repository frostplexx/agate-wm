const std = @import("std");
const macos = @import("macos");
const data = @import("data.zig");

/// Whether the window is "ordered in" — mapped/rendered by the window server.
/// Background macOS *native tabs* are not ordered in (only the front tab of a
/// tab group is), so this is how we keep a tab group from tiling as several
/// windows. Uses the private SkyLight SPI `SLSWindowIsOrderedIn`; on error we
/// assume ordered-in so a query failure never hides a real window.
pub fn isOrderedIn(win: *const data.Window) bool {
    var out: bool = false;
    const cid = macos.skylight.CGSMainConnectionID();
    if (macos.skylight.SLSWindowIsOrderedIn(cid, win.id, &out) != macos.skylight.kCGErrorSuccess) return true;
    return out;
}

/// Build a Window from CG/SkyLight metadata. The AX element is *not* resolved
/// here — see `resolveElement`. macOS won't expose a window's AX element while
/// its Space has never been active, so eager resolution fails for every window
/// not on the currently active Space. We defer it until the window is actually
/// manipulated, by which point its Space will have been visited.
pub fn init(info: macos.window_list.WindowInfo) data.Window {
    return .{
        .id = info.id,
        .pid = info.pid,
        .owner = info.owner,
        .bounds = info.bounds,
    };
}

/// Build a Window straight from its AX element, reading id/pid/frame/title from
/// Accessibility instead of CoreGraphics. Used on the window-created event:
/// CoreGraphics and SkyLight have not registered the brand-new window yet, so a
/// CGWindowList/SLS lookup races and returns nothing. This mirrors yabai's
/// `window_create` (src/window.c), which builds the window entirely from the
/// AXUIElementRef (frame via `window_ax_frame`, id via `ax_window_id`) with no
/// CoreGraphics dependency. Retains the element; `owner` and `title` are duped
/// into `alloc` (use the tree's arena so they outlive the Window).
pub fn fromElement(alloc: std.mem.Allocator, element: *macos.Element, owner: []const u8) ?data.Window {
    const wid = element.windowId() orelse return null;
    const pid = element.pid() orelse return null;
    const pos = element.position() orelse macos.accessibility.Point{ .x = 0, .y = 0 };
    const sz = element.size() orelse macos.accessibility.Size{ .width = 0, .height = 0 };
    var title: []const u8 = "";
    if (element.copyString("AXTitle")) |t| {
        defer t.release();
        var tbuf: [512]u8 = undefined;
        if (t.cstring(&tbuf)) |s| title = alloc.dupe(u8, s) catch "";
    }
    element.retain();
    return .{
        .id = wid,
        .pid = pid,
        .owner = owner,
        .title = title,
        .bounds = .{ .origin = pos, .size = sz },
        .ax_element = element,
    };
}

/// Lazily resolve (and cache) the window's AX element. Returns null if the app
/// still won't expose it — typically because its Space has not been active yet.
/// `enableManualAccessibility` nudges Chromium/Electron/Firefox-based apps to
/// publish their AXWindows list.
pub fn resolveElement(win: *data.Window) ?*macos.Element {
    if (win.ax_element) |el| return el;

    // Fast path: the app's AXWindows list. Works when the window's Space is or
    // has been active. `enableManualAccessibility` nudges lazy-a11y apps.
    if (macos.Element.createApplication(@intCast(win.pid))) |app| {
        defer app.release();
        app.enableManualAccessibility();
        if (app.windowForId(win.id)) |el| {
            win.ax_element = el;
            return el;
        }
    }

    // Fallback: fabricate the AX element via a private remote token. This is the
    // only way to get a movable AX ref for a window on a Space that has never
    // been active (AXWindows omits those).
    if (macos.accessibility.windowForIdViaRemoteToken(@intCast(win.pid), win.id)) |el| {
        win.ax_element = el;
        return el;
    }

    return null;
}
