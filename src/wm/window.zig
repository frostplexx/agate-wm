const macos = @import("macos");
const data = @import("data.zig");

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
