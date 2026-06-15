//! Control socket: a per-user UNIX domain socket the daemon listens on so a
//! second `agate <query>` invocation can ask the running daemon about its live
//! state (windows, apps, workspaces, monitors) — the AeroSpace/yabai client
//! model. The listener is a CFSocket on the *main* run loop, so the accept and
//! request handling run on the same thread that owns the `Con` tree: tree reads
//! need no locking. Requests are one line ("list-windows [--json]"); the daemon
//! writes a text (or JSON) response and closes.
const std = @import("std");
const macos = @import("macos");
const c = macos.c;
const state = @import("state.zig");
const data = @import("wm/data.zig");
const tree = @import("wm/tree.zig");
const focus = @import("wm/focus/focus.zig");

// POSIX socket bits (not surfaced by the Zig 0.16 std the way we need); declared
// directly like the rest of the codebase does for libc calls.
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SHUT_WR: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_RCVTIMEO: c_int = 0x1006;
const SO_SNDTIMEO: c_int = 0x1005;

const sockaddr_un = extern struct {
    sun_len: u8,
    sun_family: u8,
    sun_path: [104]u8,
};

const timeval = extern struct { tv_sec: c_long, tv_usec: c_int };

/// `${TMPDIR:-/tmp}/agate-<uid>.socket` into `buf`, NUL-terminated, or null if
/// it wouldn't fit `sun_path` (104 incl. NUL). Falls back to /tmp if TMPDIR is
/// too long. Shared by the server (bind) and the client (connect).
fn buildSocketPath(buf: []u8) ?[:0]const u8 {
    const uid = std.c.getuid();
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    return writePath(buf, tmp, uid) orelse writePath(buf, "/tmp", uid);
}

fn writePath(buf: []u8, base: []const u8, uid: u32) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf, "{s}/agate-{d}.socket", .{ base, uid }) catch return null;
    if (s.len > 103) return null; // must fit sun_path with its NUL
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn fillAddr(addr: *sockaddr_un, path: []const u8) void {
    addr.* = .{ .sun_len = @sizeOf(sockaddr_un), .sun_family = AF_UNIX, .sun_path = undefined };
    @memset(&addr.sun_path, 0);
    @memcpy(addr.sun_path[0..path.len], path);
}

// ---------------------------------------------------------------------------
// Server (daemon side) — runs on the main run loop
// ---------------------------------------------------------------------------

/// Bind the control socket and register it on the current (main) run loop. Best
/// effort: on any failure the daemon just runs without a control socket (the CLI
/// query commands then report "not running"). Call from the run-loop thread.
pub fn start(app: *state.AppState) void {
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("[ipc] socket() failed; control socket disabled\n", .{});
        return;
    }

    var pathbuf: [108]u8 = undefined;
    const path = buildSocketPath(&pathbuf) orelse {
        std.debug.print("[ipc] socket path too long; control socket disabled\n", .{});
        _ = close(fd);
        return;
    };
    _ = unlink(path.ptr); // clear a stale socket file from a previous run

    var addr: sockaddr_un = undefined;
    fillAddr(&addr, path);
    if (bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("[ipc] bind({s}) failed; control socket disabled\n", .{path});
        _ = close(fd);
        return;
    }
    if (listen(fd, 8) != 0) {
        std.debug.print("[ipc] listen() failed; control socket disabled\n", .{});
        _ = close(fd);
        return;
    }

    var ctx: c.CFSocketContext = .{ .version = 0, .info = app, .retain = null, .release = null, .copyDescription = null };
    const cfsock = c.CFSocketCreateWithNative(c.kCFAllocatorDefault, fd, c.kCFSocketAcceptCallBack, acceptCallback, &ctx) orelse {
        std.debug.print("[ipc] CFSocketCreateWithNative failed; control socket disabled\n", .{});
        _ = close(fd);
        return;
    };
    const src = c.CFSocketCreateRunLoopSource(c.kCFAllocatorDefault, cfsock, 0);
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopCommonModes);
    std.debug.print("[ipc] control socket listening on {s}\n", .{path});
}

/// CFSocket accept callback (main thread). `data` points to the accepted native
/// socket handle; we own it and must close it.
fn acceptCallback(
    s: c.CFSocketRef,
    cb_type: c.CFSocketCallBackType,
    address: c.CFDataRef,
    cb_data: ?*const anyopaque,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = s;
    _ = cb_type;
    _ = address;
    const app: *state.AppState = @ptrCast(@alignCast(info orelse return));
    const handle: *const c.CFSocketNativeHandle = @ptrCast(@alignCast(cb_data orelse return));
    const fd = handle.*;
    defer _ = close(fd);
    handleConnection(app, fd);
}

