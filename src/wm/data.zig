const macos = @import("macos");
const std = @import("std");

// == This file contains data structures used by the window manager.
//    - Data structures heavily inspired by i3: https://github.com/i3/i3/blob/next/include/data.h



/// Tiling modes for windows. These determine how windows are arranged on the screen.
pub const Layout = enum {
    V_SPLIT,
    H_SPLIT,
    FLOAT,
    H_STACK,
    V_STACK,
};

/// Gaps between windows and screen edges. These can be configured by the user.
pub const Gaps = struct {
    inner: u32,
    outer: u32,
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,
    /// Accordion/stack "peek": how far each stacked window is fanned past the one
    /// in front so its trailing edge stays visible (AeroSpace's accordion-padding).
    accordion: u32 = 40,
};


/// Represents a rectangle, used for window bounds and screen dimensions.
pub const Rect = macos.window_list.Rect;

/// Represents a window managed by the window manager. Contains information about
pub const Window = struct {
    id: u32,
    pid: i32,
    /// Borrowed from the arena used to query the window list.
    owner: []const u8,
    bounds: macos.window_list.Rect,
    /// Retained AX element, resolved lazily (see `window.resolveElement`).
    /// Null until first needed: macOS won't expose a window's AX element while
    /// its Space has never been active, so we can't get it eagerly at startup
    /// for windows on other Spaces.
    ax_element: ?*macos.Element = null,

    /// Whether the window is in a "fake" i.e. not macos native full-screen mode. This is used to determine whether to apply gaps and tiling.
    fake_full_screen: bool = false,

    /// Whether this window floats: lifted out of the tiling layout so it keeps
    /// its own free position/size (yabai's `window --toggle float`). The flush
    /// pass skips a floating leaf — it isn't counted in its siblings' split/stack
    /// math and is never resized — so the remaining tiles reflow without it while
    /// it stays put on top. Its leaf stays in the tree (still tracked, focusable,
    /// removed on close); only layout ignores it.
    floating: bool = false,

    /// Whether this window was observed joining a native macOS tab group (a new
    /// window created at the exact frame of an existing same-app window; see
    /// `observer.onWindowCreated`). There is no cross-process AX/CGS attribute
    /// for this on macOS 26 — `AXTabbedWindows` does not exist and the window
    /// server has no tab concept — so it is set when the join is observed and
    /// read by `onWindowDestroyed` to grant a tab close a grace re-pair.
    is_tabbed: bool = false,

    pub fn deinit(self: Window) void {
        if (self.ax_element) |el| el.release();
    }

};

/// Con is the main data structure representing the root space container, down to individual windows.
pub const Con = struct {

    pub const Type = enum {
        Root,
        Monitor,
        Workspace,
        Container,
    };

    /// Holds both window ids and SkyLight space ids (id64), so it must be 64-bit.
    id: u64,
    /// What this Con represents in the tree.
    con_type: Type,
    /// For a Workspace Con: the SkyLight Space `type` (0 = user/tileable,
    /// 2 = native-fullscreen, 4 = system). Non-user spaces are tracked (so a
    /// window parked there is found) but never tiled — agate must not resize a
    /// fullscreen window. Unused for other Con types.
    space_type: i64 = 0,
    /// The window contained in this Con, if it's a leaf node.
    window: ?Window = null,
    /// The tiling mode of this Con. Only relevant if it has children.
    layout: Layout = .H_SPLIT,
    /// Whether `layout` was set automatically by Small Screen Mode (so a later
    /// display reconfiguration may revert it). A manual `agate.layout(...)`
    /// clears it — user choices survive mode flips.
    auto_small: bool = false,
    /// The gaps for this Con. Only relevant if it has children.
    gaps: Gaps = .{ .inner = 0, .outer = 0, .top = 0, .bottom = 0, .left = 0, .right = 0 },
    /// parent of this Con. Null for the root Con.
    parent: ?*Con = null,
    /// Relative weight of this Con among its siblings along the parent's split
    /// axis. Equal weights tile evenly; a manual resize rewrites these so the
    /// new proportions persist (see `tree.applyManualResize`). Layout normalizes
    /// by the sum of siblings' ratios, so the units are arbitrary but must be
    /// consistent across siblings.
    ratio: f64 = 1.0,
    /// Depth of this Con in the tree. Root is 0, its children are 1, etc.
    depth: u32 = 0,
    /// The child this container last held focus through, so directional focus can
    /// restore the last-active window when re-entering instead of jumping to the
    /// edge (i3 "focus the most-recently-focused window"). Validated against the
    /// current children before use, so a stale pointer (closed window) is ignored.
    last_focused_child: ?*Con = null,
    /// Children of this Con in tiling order. Empty for leaf nodes. The slice
    /// order is the tiling order: index 0 is leftmost (H_SPLIT) or topmost
    /// (V_SPLIT); appending a new leaf places it at the trailing edge.
    children: std.ArrayListUnmanaged(*Con) = .{ .items = &.{}, .capacity = 0 },

    /// Count the leaf (real-window) cons at or under this Con — i.e. the windows
    /// it holds. Used by the layout pass (smart gaps) and the IPC reporters.
    pub fn leafCount(self: *const Con) usize {
        if (self.window != null) return 1;
        var total: usize = 0;
        for (self.children.items) |child| total += child.leafCount();
        return total;
    }
};
