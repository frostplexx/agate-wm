const std = @import("std");
const data = @import("./wm/data.zig");

pub const AppState = struct { 
    skylight_cid: u32, 
    arena: std.mem.Allocator ,
    tree: ?*data.Con,
};
