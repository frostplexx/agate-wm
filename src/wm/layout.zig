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

/// The current workspace's full tiling area (after the outer-gap inset), set at
/// the top of each `assignFrames` pass. A leaf marked `fake_full_screen`
/// (yabai's zoom-fullscreen) is given this area instead of its tiled slot, so it
/// fills the whole space while the others keep their frames behind it. Single-
/// threaded main loop, so a file-scope value is safe (same pattern as the
/// animator's fixed buffers).
var zoom_area: Rect = undefined;

/// Count the leaf (real-window) cons under `con`. Used by smart gaps to detect
/// the "only one window" workspace.
fn leafCount(con: *data.Con) usize {
    if (con.window != null) return 1;
    var total: usize = 0;
    for (con.children.items) |child| total += leafCount(child);
    return total;
}

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
    if (animate and animation.enabled()) {
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
    const outer: f64 = if (smart_gaps and leafCount(con) <= 1) 0 else @floatFromInt(con.gaps.outer);
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