fn handleConnection(app: *state.AppState, fd: c_int) void {
    // Guard against a client that connects but never sends/closes, which would
    // otherwise wedge the run loop on the blocking read below.
    const tv = timeval{ .tv_sec = 2, .tv_usec = 0 };
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(timeval));
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, @sizeOf(timeval));

    var reqbuf: [512]u8 = undefined;
    const n = readRequest(fd, &reqbuf);
    const req = std.mem.trim(u8, reqbuf[0..n], " \t\r\n");

    var out = std.Io.Writer.Allocating.init(app.gpa);
    defer out.deinit();
    dispatch(app, &out.writer, req) catch {};
    _ = writeAll(fd, out.written());
}

/// Read until the client half-closes (EOF) or the buffer fills — requests are a
/// single short line, and the client shuts down its write side after sending.
fn readRequest(fd: c_int, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = read(fd, buf.ptr + total, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn dispatch(app: *state.AppState, w: *std.Io.Writer, req: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, req, " \t");
    const cmd = it.next() orelse return;
    var json = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
    }
    if (std.mem.eql(u8, cmd, "list-windows")) {
        try writeWindows(w, app, json);
    } else if (std.mem.eql(u8, cmd, "list-apps")) {
        try writeApps(w, app, json);
    } else if (std.mem.eql(u8, cmd, "list-workspaces")) {
        try writeWorkspaces(w, app, json);
    } else if (std.mem.eql(u8, cmd, "list-monitors")) {
        try writeMonitors(w, app, json);
    } else {
        try w.print("ERR unknown request: {s}\n", .{cmd});
    }
}

// ---------------------------------------------------------------------------
// Response builders (read the live tree — main thread)
// ---------------------------------------------------------------------------

fn layoutName(l: data.Layout) []const u8 {
    return switch (l) {
        .H_SPLIT => "h_tiles",
        .V_SPLIT => "v_tiles",
        .H_STACK => "h_stack",
        .V_STACK => "v_stack",
        .FLOAT => "float",
    };
}

fn spaceTypeName(t: i64) []const u8 {
    return switch (t) {
        0 => "user",
        2 => "fullscreen",
        4 => "system",
        else => "other",
    };
}

fn leafCount(con: *data.Con) usize {
    if (con.window != null) return 1;
    var total: usize = 0;
    for (con.children.items) |child| total += leafCount(child);
    return total;
}

fn writeJsonStr(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
}

const WinCtx = struct {
    w: *std.Io.Writer,
    focused: ?*data.Con,
    mon_no: u64,
    ws_no: usize,
    json: bool,
    first: *bool,
};

fn writeWindows(w: *std.Io.Writer, app: *state.AppState, json: bool) !void {
    const root = app.tree orelse {
        if (json) try w.writeAll("[]\n");
        return;
    };
    const focused = focus.currentFocusedLeaf(app);
    var first = true;
    if (json) try w.writeAll("[");
    for (root.children.items) |mon| {
        if (mon.con_type != .Monitor) continue;
        for (mon.children.items, 1..) |ws, wi| {
            if (ws.con_type != .Workspace) continue;
            var ctx = WinCtx{ .w = w, .focused = focused, .mon_no = mon.id + 1, .ws_no = wi, .json = json, .first = &first };
            try walkLeaves(&ctx, ws);
        }
    }
    if (json) try w.writeAll("]\n");
}

/// Emit a row per leaf window under `parent`; `parent.layout` is the layout that
/// governs those leaves (so a nested container reports its own).
fn walkLeaves(ctx: *WinCtx, parent: *data.Con) !void {
    for (parent.children.items) |child| {
        if (child.window) |win| {
            try writeWindowRow(ctx, child, win, parent.layout);
        } else {
            try walkLeaves(ctx, child);
        }
    }
}

