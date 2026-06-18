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
const animation = @import("animate.zig");

const Rect = macos.window_list.Rect;

/// Whether frame changes should animate. Set from the Lua config
/// (`agate.config{ animations = true }`); speed comes from
/// `animation.duration_ms` (`animation_duration`, milliseconds). See
/// `animate.zig` for how (and within which platform limits) the sweep runs.
pub var animate: bool = false;

/// Smart gaps (Hyprland's `no_gaps_when_only`): when a workspace holds a single
/// tiled window, drop the outer gap so it fills the display edge-to-edge. Set
/// from the Lua config (`agate.config{ smart_gaps = true }`).
pub var smart_gaps: bool = false;

// --- Flow strip tuning (the `SCROLL` layout). Mirrored from the Lua config in
// `api.agateConfig`; file-scope is safe on the single-threaded main loop. ---

/// Target width (viewport fraction) a column with no explicit `width_frac` gets.
pub var default_column_width: f64 = 0.5;
/// Soft bound: smallest column width (viewport fraction) before the strip scrolls.
/// While every column fits at this width the strip tiles the whole viewport.
pub var min_column_width: f64 = 0.22;
/// Edge-peek width (points): the sliver of a fully off-screen column kept visible
/// at the screen edge once the strip scrolls (also the macOS off-screen fix).
pub var scroll_sliver: f64 = 24;

/// Whether a live trackpad swipe is currently driving the active workspace's
/// `scroll_offset`. While set, `layoutScroll` leaves the offset alone (the finger
/// owns it) instead of snapping the focused column into view. Set from
/// `config/swipe.zig`. Mirrors `animate`.
pub var scrolling: bool = false;

/// Force this flush to snap (apply frames directly) even when `animate` is on.
/// Set during a live scroll-drag so columns track the finger in lockstep instead
/// of each lagging behind its own ease (paneru snaps during a swipe too — see
/// `position_layout_windows`). Cleared for the release settle, which *does* glide.
pub var snap_now: bool = false;

/// Most columns one strip lays out. Past this the extra columns are dropped from
/// the pass (they'd be off-screen regardless) — a workspace with this many
/// columns is already well past any sane capacity.
const max_columns = 64;

/// The current workspace's full tiling area (after the outer-gap inset), set at
/// the top of each `assignFrames` pass. A leaf marked `fake_full_screen`
/// (yabai's zoom-fullscreen) is given this area instead of its tiled slot, so it
/// fills the whole space while the others keep their frames behind it. Single-
/// threaded main loop, so a file-scope value is safe (same pattern as the
/// animator's fixed buffers).
var zoom_area: Rect = undefined;

/// Whether `con` is a floating leaf — lifted out of the tiling layout (see
/// `data.Window.floating`). Such a leaf is skipped by the split/stack math: it
/// keeps its own frame on top while its siblings tile as if it weren't there.
fn isFloating(con: *data.Con) bool {
    return if (con.window) |w| w.floating else false;
}

/// Lay out and apply a workspace's windows within `area` (the display's usable
/// frame, AX coordinates). The workspace's `outer` gap insets the whole area;
/// children are then split per the container's layout with the `inner` gap
/// between them. The whole pass runs with `AXEnhancedUserInterface` disabled
/// per *application* (see `EuiGuard`) instead of toggling it per window, so
/// every real frame lands instantly and exactly.
///
/// With `animate` on, changed windows get their final SIZE applied here and
/// their position swept over by the animator, which also takes over the EUI
/// guard until the sweep lands (AppKit must not ease the ticks).
pub fn flushWorkspace(ws: *data.Con, area: Rect) void {
    var eui = EuiGuard{};
    eui.disableUnder(ws);
    // `snap_now` (a live scroll-drag) forces the direct path so the columns track
    // the finger exactly instead of easing behind it.
    if (animate and animation.enabled() and !snap_now) {
        animation.begin();
        assignFrames(ws, area, animateSink);
        animation.commit(eui); // guard ownership moves to the animator
        return;
    }
    defer eui.restore();
    assignFrames(ws, area, applySink);
}

