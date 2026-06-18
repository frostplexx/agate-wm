//! Small Screen Mode: on a small main display (the built-in panel, or anything
//! at or under the configured width), workspaces still on the default split
//! layout switch to an accordion/stack — a straight split is not useful on a
//! tiny screen — and revert when a big display takes over. Re-evaluated on
//! config load and every display reconfiguration.
const std = @import("std");
const macos = @import("macos");
const state = @import("../state.zig");
const tree = @import("../wm/tree.zig");
const data = @import("../wm/data.zig");
const types = @import("types.zig");
const ctx = @import("context.zig");

/// Whether the screen being worked on counts as "small": the built-in panel
/// is the *only* display (a MacBook on the go — the case the mode exists for),
/// or the visible frame is at or under the configured width threshold (for
/// users who call e.g. a 13" external small). The only-display test matters:
/// keying on "is the primary display built-in" while an external monitor is
/// attached used to flip the accordion on for the big screen too.
fn isSmallScreen(cfg: *const types.Config) bool {
    if (macos.display.builtinIsOnlyDisplay()) return true;
    if (cfg.small_screen_max_width > 0) {
        if (macos.display.mainVisibleFrame()) |frame| {
            return frame.size.width <= cfg.small_screen_max_width;
        }
    }
    return false;
}

/// Re-evaluate Small Screen Mode against the current display and rewrite
/// workspace layouts accordingly. Returns true if any workspace changed (the
/// caller re-flushes). Called after config load and on every display
/// reconfiguration (clamshell, dock/undock) — the moments "which screen am I
/// on" can change.
pub fn applySmallScreenMode(app: *state.AppState) bool {
    const cfg = ctx.config orelse return false;
    if (!cfg.small_screen_enabled) return false;
    const root = app.tree orelse return false;
    const peek: u32 = if (cfg.small_screen_tabs) 0 else @intFromFloat(@max(0, cfg.peek));
    const normal_peek: u32 = @intFromFloat(@max(0, cfg.peek));
    return applySmallLayoutToTree(root, isSmallScreen(cfg), cfg.small_screen_layout, peek, normal_peek);
}

/// The tree rewrite behind `applySmallScreenMode`, OS-free for testability.
/// Entering small mode moves workspaces from the stock `.H_SPLIT` to `layout`
/// (with `small_peek` as the accordion fan — 0 for the tabs variant), marking
/// them `auto_small`; leaving it reverts exactly the marked ones. A layout the
/// user picked by hand (float, v_split, a manual accordion — anything via
/// `agate.layout`, which clears the mark) survives mode flips. Returns true if
/// anything changed.
fn applySmallLayoutToTree(con: *data.Con, small: bool, layout: data.Layout, small_peek: u32, normal_peek: u32) bool {
    var changed = false;
    if (con.con_type == .Workspace) {
        if (small and con.layout == .H_SPLIT) {
            con.layout = layout;
            con.gaps.accordion = small_peek;
            con.auto_small = true;
            changed = true;
        } else if (!small and con.auto_small) {
            con.layout = .H_SPLIT;
            con.gaps.accordion = normal_peek;
            con.auto_small = false;
            changed = true;
        }
    }
    for (con.children.items) |child| {
        if (applySmallLayoutToTree(child, small, layout, small_peek, normal_peek)) changed = true;
    }
    return changed;
}

const testing = std.testing;

test "applySmallLayoutToTree flips default workspaces in and out of small mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try alloc.create(data.Con);
    root.* = .{ .id = 0, .con_type = .Root };
    const ws_default = try alloc.create(data.Con);
    ws_default.* = .{ .id = 1, .con_type = .Workspace, .parent = root };
    ws_default.gaps.accordion = 40;
    const ws_manual = try alloc.create(data.Con);
    ws_manual.* = .{ .id = 2, .con_type = .Workspace, .parent = root, .layout = .FLOAT };
    try root.children.append(alloc, ws_default);
    try root.children.append(alloc, ws_manual);

    // Enter small mode (tabs variant: zero peek): only the default ws changes.
    try testing.expect(applySmallLayoutToTree(root, true, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_STACK, ws_default.layout);
    try testing.expect(ws_default.auto_small);
    try testing.expectEqual(@as(u32, 0), ws_default.gaps.accordion);
    try testing.expectEqual(data.Layout.FLOAT, ws_manual.layout);

    // Already small — applying again is a no-op.
    try testing.expect(!applySmallLayoutToTree(root, true, .H_STACK, 0, 40));

    // Leave small mode: the auto-set workspace reverts, peek restored.
    try testing.expect(applySmallLayoutToTree(root, false, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_SPLIT, ws_default.layout);
    try testing.expect(!ws_default.auto_small);
    try testing.expectEqual(@as(u32, 40), ws_default.gaps.accordion);

    // A user-chosen H_STACK (no auto_small mark) is never reverted.
    ws_manual.layout = .H_STACK;
    try testing.expect(!applySmallLayoutToTree(root, false, .H_STACK, 0, 40));
    try testing.expectEqual(data.Layout.H_STACK, ws_manual.layout);
}
