const macos = @import("macos");

pub const Window = struct {
    id: u32,
    pid: i32,
    /// Borrowed from the arena used to query the window list.
    owner: []const u8,
    bounds: macos.window_list.Rect,
    /// Retained AX element — must call deinit when done.
    ax_element: *macos.Element,

    pub fn deinit(self: Window) void {
        self.ax_element.release();
    }
};

/// Build a Window from a WindowInfo. Returns null if the AX element cannot
/// be obtained (app not accessible, window already closed, etc.).
pub fn init(info: macos.window_list.WindowInfo) ?Window {
    const app = macos.Element.createApplication(@intCast(info.pid)) orelse return null;
    defer app.release();
    const ax_element = app.windowForId(info.id) orelse return null;
    return .{
        .id = info.id,
        .pid = info.pid,
        .owner = info.owner,
        .bounds = info.bounds,
        .ax_element = ax_element,
    };
}
