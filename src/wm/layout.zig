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
/// nested split containers and applying frames at the leaves. The main axis
/// (width for H_SPLIT, height for V_SPLIT) is divided in proportion to each
/// child's `ratio`; the cross axis fills the area. (Like yabai's view, each leaf
/// gets its exact computed area — no readback.)
fn layoutChildren(con: *data.Con, area: Rect) void {
    const n = con.children.items.len;
    if (n == 0) return;

    switch (con.layout) {
        .H_STACK, .V_STACK => return layoutStack(con, area),
        // FLOAT: leave each window filling the area (no real float model yet).
        .FLOAT => {
            for (con.children.items) |child| place(child, area);
            return;
        },
        .H_SPLIT, .V_SPLIT => {},
    }

    const horizontal = con.layout == .H_SPLIT;
    const gap: f64 = @floatFromInt(con.gaps.inner);

    var total_ratio: f64 = 0;
    for (con.children.items) |child| total_ratio += child.ratio;
    if (total_ratio <= 0) total_ratio = 1;

    const nf: f64 = @floatFromInt(n);
    const avail_main = (if (horizontal) area.size.width else area.size.height) - gap * (nf - 1);

    var offset = if (horizontal) area.origin.x else area.origin.y;
    for (con.children.items) |child| {
        const extent = avail_main * (child.ratio / total_ratio);
        const rect: Rect = if (horizontal) .{
            .origin = .{ .x = offset, .y = area.origin.y },
            .size = .{ .width = extent, .height = area.size.height },
        } else .{
            .origin = .{ .x = area.origin.x, .y = offset },
            .size = .{ .width = area.size.width, .height = extent },
        };
        place(child, rect);
        offset += extent + gap;
    }
}

/// Accordion / stacked layout (AeroSpace-style): the children overlap, fanned by
/// a fixed `accordion_peek` so each one's trailing edge shows past the one in
/// front of it. `H_STACK` fans horizontally (right edges peek); `V_STACK` fans
/// vertically (bottom edges peek). All windows share one size — the area shrunk
/// by the total fan span — so none leave the area; the focused window is brought
/// to the front by the focus engine (`AXRaise`), so it shows fully while the
/// rest peek. The fan step is clamped so it never consumes more than half the
/// area, keeping windows usable when the stack is deep.
fn layoutStack(con: *data.Con, area: Rect) void {
    const n = con.children.items.len;
    const horizontal = con.layout == .H_STACK;
    const nf: f64 = @floatFromInt(n);

    const peek: f64 = @floatFromInt(con.gaps.accordion);
    const main = if (horizontal) area.size.width else area.size.height;
    const step: f64 = if (n > 1) @min(peek, (main * 0.5) / (nf - 1)) else 0;
    const span = step * (nf - 1);

    for (con.children.items, 0..) |child, i| {
        const off = step * @as(f64, @floatFromInt(i));
        const rect: Rect = if (horizontal) .{
            .origin = .{ .x = area.origin.x + off, .y = area.origin.y },
            .size = .{ .width = area.size.width - span, .height = area.size.height },
        } else .{
            .origin = .{ .x = area.origin.x, .y = area.origin.y + off },
            .size = .{ .width = area.size.width, .height = area.size.height - span },
        };
        place(child, rect);
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

/// Push a frame onto the real window (AX element resolved lazily). This is a
/// direct port of yabai's `window_manager_set_window_frame`
/// (koekeishiya/yabai, src/window_manager.c): apply size → position → size.
/// macOS clamps a window to the visible area, so the size may need setting both
/// before the move (so the position isn't clamped to the old, larger extent) and
/// after it. The whole sequence runs with `AXEnhancedUserInterface` disabled
/// (yabai's `AX_ENHANCED_UI_WORKAROUND`, src/misc/helpers.h) — that attribute,
/// which macOS turns on for any app an assistive client attaches to, makes
/// AppKit *animate* AX-driven frame changes; turning it off makes them instant.
fn applyFrame(win: *data.Window, area: Rect) void {
    const el = window.resolveElement(win) orelse return;

    // The attribute lives on the *application* element, not the window.
    const app = macos.Element.createApplication(@intCast(win.pid));
    defer if (app) |a| a.release();
    const eui = if (app) |a| a.enhancedUserInterface() else false;
    if (eui) app.?.setEnhancedUserInterface(false);

    _ = el.setSize(area.size);
    _ = el.setPosition(area.origin);
    _ = el.setSize(area.size);

    if (eui) app.?.setEnhancedUserInterface(true);
    win.bounds = area; // keep the model in sync with what we requested
}

/// Shrink a rect inward by `by` on every side.
fn inset(r: Rect, by: f64) Rect {
    return .{
        .origin = .{ .x = r.origin.x + by, .y = r.origin.y + by },
        .size = .{ .width = r.size.width - 2 * by, .height = r.size.height - 2 * by },
    };
}
