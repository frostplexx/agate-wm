//! The flush pass: compute each leaf window's frame from the container tree
//! (rect + layout + gaps) and push it onto the real window via Accessibility.
//! The tree is the source of truth — this makes the OS match it.
//!
//! Mirrors yabai's `view_flush` / `window_node_flush` (koekeishiya/yabai,
//! src/view.c): walk to the leaves, assign rects, and apply each to its window.
//! See `applyFrame` for the size-then-position ordering and why we diverge from
//! yabai's trailing resize.
const macos = @import("macos");
const data = @import("data.zig");
const window = @import("window.zig");

const Rect = macos.window_list.Rect;

/// Lay out and apply a workspace's windows within `area` (the display's usable
/// frame, AX coordinates). The workspace's `outer` gap insets the whole area;
/// children are then split per the container's layout with the `inner` gap
/// between them.
pub fn flushWorkspace(ws: *data.Con, area: Rect) void {
    layoutChildren(ws, inset(area, @floatFromInt(ws.gaps.outer)));
}

/// Split `area` among `con`'s children according to its layout, recursing into
/// nested split containers and applying frames at the leaves.
fn layoutChildren(con: *data.Con, area: Rect) void {
    const n = con.children.len();
    if (n == 0) return;

    const gap: f64 = @floatFromInt(con.gaps.inner);
    var it = con.children.first;
    var i: usize = 0;
    while (it) |node| : ({
        it = node.next;
        i += 1;
    }) {
        place(data.Con.fromNode(node), childRect(con.layout, area, n, i, gap));
    }
}

/// Apply `area` to a leaf window, or recurse if it's a nested split container.
fn place(con: *data.Con, area: Rect) void {
    if (con.window != null) {
        applyFrame(&con.window.?, area);
    } else {
        layoutChildren(con, area);
    }
}

/// The rect for child `i` of `n` within `area` under `layout`.
fn childRect(layout: data.layouts, area: Rect, n: usize, i: usize, gap: f64) Rect {
    const nf: f64 = @floatFromInt(n);
    const fi: f64 = @floatFromInt(i);
    return switch (layout) {
        // Even columns left-to-right.
        .H_SPLIT => blk: {
            const w = (area.size.width - gap * (nf - 1)) / nf;
            break :blk .{
                .origin = .{ .x = area.origin.x + fi * (w + gap), .y = area.origin.y },
                .size = .{ .width = w, .height = area.size.height },
            };
        },
        // Even rows top-to-bottom.
        .V_SPLIT => blk: {
            const h = (area.size.height - gap * (nf - 1)) / nf;
            break :blk .{
                .origin = .{ .x = area.origin.x, .y = area.origin.y + fi * (h + gap) },
                .size = .{ .width = area.size.width, .height = h },
            };
        },
        // Stacks and float: every child fills the area for now.
        .H_STACK, .V_STACK, .FLOAT => area,
    };
}

/// Push a frame onto the real window (AX element resolved lazily).
///
/// Order matters: set size FIRST so the target position isn't clamped to the
/// window's old (larger) extent, then set position LAST. yabai's
/// `window_manager_set_window_frame` (koekeishiya/yabai, src/window_manager.c)
/// also re-sets size *after* the move; we deliberately don't, because that
/// trailing resize makes some apps — terminals like Ghostty especially —
/// re-anchor and snap back to their old position.
fn applyFrame(win: *data.Window, area: Rect) void {
    const el = window.resolveElement(win) orelse return;
    _ = el.setSize(area.size);
    _ = el.setPosition(area.origin);
    win.bounds = area; // keep the model in sync with what we requested
}

/// Shrink a rect inward by `by` on every side.
fn inset(r: Rect, by: f64) Rect {
    return .{
        .origin = .{ .x = r.origin.x + by, .y = r.origin.y + by },
        .size = .{ .width = r.size.width - 2 * by, .height = r.size.height - 2 * by },
    };
}