/// The animated-flush sink: perceptible frame changes get the final size now
/// (the expensive, relayout-causing half) and a position sweep via the
/// animator; everything else (no real change / animator full / unresolvable
/// element) is applied directly like `applySink`.
fn animateSink(leaf: *data.Con, area: Rect) void {
    const win = &leaf.window.?;
    const from = win.bounds;
    if (!animation.shouldAnimate(from, area)) return applyFrame(win, area);
    // Snap a large jump instead of easing it (paneru's `offscreen_move` rule): a
    // re-tile nudges a window by less than its own width, but shoving a column to
    // its off-screen edge-peek moves it ~a viewport — animating that would fling
    // it across the screen. Snap so on-screen columns glide and edge columns just
    // appear at the edge.
    const dx = @abs(area.origin.x - from.origin.x);
    const dy = @abs(area.origin.y - from.origin.y);
    if (dx > 1.5 * area.size.width or dy > 1.5 * area.size.height) return applyFrame(win, area);
    const el = window.resolveElement(win) orelse return applyFrame(win, area);
    if (!animation.add(el, from, area)) return applyFrame(win, area);
    _ = el.setSize(area.size); // final size at the old position; ticks glide it over
    win.bounds = area; // tree state is the final frame, same as applyFrame
}

/// Compute each leaf's frame under `con` within `area` and hand it to `sink`.
/// The frame *math* lives here; what happens with a computed frame is the
/// sink's business — `flushWorkspace` pushes it onto the real window, tests
/// record it. `sink` is comptime so the recursion stays a plain call.
pub fn assignFrames(con: *data.Con, area: Rect, comptime sink: fn (*data.Con, Rect) void) void {
    // Smart gaps: a lone tiled window fills the display (inner gaps are moot with
    // no siblings, so only the outer inset is suppressed).
    const outer: f64 = if (smart_gaps and con.leafCount() <= 1) 0 else @floatFromInt(con.gaps.outer);
    const top = inset(area, outer);
    zoom_area = top; // a zoom-fullscreen leaf fills the whole space (see `place`)
    layoutChildren(con, top, sink);
}

/// The production sink: apply the computed frame to the leaf's real window.
fn applySink(leaf: *data.Con, area: Rect) void {
    applyFrame(&leaf.window.?, area);
}

