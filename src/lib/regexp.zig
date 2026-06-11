//! POSIX extended-regex wrapper (the engine yabai uses for its rules, via
//! <regex.h> from libSystem). `regex_t`'s layout is opaque to us, so it is
//! allocated in C (src/lib/regex_slim.c, compiled into the executable by
//! build.zig) and only handled through a pointer here.
//! https://www.openmymind.net/Regular-Expressions-in-Zig/
const std = @import("std");

pub const regex_t = opaque {};
extern fn alloc_regex_t() ?*regex_t;
extern fn free_regex_t(ptr: *regex_t) void;
extern fn regcomp(preg: *regex_t, pattern: [*:0]const u8, cflags: c_int) c_int;
extern fn regexec(preg: *const regex_t, string: [*:0]const u8, nmatch: usize, pmatch: ?*anyopaque, eflags: c_int) c_int;
extern fn regfree(preg: *regex_t) void;

/// regcomp cflags (values from macOS <regex.h>).
const REG_EXTENDED: c_int = 0x0001;
const REG_NOSUB: c_int = 0x0004;

/// A compiled regular expression. Used for matching window titles and app
/// names in assignment rules (`agate.rule`). Extended POSIX syntax, like
/// yabai's rules (koekeishiya/yabai, src/rule.c uses REG_EXTENDED).
pub const Regex = struct {
    inner: *regex_t,

    pub fn init(pattern: [:0]const u8) !Regex {
        const inner = alloc_regex_t() orelse return error.OutOfMemory;
        // NOSUB: we only ever ask "does it match", never where.
        if (0 != regcomp(inner, pattern, REG_EXTENDED | REG_NOSUB)) {
            free_regex_t(inner);
            return error.compile;
        }
        return .{ .inner = inner };
    }

    pub fn deinit(self: Regex) void {
        regfree(self.inner); // release the compiled program (regcomp succeeded in init)
        free_regex_t(self.inner);
    }

    pub fn matches(self: Regex, input: [:0]const u8) bool {
        return 0 == regexec(self.inner, input, 0, null, 0);
    }
};

test "Regex compiles and matches POSIX extended patterns" {
    const re = try Regex.init("^Mus.c$");
    defer re.deinit();
    try std.testing.expect(re.matches("Music"));
    try std.testing.expect(!re.matches("music")); // case-sensitive
    try std.testing.expect(!re.matches("Musical")); // anchored
}

test "Regex.init rejects an invalid pattern" {
    try std.testing.expectError(error.compile, Regex.init("(unclosed"));
}
