//! The single source of truth for "what displays are connected and how are they
//! identified" — the join the rest of the WM was doing ad-hoc in three places.
//!
//! Two coordinate systems describe a display, and conflating them was the root
//! of the multi-monitor instability:
//!
//!   * SkyLight (`SLSCopyManagedDisplaySpaces`) identifies a display by a UUID
//!     *string* and enumerates them in an order (`display_index`) that is NOT
//!     stable across reconfiguration — unplugging/replugging a monitor reshuffles
//!     it. The window-server Space queries are keyed by this order.
//!   * AppKit (`NSScreen`) identifies a display by `CGDirectDisplayID` and knows
//!     its geometry.
//!
//! `CGDisplayCreateUUIDFromDisplayID` bridges the two. This module performs that
//! join once and hands back a stable, sorted view:
//!
//!   * `key` — a hash of the UUID, the *stable* identity a Monitor Con is keyed
//!     by, so the tree survives a display being added/removed/reordered.
//!   * `arrangement` — 1-based spatial order (left→right, then top→bottom), the
//!     intuitive number the user addresses a monitor with (`agate.rule{monitor=2}`).
//!   * `display_index` — the window-server enumeration index, used *only* to
//!     drive the SkyLight Space queries (which still want it).
const std = @import("std");
const c = @import("c.zig").c;
const sl = @import("skylight.zig");
const spaces = @import("spaces.zig");
const display = @import("display.zig");

const Rect = display.Rect;

/// Upper bound on physical displays for the stack buffers callers pass in.
pub const max_monitors = 16;

extern fn CGMainDisplayID() u32;

/// A connected display, joined from SkyLight + NSScreen and tagged with both a
/// stable identity (`key`) and a user-facing order (`arrangement`).
pub const Monitor = struct {
    /// CGDisplay UUID string (matches `SLSCopyManagedDisplaySpaces`). NUL-free.
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    /// Stable identity: a hash of `uuid`. A Monitor Con's `id` is this, so the
    /// tree keeps pointing at the right physical display across reconfiguration.
    key: u64 = 0,
    /// CGDirectDisplayID (NSScreenNumber).
    display_id: u32 = 0,
    /// The window-server enumeration index — drives SkyLight Space queries only.
    /// NOT stable across reconfiguration; never use it as an identity.
    display_index: usize = 0,
    /// 1-based spatial order (left→right, then top→bottom): the number the user
    /// addresses this monitor with. Stable for a fixed physical arrangement.
    arrangement: usize = 0,
    /// Visible frame (menu bar / Dock excluded) in top-left AX coordinates.
    frame: Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    /// The Space currently shown on this display.
    current_space: u64 = 0,
    /// Localized display name. NUL-free.
    name: [128]u8 = undefined,
    name_len: usize = 0,
    /// Whether this is the arrangement-primary display (`CGMainDisplayID`).
    is_main: bool = false,

    pub fn uuidSlice(self: *const Monitor) []const u8 {
        return self.uuid[0..self.uuid_len];
    }
    pub fn nameSlice(self: *const Monitor) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// The stable Monitor-Con key for a display UUID (defined in `display.zig` so
/// `spaces.zig` can use it without a circular import). Re-exported here as the
/// natural home for monitor identity.
pub const keyForUUID = display.keyForUUID;

/// Every connected display, joined and sorted by `arrangement`, written into
/// `buf` (a caller-owned stack buffer — displays are few). Returns the filled
/// prefix. The window-server view is authoritative for *which* displays exist
/// and their current Space; NSScreen supplies geometry and name.
pub fn enumerate(buf: []Monitor, cid: sl.ConnectionID) []Monitor {
    var md_buf: [max_monitors]spaces.ManagedDisplay = undefined;
    const mds = spaces.managedDisplays(&md_buf, cid);
    if (mds.len == 0) return buf[0..0];

    var frame_buf: [max_monitors]display.DisplayFrame = undefined;
    const frames = display.displayFrames(&frame_buf);

    const main_id = CGMainDisplayID();

    var n: usize = 0;
    for (mds, 0..) |md, di| {
        if (n >= buf.len) break;
        const df = frameForUUID(frames, md.uuidSlice()) orelse continue; // not an NSScreen we see
        var m = Monitor{
            .key = keyForUUID(md.uuidSlice()),
            .display_id = df.display_id,
            .display_index = di,
            .frame = df.frame,
            .current_space = md.current_space,
            .is_main = df.display_id == main_id,
        };
        @memcpy(m.uuid[0..md.uuidSlice().len], md.uuidSlice());
        m.uuid_len = md.uuidSlice().len;
        const nm = df.nameSlice();
        @memcpy(m.name[0..nm.len], nm);
        m.name_len = nm.len;
        buf[n] = m;
        n += 1;
    }

    const out = buf[0..n];
    // Spatial order: left→right, then top→bottom. Assign 1-based arrangement.
    std.mem.sort(Monitor, out, {}, lessByPosition);
    for (out, 0..) |*m, i| m.arrangement = i + 1;
    return out;
}

fn lessByPosition(_: void, a: Monitor, b: Monitor) bool {
    if (a.frame.origin.x != b.frame.origin.x) return a.frame.origin.x < b.frame.origin.x;
    return a.frame.origin.y < b.frame.origin.y;
}

/// The `DisplayFrame` whose UUID matches `uuid`, or null.
fn frameForUUID(frames: []const display.DisplayFrame, uuid: []const u8) ?*const display.DisplayFrame {
    if (uuid.len == 0) return null;
    for (frames) |*f| {
        if (std.mem.eql(u8, f.uuidSlice(), uuid)) return f;
    }
    return null;
}

/// The window-server `display_index` of the display at 1-based `arrangement`,
/// for driving the SkyLight Space queries. Null if no such monitor.
pub fn displayIndexForArrangement(cid: sl.ConnectionID, arrangement: usize) ?usize {
    if (arrangement == 0) return null;
    var buf: [max_monitors]Monitor = undefined;
    const mons = enumerate(&buf, cid);
    for (mons) |m| if (m.arrangement == arrangement) return m.display_index;
    return null;
}

/// The monitor whose stable `key` is `key`, copied out of a fresh enumeration.
/// Null if that display is no longer connected.
pub fn byKey(cid: sl.ConnectionID, key: u64) ?Monitor {
    var buf: [max_monitors]Monitor = undefined;
    const mons = enumerate(&buf, cid);
    for (mons) |m| if (m.key == key) return m;
    return null;
}

test "keyForUUID is stable and distinguishes UUIDs" {
    const a = keyForUUID("11111111-2222-3333-4444-555555555555");
    const b = keyForUUID("11111111-2222-3333-4444-555555555555");
    const c2 = keyForUUID("99999999-2222-3333-4444-555555555555");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c2);
}