/// Split `area` among `con`'s children according to its layout, recursing into
/// nested split containers and emitting frames at the leaves. The main axis
/// (width for H_SPLIT, height for V_SPLIT) is divided in proportion to each
/// child's `ratio`; the cross axis fills the area. (Like yabai's view, each leaf
/// gets its exact computed area — no readback.)
fn layoutChildren(con: *data.Con, area: Rect, comptime sink: fn (*data.Con, Rect) void) void {
    const n = con.children.items.len;
    if (n == 0) return;

    switch (con.layout) {
        .SCROLL => return layoutScroll(con, area, sink),
        .H_STACK, .V_STACK => return layoutStack(con, area, sink),
        // FLOAT: leave each window filling the area (no real float model yet).
        .FLOAT => {
            for (con.children.items) |child| place(child, area, sink);
            return;
        },
        .H_SPLIT, .V_SPLIT => {},
    }

    const horizontal = con.layout == .H_SPLIT;
    const gap: f64 = @floatFromInt(con.gaps.inner);

    // Floating leaves are lifted out of the tiling: they don't take a slot and
    // their weight doesn't count, so the tiled siblings split the area as if the
    // floats weren't there (and the floats keep their own frame, untouched).
    var tiled: usize = 0;
    var total_ratio: f64 = 0;
    for (con.children.items) |child| {
        if (isFloating(child)) continue;
        tiled += 1;
        total_ratio += child.ratio;
    }
    if (tiled == 0) return; // every child floats — nothing to tile
    if (total_ratio <= 0) total_ratio = 1;

    const nf: f64 = @floatFromInt(tiled);
    const avail_main = (if (horizontal) area.size.width else area.size.height) - gap * (nf - 1);

    var offset = if (horizontal) area.origin.x else area.origin.y;
    for (con.children.items) |child| {
        if (isFloating(child)) continue;
        const extent = avail_main * (child.ratio / total_ratio);
        const rect: Rect = if (horizontal) .{
            .origin = .{ .x = offset, .y = area.origin.y },
            .size = .{ .width = extent, .height = area.size.height },
        } else .{
            .origin = .{ .x = area.origin.x, .y = offset },
            .size = .{ .width = area.size.width, .height = extent },
        };
        place(child, rect, sink);
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
fn layoutStack(con: *data.Con, area: Rect, comptime sink: fn (*data.Con, Rect) void) void {
    const horizontal = con.layout == .H_STACK;

    // Floating leaves are lifted out of the fan (see `layoutChildren`): count and
    // step over only the tiled ones, so a float doesn't widen the span or claim a
    // fan position.
    var n: usize = 0;
    for (con.children.items) |child| {
        if (!isFloating(child)) n += 1;
    }
    if (n == 0) return;
    const nf: f64 = @floatFromInt(n);

    const peek: f64 = @floatFromInt(con.gaps.accordion);
    const main = if (horizontal) area.size.width else area.size.height;
    const step: f64 = if (n > 1) @min(peek, (main * 0.5) / (nf - 1)) else 0;
    const span = step * (nf - 1);

    var i: usize = 0;
    for (con.children.items) |child| {
        if (isFloating(child)) continue;
        const off = step * @as(f64, @floatFromInt(i));
        const rect: Rect = if (horizontal) .{
            .origin = .{ .x = area.origin.x + off, .y = area.origin.y },
            .size = .{ .width = area.size.width - span, .height = area.size.height },
        } else .{
            .origin = .{ .x = area.origin.x, .y = area.origin.y + off },
            .size = .{ .width = area.size.width, .height = area.size.height - span },
        };
        place(child, rect, sink);
        i += 1;
    }
}

/// The "Flow" strip (niri/PaperWM via paneru): `ws`'s direct children are
/// columns laid out left→right. While every column fits at `min_column_width`
/// the strip *fills the viewport* like a classic tiler (fit mode); past that
/// capacity it scrolls, keeping off-screen columns as edge peeks (scroll mode).
/// Each column is itself `place`d, so a column that is a nested container tiles
/// its own windows with the classic layouts — traditional tiling inside a column.
fn layoutScroll(ws: *data.Con, area: Rect, comptime sink: fn (*data.Con, Rect) void) void {
    var cols: [max_columns]*data.Con = undefined;
    var out: [max_columns]f64 = undefined;
    const fl = flowWidths(ws, area, &cols, &out);
    if (fl.n == 0) return; // every column floats — nothing to tile

    if (fl.fit) {
        // Fit mode: the columns fill the viewport like a classic tiler, so there
        // is nothing to scroll.
        ws.scroll_offset = 0;
        placeColumns(cols[0..fl.n], out[0..fl.n], area, area.origin.x, fl.gap, sink, false);
    } else {
        // Scroll mode: the strip slides so the focused column stays in view, and
        // off-screen columns peek at the edges (unless a live swipe owns the
        // offset).
        if (!scrolling) ensureColumnVisible(ws, cols[0..fl.n], out[0..fl.n], area, fl.gap);
        placeColumns(cols[0..fl.n], out[0..fl.n], area, area.origin.x - ws.scroll_offset, fl.gap, sink, true);
    }
}

/// Result of `flowWidths`: how many columns were collected, whether the strip
/// fits the viewport (fit mode) or overflows (scroll mode), and the inner gap.
const FlowLayout = struct { n: usize, fit: bool, gap: f64 };

/// Collect `ws`'s tiled columns into `cols` and compute their pixel widths into
/// `out`, applying the fit-vs-scroll rule. Shared by `layoutScroll` (which then
/// places them) and `centerFocusedColumn` (which only needs the geometry). A
/// floating leaf is lifted out of the strip, as in `layoutChildren`.
fn flowWidths(ws: *data.Con, area: Rect, cols: []*data.Con, out: []f64) FlowLayout {
    var weights: [max_columns]f64 = undefined;
    var n: usize = 0;
    var total_t: f64 = 0;
    for (ws.children.items) |child| {
        if (isFloating(child)) continue;
        if (n == max_columns) break;
        const t = if (child.width_frac > 0) child.width_frac else default_column_width;
        cols[n] = child;
        weights[n] = t;
        total_t += t;
        n += 1;
    }
    if (n == 0) return .{ .n = 0, .fit = true, .gap = 0 };
    if (total_t <= 0) total_t = 1;

    const W = area.size.width;
    const gap: f64 = @floatFromInt(ws.gaps.inner);
    const nf: f64 = @floatFromInt(n);
    const avail = W - gap * (nf - 1);
    const min_w = min_column_width * W;

    if (nf * min_w <= avail) {
        // Fit mode: proportional to weights, floored at min, summing to avail.
        fitWidths(weights[0..n], out[0..n], avail, min_w);
        return .{ .n = n, .fit = true, .gap = gap };
    }
    // Scroll mode: absolute target widths, floored at min.
    for (0..n) |i| out[i] = @max(min_w, weights[i] * W);
    return .{ .n = n, .fit = false, .gap = gap };
}

/// Set `ws.scroll_offset` so the focused column is centered in the viewport
/// (`agate.scroll("center")`). In fit mode the strip already fills the viewport,
/// so the offset is reset to 0. Called outside the flush; the next flush keeps
/// the centered offset because the column is then fully visible.
pub fn centerFocusedColumn(ws: *data.Con, area: Rect) void {
    var cols: [max_columns]*data.Con = undefined;
    var out: [max_columns]f64 = undefined;
    const fl = flowWidths(ws, area, &cols, &out);
    if (fl.n == 0 or fl.fit) {
        ws.scroll_offset = 0;
        return;
    }
    const focused = validFocusedColumn(ws) orelse return;
    var x: f64 = 0;
    var fx: f64 = 0;
    var fw: f64 = 0;
    var found = false;
    for (cols[0..fl.n], out[0..fl.n]) |c, w| {
        if (c == focused) {
            fx = x;
            fw = w;
            found = true;
        }
        x += w + fl.gap;
    }
    if (!found) return;
    // On-screen left = area.x + fx - offset; center it: fx - off + fw/2 == W/2.
    ws.scroll_offset = fx + fw / 2 - area.size.width / 2;
}

/// Total width (points) of `ws`'s columns laid end to end (widths + inner gaps),
/// or 0 in fit mode (the strip never overflows then). Used to bound scrolling.
fn contentWidth(ws: *data.Con, area: Rect) f64 {
    var cols: [max_columns]*data.Con = undefined;
    var out: [max_columns]f64 = undefined;
    const fl = flowWidths(ws, area, &cols, &out);
    if (fl.n == 0 or fl.fit) return 0;
    var total: f64 = 0;
    for (out[0..fl.n]) |w| total += w + fl.gap;
    return total - fl.gap; // no trailing gap after the last column
}

/// Clamp `ws.scroll_offset` to the legal range `[0, content − viewport]` so a
/// live swipe can't fling the strip past its ends into empty space. Used by the
/// continuous trackpad scroll (`config/swipe.zig`).
pub fn clampScroll(ws: *data.Con, area: Rect) void {
    const total = contentWidth(ws, area);
    if (total <= 0) {
        ws.scroll_offset = 0;
        return;
    }
    const max_off = @max(0, total - area.size.width);
    ws.scroll_offset = std.math.clamp(ws.scroll_offset, 0, max_off);
}

/// Snap `ws.scroll_offset` to the nearest column's left edge, so a swipe settles
/// with a column aligned to the viewport edge instead of mid-column. No-op in fit
/// mode. Called on swipe release (`config/swipe.zig`).
pub fn snapStrip(ws: *data.Con, area: Rect) void {
    var cols: [max_columns]*data.Con = undefined;
    var out: [max_columns]f64 = undefined;
    const fl = flowWidths(ws, area, &cols, &out);
    if (fl.n == 0 or fl.fit) {
        ws.scroll_offset = 0;
        return;
    }
    var x: f64 = 0;
    var best: f64 = 0;
    var best_dist: f64 = std.math.floatMax(f64);
    for (out[0..fl.n]) |w| {
        const d = @abs(x - ws.scroll_offset);
        if (d < best_dist) {
            best_dist = d;
            best = x;
        }
        x += w + fl.gap;
    }
    const total = x - fl.gap;
    const max_off = @max(0, total - area.size.width);
    ws.scroll_offset = std.math.clamp(best, 0, max_off);
}

/// Distribute `avail` points among columns in proportion to `weights`, with each
/// column floored at `min_w`. Standard iterative water-filling: pin any column
/// whose proportional share falls below `min_w` to exactly `min_w` and re-divide
/// the rest among the unpinned, until no new pins appear. The caller guarantees
/// `n * min_w <= avail`, so the result sums to `avail`.
fn fitWidths(weights: []const f64, out: []f64, avail: f64, min_w: f64) void {
    const n = weights.len;
    var pinned: [max_columns]bool = undefined;
    for (0..n) |i| pinned[i] = false;

    while (true) {
        var rem_avail = avail;
        var rem_weight: f64 = 0;
        for (0..n) |i| {
            if (pinned[i]) rem_avail -= min_w else rem_weight += weights[i];
        }
        if (rem_weight <= 0) {
            for (0..n) |i| if (!pinned[i]) {
                out[i] = min_w;
            };
            return;
        }
        var newly_pinned = false;
        for (0..n) |i| {
            if (pinned[i]) continue;
            const px = rem_avail * (weights[i] / rem_weight);
            if (px < min_w) {
                pinned[i] = true;
                out[i] = min_w;
                newly_pinned = true;
            } else {
                out[i] = px;
            }
        }
        if (!newly_pinned) return;
    }
}

/// Place each column left→right starting at `base` (the strip's left edge in
/// screen coords), advancing by width + inner gap. In scroll mode a column that
/// would sit fully off-screen is clamped to a `scroll_sliver`-wide edge peek (the
/// columns inside slide with it). Mirrors paneru's edge math in
/// `position_layout_windows` (src/ecs/layout.rs).
fn placeColumns(
    cols: []const *data.Con,
    widths: []const f64,
    area: Rect,
    base: f64,
    gap: f64,
    comptime sink: fn (*data.Con, Rect) void,
    scroll_mode: bool,
) void {
    var cursor = base;
    for (cols, widths) |col, w| {
        var rect: Rect = .{
            .origin = .{ .x = cursor, .y = area.origin.y },
            .size = .{ .width = w, .height = area.size.height },
        };
        if (scroll_mode) rect = peekClamp(rect, area);
        place(col, rect, sink);
        cursor += w + gap;
    }
}

/// Keep a fully off-screen column as a thin sliver at the screen edge: macOS
/// relocates windows pushed *entirely* off-screen, and a peek is friendlier than
/// a vanished window. A column straddling the edge is left where it is.
fn peekClamp(rect: Rect, area: Rect) Rect {
    const left = area.origin.x;
    const right = area.origin.x + area.size.width;
    var r = rect;
    if (r.origin.x + r.size.width <= left + scroll_sliver) {
        r.origin.x = left - r.size.width + scroll_sliver; // peek on the left edge
    } else if (r.origin.x >= right - scroll_sliver) {
        r.origin.x = right - scroll_sliver; // peek on the right edge
    }
    return r;
}

/// Nudge `ws.scroll_offset` by the minimum needed to bring the focused column
/// (`ws.last_focused_child`, validated against the current children) fully into
/// the viewport. If it already fits, the offset is untouched. Mirrors paneru's
/// `ensure_visible_in_strip` (src/ecs/layout.rs).
fn ensureColumnVisible(ws: *data.Con, cols: []const *data.Con, widths: []const f64, area: Rect, gap: f64) void {
    const focused = validFocusedColumn(ws) orelse return;
    var x: f64 = 0; // left edge of each column in strip coords (offset 0)
    var fx: f64 = 0;
    var fw: f64 = 0;
    var found = false;
    for (cols, widths) |c, w| {
        if (c == focused) {
            fx = x;
            fw = w;
            found = true;
        }
        x += w + gap;
    }
    if (!found) return;

    const W = area.size.width;
    var off = ws.scroll_offset;
    const left_rel = fx - off; // column's left edge relative to the viewport
    const right_rel = left_rel + fw;
    if (left_rel < 0) {
        off += left_rel; // scroll to reveal the left edge
    } else if (right_rel > W) {
        off += right_rel - W; // scroll to reveal the right edge
    }
    ws.scroll_offset = off;
}

/// The focused column of a `SCROLL` workspace: its `last_focused_child` when that
/// is still one of its children (the breadcrumb `focus.recordFocusPath` keeps),
/// else null. A column is always a direct child of the workspace.
fn validFocusedColumn(ws: *data.Con) ?*data.Con {
    const lf = ws.last_focused_child orelse return null;
    for (ws.children.items) |c| if (c == lf) return lf;
    return null;
}

/// Emit `area` for a leaf window, or recurse if it's a nested split container.
fn place(con: *data.Con, area: Rect, comptime sink: fn (*data.Con, Rect) void) void {
    if (con.window) |win| {
        // A zoom-fullscreen window ignores its tiled slot and fills the space.
        sink(con, if (win.fake_full_screen) zoom_area else area);
    } else {
        layoutChildren(con, area, sink);
    }
}

/// Push a frame onto the real window (AX element resolved lazily). This is a
/// direct port of yabai's `window_manager_set_window_frame`
/// (koekeishiya/yabai, src/window_manager.c): apply size → position → size.
/// macOS clamps a window to the visible area, so the size may need setting both
/// before the move (so the position isn't clamped to the old, larger extent) and
/// after it. Runs inside `flushWorkspace`'s `EuiGuard` window, so AppKit applies
/// the change instantly instead of animating it.
fn applyFrame(win: *data.Window, area: Rect) void {
    const el = window.resolveElement(win) orelse return;
    _ = el.setSize(area.size);
    _ = el.setPosition(area.origin);
    _ = el.setSize(area.size);
    win.bounds = area; // keep the model in sync with what we requested
}

/// How many distinct apps one flush will toggle EUI for. Past the cap, the
/// extra apps keep their setting (their windows may animate — harmless).
const max_eui_apps = 32;

/// Per-flush batching of yabai's `AX_ENHANCED_UI_WORKAROUND` (src/misc/helpers.h):
/// `AXEnhancedUserInterface` — which macOS turns on for any app an assistive
/// client attaches to — makes AppKit *animate* AX-driven frame changes. The
/// attribute lives on the *application* element, so disabling it once per app
/// for the whole flush (instead of around every window, as before) saves an
/// app-element create plus a get/set/set AX round-trip per extra window of the
/// same app.
pub const EuiGuard = struct {
    pids: [max_eui_apps]i32 = undefined,
    /// Retained app elements that had EUI on (to restore); null = was off.
    apps: [max_eui_apps]?*macos.Element = undefined,
    count: usize = 0,

    /// Disable EUI for every distinct app owning a window under `con`.
    pub fn disableUnder(self: *EuiGuard, con: *data.Con) void {
        if (con.window) |w| self.disablePid(w.pid);
        for (con.children.items) |child| self.disableUnder(child);
    }

    fn disablePid(self: *EuiGuard, pid: i32) void {
        for (self.pids[0..self.count]) |p| if (p == pid) return; // already handled
        if (self.count == max_eui_apps) return;
        const app = macos.Element.createApplication(pid) orelse return;
        if (app.enhancedUserInterface()) {
            app.setEnhancedUserInterface(false);
            self.apps[self.count] = app; // keep retained for restore()
        } else {
            app.release();
            self.apps[self.count] = null;
        }
        self.pids[self.count] = pid;
        self.count += 1;
    }

    pub fn restore(self: *EuiGuard) void {
        for (self.apps[0..self.count]) |maybe_app| {
            const app = maybe_app orelse continue;
            app.setEnhancedUserInterface(true);
            app.release();
        }
        self.count = 0;
    }
};

/// Shrink a rect inward by `by` on every side.
fn inset(r: Rect, by: f64) Rect {
    return .{
        .origin = .{ .x = r.origin.x + by, .y = r.origin.y + by },
        .size = .{ .width = r.size.width - 2 * by, .height = r.size.height - 2 * by },
    };
}

// ---------------------------------------------------------------------------
// Tests — drive `assignFrames` with a sink that records each leaf's computed
// frame into its window bounds, so no Accessibility calls happen.
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn recordSink(leaf: *data.Con, area: Rect) void {
    leaf.window.?.bounds = area;
}

fn testRect(x: f64, y: f64, w: f64, h: f64) Rect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn testLeaf(alloc: std.mem.Allocator, parent: *data.Con, id: u32, ratio: f64) !*data.Con {
    const con = try alloc.create(data.Con);
    con.* = .{
        .id = id,
        .con_type = .Container,
        .parent = parent,
        .depth = parent.depth + 1,
        .ratio = ratio,
        .window = .{ .id = id, .pid = 1, .owner = "test", .bounds = testRect(0, 0, 0, 0) },
    };
    try parent.children.append(alloc, con);
    return con;
}

fn testContainer(alloc: std.mem.Allocator, con_type: data.Con.Type, layout: data.Layout) !*data.Con {
    const con = try alloc.create(data.Con);
    con.* = .{ .id = 0, .con_type = con_type, .layout = layout };
    return con;
}

fn expectRect(expected: Rect, actual: Rect) !void {
    try testing.expectApproxEqAbs(expected.origin.x, actual.origin.x, 0.001);
    try testing.expectApproxEqAbs(expected.origin.y, actual.origin.y, 0.001);
    try testing.expectApproxEqAbs(expected.size.width, actual.size.width, 0.001);
    try testing.expectApproxEqAbs(expected.size.height, actual.size.height, 0.001);
}

test "H_SPLIT divides the width by ratio with inner gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .H_SPLIT);
    ws.gaps = .{ .inner = 10, .outer = 0, .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 3.0);

    assignFrames(ws, testRect(0, 0, 410, 200), recordSink);
    // 410 minus one 10px gap = 400 to share 1:3 → 100 and 300.
    try expectRect(testRect(0, 0, 100, 200), a.window.?.bounds);
    try expectRect(testRect(110, 0, 300, 200), b.window.?.bounds);
}

test "V_SPLIT divides the height; outer gap insets the whole area" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .V_SPLIT);
    ws.gaps = .{ .inner = 0, .outer = 10, .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);

    assignFrames(ws, testRect(0, 0, 100, 220), recordSink);
    // Outer gap shrinks the area to (10,10,80,200); halves stack vertically.
    try expectRect(testRect(10, 10, 80, 100), a.window.?.bounds);
    try expectRect(testRect(10, 110, 80, 100), b.window.?.bounds);
}