fn writeWindowRow(ctx: *WinCtx, leaf: *data.Con, win: data.Window, layout: data.Layout) !void {
    const w = ctx.w;
    const is_focused = ctx.focused != null and ctx.focused.? == leaf;
    const zoom = win.fake_full_screen;
    if (ctx.json) {
        if (!ctx.first.*) try w.writeAll(",");
        ctx.first.* = false;
        try w.writeAll("{\"window-id\":");
        try w.print("{d},\"app\":\"", .{win.id});
        try writeJsonStr(w, win.owner);
        try w.print("\",\"pid\":{d},\"workspace\":{d},\"monitor\":{d},\"layout\":\"{s}\",\"focused\":{},\"fullscreen\":{}}}", .{
            win.pid, ctx.ws_no, ctx.mon_no, layoutName(layout), is_focused, zoom,
        });
    } else {
        try w.print("{d}\t{s}\tws {d}\tmon {d}\t{s}", .{ win.id, win.owner, ctx.ws_no, ctx.mon_no, layoutName(layout) });
        if (is_focused) try w.writeAll("\t(focused)");
        if (zoom) try w.writeAll("\t(fullscreen)");
        try w.writeByte('\n');
    }
}

const AppEntry = struct { pid: i32, name: []const u8, count: usize };

fn collectApps(con: *data.Con, list: *std.ArrayList(AppEntry), alloc: std.mem.Allocator) void {
    if (con.window) |win| {
        for (list.items) |*e| if (e.pid == win.pid) {
            e.count += 1;
            return;
        };
        list.append(alloc, .{ .pid = win.pid, .name = win.owner, .count = 1 }) catch {};
        return;
    }
    for (con.children.items) |child| collectApps(child, list, alloc);
}

fn writeApps(w: *std.Io.Writer, app: *state.AppState, json: bool) !void {
    const root = app.tree orelse {
        if (json) try w.writeAll("[]\n");
        return;
    };
    var list: std.ArrayList(AppEntry) = .empty;
    defer list.deinit(app.gpa);
    collectApps(root, &list, app.gpa);

    if (json) try w.writeAll("[");
    for (list.items, 0..) |e, i| {
        // Resolve the bundle id from the live process (it isn't in the tree).
        var bidbuf: [256]u8 = undefined;
        const bid = macos.workspace.bundleId(e.pid, &bidbuf) orelse "";
        if (json) {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("{\"pid\":");
            try w.print("{d},\"bundle-id\":\"", .{e.pid});
            try writeJsonStr(w, bid);
            try w.writeAll("\",\"app\":\"");
            try writeJsonStr(w, e.name);
            try w.print("\",\"windows\":{d}}}", .{e.count});
        } else {
            try w.print("{d}\t{s}\t{s}\t{d} window{s}\n", .{
                e.pid, if (bid.len == 0) "-" else bid, e.name, e.count, if (e.count == 1) "" else "s",
            });
        }
    }
    if (json) try w.writeAll("]\n");
}

fn currentSpaceOf(mons: []const tree.MonitorInfo, mon: *data.Con) u64 {
    for (mons) |m| if (m.con == mon) return m.current_space;
    return 0;
}

fn writeWorkspaces(w: *std.Io.Writer, app: *state.AppState, json: bool) !void {
    const root = app.tree orelse {
        if (json) try w.writeAll("[]\n");
        return;
    };
    var mbuf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const mons = mbuf[0..tree.collectMonitors(app, &mbuf)];

    var first = true;
    if (json) try w.writeAll("[");
    for (root.children.items) |mon| {
        if (mon.con_type != .Monitor) continue;
        const cur = currentSpaceOf(mons, mon);
        for (mon.children.items, 1..) |ws, wi| {
            if (ws.con_type != .Workspace) continue;
            const visible = ws.id == cur and cur != 0;
            const wins = leafCount(ws);
            if (json) {
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{{\"workspace\":{d},\"monitor\":{d},\"layout\":\"{s}\",\"type\":\"{s}\",\"visible\":{},\"windows\":{d}}}", .{
                    wi, mon.id + 1, layoutName(ws.layout), spaceTypeName(ws.space_type), visible, wins,
                });
            } else {
                try w.print("ws {d}\tmon {d}\t{s}\t{s}\t{d} window{s}", .{
                    wi, mon.id + 1, layoutName(ws.layout), spaceTypeName(ws.space_type), wins, if (wins == 1) "" else "s",
                });
                if (visible) try w.writeAll("\t(visible)");
                try w.writeByte('\n');
            }
        }
    }
    if (json) try w.writeAll("]\n");
}

fn wsNumberForSid(mon: *data.Con, sid: u64) usize {
    for (mon.children.items, 1..) |ws, i| if (ws.id == sid) return i;
    return 0;
}

fn writeMonitors(w: *std.Io.Writer, app: *state.AppState, json: bool) !void {
    var mbuf: [focus.max_monitors]tree.MonitorInfo = undefined;
    const mons = mbuf[0..tree.collectMonitors(app, &mbuf)];

    if (json) try w.writeAll("[");
    for (mons, 0..) |m, i| {
        const no = m.con.id + 1;
        const f = m.frame;
        const cur_ws = wsNumberForSid(m.con, m.current_space);
        if (json) {
            if (i != 0) try w.writeAll(",");
            try w.print("{{\"monitor\":{d},\"width\":{d:.0},\"height\":{d:.0},\"x\":{d:.0},\"y\":{d:.0},\"current-workspace\":{d}}}", .{
                no, f.size.width, f.size.height, f.origin.x, f.origin.y, cur_ws,
            });
        } else {
            try w.print("mon {d}\t{d:.0}x{d:.0}\t+{d:.0}+{d:.0}\tws {d}\n", .{
                no, f.size.width, f.size.height, f.origin.x, f.origin.y, cur_ws,
            });
        }
    }
    if (json) try w.writeAll("]\n");
}

// ---------------------------------------------------------------------------
// Client (CLI side)
// ---------------------------------------------------------------------------

/// Send `request` to the running daemon and return its full response (caller
/// owns it), or null if no daemon is reachable. No CoreFoundation here — a plain
/// blocking connect/write/read.
pub fn query(alloc: std.mem.Allocator, request: []const u8) ?[]u8 {
    var pathbuf: [108]u8 = undefined;
    const path = buildSocketPath(&pathbuf) orelse return null;

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return null;
    defer _ = close(fd);

    var addr: sockaddr_un = undefined;
    fillAddr(&addr, path);
    if (connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_un)) != 0) return null; // no daemon

    _ = writeAll(fd, request);
    _ = shutdown(fd, SHUT_WR); // signal end of request so the server reads EOF

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(alloc, buf[0..@intCast(n)]) catch break;
    }
    return out.toOwnedSlice(alloc) catch null;
}

