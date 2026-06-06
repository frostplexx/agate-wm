const std = @import("std");
const data = @import("./wm/data.zig");

pub const AppState = struct {
    skylight_cid: u32,
    arena: std.mem.Allocator ,
    /// General-purpose allocator for transient, freed-immediately work (the
    /// arena is for things that live as long as the tree).
    gpa: std.mem.Allocator,
    tree: ?*data.Con,
};