test "nested split container subdivides its slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .H_SPLIT);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const sub = try testContainer(alloc, .Container, .V_SPLIT);
    sub.parent = ws;
    sub.depth = ws.depth + 1;
    try ws.children.append(alloc, sub);
    const b1 = try testLeaf(alloc, sub, 2, 1.0);
    const b2 = try testLeaf(alloc, sub, 3, 1.0);

    assignFrames(ws, testRect(0, 0, 200, 100), recordSink);
    try expectRect(testRect(0, 0, 100, 100), a.window.?.bounds);
    try expectRect(testRect(100, 0, 100, 50), b1.window.?.bounds);
    try expectRect(testRect(100, 50, 100, 50), b2.window.?.bounds);
}

test "zoom-fullscreen leaf fills the whole space; siblings keep their slots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .H_SPLIT);
    ws.gaps = .{ .inner = 0, .outer = 10, .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    b.window.?.fake_full_screen = true;

    assignFrames(ws, testRect(0, 0, 220, 120), recordSink);
    // Outer gap shrinks the area to (10,10,200,100). a keeps its tiled half;
    // the zoomed b ignores its slot and fills the full (inset) workspace area.
    try expectRect(testRect(10, 10, 100, 100), a.window.?.bounds);
    try expectRect(testRect(10, 10, 200, 100), b.window.?.bounds);
}