// ---------------------------------------------------------------------------
// Tests (the tree-walk / formatting helpers that need no OS state)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testLeaf(a: std.mem.Allocator, parent: *data.Con, id: u32, pid: i32, owner: []const u8) !*data.Con {
    const con = try a.create(data.Con);
    con.* = .{
        .id = id,
        .con_type = .Container,
        .parent = parent,
        .window = .{ .id = id, .pid = pid, .owner = owner, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } } },
    };
    try parent.children.append(a, con);
    return con;
}

test "writeApps groups windows by app (text and json)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try a.create(data.Con);
    root.* = .{ .id = 0, .con_type = .Root };
    const mon = try a.create(data.Con);
    mon.* = .{ .id = 0, .con_type = .Monitor, .parent = root };
    try root.children.append(a, mon);
    const ws = try a.create(data.Con);
    ws.* = .{ .id = 100, .con_type = .Workspace, .parent = mon };
    try mon.children.append(a, ws);
    _ = try testLeaf(a, ws, 1, 501, "Safari");
    _ = try testLeaf(a, ws, 2, 501, "Safari");
    _ = try testLeaf(a, ws, 3, 777, "Notes");

    var app: state.AppState = .{ .skylight_cid = 0, .arena = a, .gpa = testing.allocator, .tree = root };

    // The bundle-id column is resolved from the live process, so assert only on
    // the deterministic parts (grouping, counts, names, row shape).
    var text = std.Io.Writer.Allocating.init(testing.allocator);
    defer text.deinit();
    try writeApps(&text.writer, &app, false);
    try testing.expect(std.mem.startsWith(u8, text.written(), "501\t"));
    try testing.expect(std.mem.indexOf(u8, text.written(), "\tSafari\t2 windows\n") != null);
    try testing.expect(std.mem.indexOf(u8, text.written(), "\tNotes\t1 window\n") != null);

    var json = std.Io.Writer.Allocating.init(testing.allocator);
    defer json.deinit();
    try writeApps(&json.writer, &app, true);
    try testing.expect(std.mem.indexOf(u8, json.written(), "\"pid\":501,\"bundle-id\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, json.written(), "\"app\":\"Safari\",\"windows\":2}") != null);
}

test "writePath builds the socket path and falls back when too long" {
    var buf: [108]u8 = undefined;
    const too_long = "/" ++ ("a" ** 120);
    try testing.expect(writePath(&buf, too_long, 501) == null);
    const p = writePath(&buf, "/tmp", 501).?;
    try testing.expectEqualStrings("/tmp/agate-501.socket", p);
}

test "writeJsonStr escapes quotes and backslashes" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try writeJsonStr(&out.writer, "a\"b\\c\td");
    try testing.expectEqualStrings("a\\\"b\\\\c\\td", out.written());
}
