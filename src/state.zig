const std = @import("std");
const data = @import("./wm/data.zig");

/// A window to focus the next time a given Space becomes active. Set when a
/// window is moved to another Space so it stays selected once the user follows
/// it over (yabai keeps a moved window focused). Consumed by the space-change
/// handler when its Space is reached; harmlessly ignored otherwise.
pub const PendingFocus = struct { wid: u32, sid: u64 };

pub const AppState = struct {
    skylight_cid: u32,
    arena: std.mem.Allocator ,
    /// General-purpose allocator for transient, freed-immediately work (the
    /// arena is for things that live as long as the tree).
    gpa: std.mem.Allocator,
    tree: ?*data.Con,
    /// See `PendingFocus`. Null when there's no deferred focus request.
    pending_focus: ?PendingFocus = null,
};