test "V_STACK fans by the accordion peek, clamped to half the area" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .V_STACK);
    ws.gaps.accordion = 40;
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    const c2 = try testLeaf(alloc, ws, 3, 1.0);

    assignFrames(ws, testRect(0, 0, 100, 100), recordSink);
    // peek 40 clamps to (100*0.5)/2 = 25 per step; span 50; all share height 50.
    try expectRect(testRect(0, 0, 100, 50), a.window.?.bounds);
    try expectRect(testRect(0, 25, 100, 50), b.window.?.bounds);
    try expectRect(testRect(0, 50, 100, 50), c2.window.?.bounds);
}

test "a floating leaf is skipped: tiled siblings split as if it weren't there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .H_SPLIT);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const f = try testLeaf(alloc, ws, 2, 1.0);
    const b = try testLeaf(alloc, ws, 3, 1.0);
    // Float the middle window and seed a frame the flush must leave untouched.
    f.window.?.floating = true;
    f.window.?.bounds = testRect(11, 22, 33, 44);

    assignFrames(ws, testRect(0, 0, 200, 100), recordSink);
    // a and b share the full width 1:1 (the float takes no slot, no weight).
    try expectRect(testRect(0, 0, 100, 100), a.window.?.bounds);
    try expectRect(testRect(100, 0, 100, 100), b.window.?.bounds);
    // The floating window keeps its own frame — the flush never placed it.
    try expectRect(testRect(11, 22, 33, 44), f.window.?.bounds);
}

