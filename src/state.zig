const std = @import("std");
const data = @import("./wm/data.zig");

/// A window to focus the next time a given Space becomes active. Set when a
/// window is moved to another Space so it stays selected once the user follows
/// it over (yabai keeps a moved window focused). Consumed by the space-change
/// handler when its Space is reached; harmlessly ignored otherwise.
pub const PendingFocus = struct { wid: u32, sid: u64 };

/// A window an assignment rule just sent to another Space, with the
/// `CFAbsoluteTime` of the move. The app activating around its own launch
/// would otherwise make activation-follow chase the moved window: a duplicate
/// switch racing the rule's own follow, or — for a `follow = false` rule — a
/// switch against the rule's intent. Activation-follow consults this and
/// skips a recently rule-routed window instead.
pub const RuleMoved = struct { wid: u32, at: f64 };

/// A move requested for a window that was in native fullscreen. A fullscreen
/// window can't be sent to a regular Space while fullscreen, so the move command
/// exits fullscreen and records the target here; once the window lands back on a
/// user Space (a later space-change), the move is carried out. See
/// `lua_config.runPendingMove`.
pub const PendingMove = struct { wid: u32, target_sid: u64 };

pub const AppState = struct {
    skylight_cid: u32,
    /// Arena for tree-lifetime allocations: Con nodes, their children lists,
    /// and owner strings. Never freed piecemeal.
    arena: std.mem.Allocator,
    /// General-purpose allocator for transient, freed-immediately work (the
    /// arena is for things that live as long as the tree).
    gpa: std.mem.Allocator,
    tree: ?*data.Con,
    /// Recycled Workspace Cons (gpa-tracked list, arena-allocated Cons). A Space
    /// created at runtime (a new desktop, a native-fullscreen Space) gets a
    /// Workspace Con; when that Space is destroyed the empty Con is parked here
    /// and reused for the next new Space, so create/destroy churn (e.g. toggling
    /// fullscreen) doesn't grow the tree arena without bound.
    workspace_pool: std.ArrayListUnmanaged(*data.Con) = .empty,
    /// See `PendingFocus`. Null when there's no deferred focus request.
    pending_focus: ?PendingFocus = null,
    /// See `PendingMove`. Null when no fullscreen-exit move is pending.
    pending_move: ?PendingMove = null,
    /// See `RuleMoved`. Null when no rule move is pending suppression.
    rule_moved: ?RuleMoved = null,
    /// XOR of the stable keys of the displays connected at the last settled
    /// display reconfiguration, so the handler can tell a genuine connect/
    /// disconnect (fire `monitors_changed`) from a mere resolution/arrangement
    /// nudge. 0 until the first reconfiguration is processed.
    monitor_set_hash: u64 = 0,
};