test "smart gaps drop the outer inset for a lone window, keep it for two" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    smart_gaps = true;
    defer smart_gaps = false;

    // One window: outer gap suppressed, fills the whole area.
    const solo = try testContainer(alloc, .Workspace, .H_SPLIT);
    solo.gaps = .{ .inner = 8, .outer = 8, .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const only = try testLeaf(alloc, solo, 1, 1.0);
    assignFrames(solo, testRect(0, 0, 400, 300), recordSink);
    try expectRect(testRect(0, 0, 400, 300), only.window.?.bounds);

    // Two windows: the outer inset applies again (8px on every side).
    const pair = try testContainer(alloc, .Workspace, .H_SPLIT);
    pair.gaps = .{ .inner = 0, .outer = 8, .top = 0, .bottom = 0, .left = 0, .right = 0 };
    const a = try testLeaf(alloc, pair, 1, 1.0);
    const b = try testLeaf(alloc, pair, 2, 1.0);
    assignFrames(pair, testRect(0, 0, 400, 300), recordSink);
    // area inset to (8,8,384,284); split in half horizontally (inner gap 0).
    try expectRect(testRect(8, 8, 192, 284), a.window.?.bounds);
    try expectRect(testRect(200, 8, 192, 284), b.window.?.bounds);
}

test "single window fills the workspace area" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ws = try testContainer(alloc, .Workspace, .H_SPLIT);
    const a = try testLeaf(alloc, ws, 1, 1.0);

    assignFrames(ws, testRect(0, 25, 1512, 920), recordSink);
    try expectRect(testRect(0, 25, 1512, 920), a.window.?.bounds);
}

// ---------------------------------------------------------------------------
// Flow strip (SCROLL) tests.
// ---------------------------------------------------------------------------

/// Reset the Flow tuning to defaults around a test (file-scope mutable state).
fn resetFlowDefaults() void {
    default_column_width = 0.5;
    min_column_width = 0.22;
    scroll_sliver = 24;
    scrolling = false;
}

test "SCROLL fit mode: equal-weight columns fill the viewport like H_SPLIT" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Three default (0.5) columns: 3 * 0.22 = 0.66 <= 1, so fit mode. Equal
    // weights split the 1200px viewport into even thirds (no inner gap).
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    const c = try testLeaf(alloc, ws, 3, 1.0);

    assignFrames(ws, testRect(0, 0, 1200, 800), recordSink);
    try expectRect(testRect(0, 0, 400, 800), a.window.?.bounds);
    try expectRect(testRect(400, 0, 400, 800), b.window.?.bounds);
    try expectRect(testRect(800, 0, 400, 800), c.window.?.bounds);
    try testing.expectEqual(@as(f64, 0), ws.scroll_offset);
}

test "SCROLL fit mode: per-column width_frac biases the split" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Two columns weighted 1:3 fill the viewport in those proportions.
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    a.width_frac = 0.25;
    b.width_frac = 0.75;

    assignFrames(ws, testRect(0, 0, 1000, 600), recordSink);
    try expectRect(testRect(0, 0, 250, 600), a.window.?.bounds);
    try expectRect(testRect(250, 0, 750, 600), b.window.?.bounds);
}

test "SCROLL fit mode: a column is floored at min_column_width" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // min 0.2 of 1000 = 200px. A tiny-weighted column is pinned to 200; the
    // other takes the remaining 800. Still fit mode (2 * 200 <= 1000).
    min_column_width = 0.2;
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    a.width_frac = 0.01;
    b.width_frac = 0.99;

    assignFrames(ws, testRect(0, 0, 1000, 600), recordSink);
    try expectRect(testRect(0, 0, 200, 600), a.window.?.bounds);
    try expectRect(testRect(200, 0, 800, 600), b.window.?.bounds);
}

test "SCROLL scroll mode: past capacity columns keep target width and scroll" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // min 0.3 of 1000 = 300px capacity = floor(1000/300) = 3 columns. Four
    // 0.5-width (500px) columns exceed it → scroll mode, each at 500px.
    min_column_width = 0.3;
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    const c = try testLeaf(alloc, ws, 3, 1.0);
    const d = try testLeaf(alloc, ws, 4, 1.0);
    for ([_]*data.Con{ a, b, c, d }) |col| col.width_frac = 0.5;

    // Focus the third column; the strip scrolls just enough to reveal it.
    ws.last_focused_child = c;
    assignFrames(ws, testRect(0, 0, 1000, 600), recordSink);

    // c's strip-left is 1000; to fit its right edge (1500) in the 1000 viewport
    // the offset becomes 500, so c lands at x=500 and fills to the right edge.
    try testing.expectEqual(@as(f64, 500), ws.scroll_offset);
    try expectRect(testRect(500, 0, 500, 600), c.window.?.bounds);
    try testing.expectEqual(@as(f64, 500), d.window.?.bounds.size.width);
}

test "SCROLL scroll mode: an off-screen column is clamped to an edge peek" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    min_column_width = 0.3;
    scroll_sliver = 20;
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const b = try testLeaf(alloc, ws, 2, 1.0);
    const c = try testLeaf(alloc, ws, 3, 1.0);
    const d = try testLeaf(alloc, ws, 4, 1.0);
    for ([_]*data.Con{ a, b, c, d }) |col| col.width_frac = 0.5;

    ws.last_focused_child = d; // focus last → offset 1000, a is far off-left
    assignFrames(ws, testRect(0, 0, 1000, 600), recordSink);

    // a would sit at x = -1000 (fully off-screen); it's clamped so 20px peeks
    // at the left edge: x = 0 - 500 + 20 = -480 (right edge at +20).
    try expectRect(testRect(-480, 0, 500, 600), a.window.?.bounds);
    // d is the focused last column, flush against the right edge.
    try expectRect(testRect(500, 0, 500, 600), d.window.?.bounds);
}

test "SCROLL: a column that is a nested split tiles internally" {
    resetFlowDefaults();
    defer resetFlowDefaults();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Two columns; the second is a vertical split of two windows. Classic tiling
    // lives inside the column.
    const ws = try testContainer(alloc, .Workspace, .SCROLL);
    const a = try testLeaf(alloc, ws, 1, 1.0);
    const col = try testContainer(alloc, .Container, .V_SPLIT);
    col.parent = ws;
    col.depth = ws.depth + 1;
    try ws.children.append(alloc, col);
    const b1 = try testLeaf(alloc, col, 2, 1.0);
    const b2 = try testLeaf(alloc, col, 3, 1.0);

    assignFrames(ws, testRect(0, 0, 1000, 800), recordSink);
    // Two equal columns of 500px; the right one splits its height.
    try expectRect(testRect(0, 0, 500, 800), a.window.?.bounds);
    try expectRect(testRect(500, 0, 500, 400), b1.window.?.bounds);
    try expectRect(testRect(500, 400, 500, 400), b2.window.?.bounds);
}
