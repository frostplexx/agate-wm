const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Objective-C runtime bindings (mitchellh/zig-objc). This package
    // already translates <objc/runtime.h>, links libobjc + Foundation, and
    // resolves the Apple SDK on its own, so we just import the module.
    const objc = b.dependency("objc", .{
        .target = target,
        .optimize = optimize,
    }).module("objc");

    // Lua bindings for zig
    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    });

    // The native macOS interop layer. This mirrors Ghostty's `pkg/macos`
    // strategy: a single module that consolidates the C framework headers via
    // @cImport and exposes hand-written, idiomatic Zig wrappers on top. The
    // module is what performs the @cImport, so it is the thing that needs the
    // SDK include/framework paths and the framework links.
    const macos = b.addModule("macos", .{
        .root_source_file = b.path("src/macos/macos.zig"),
        .target = target,
        .optimize = optimize,
    });
    macos.addImport("objc", objc);
    try linkMacOSFrameworks(b, macos);

    // The agate executable.
    const exe = b.addExecutable(.{
        .name = "agate_wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "macos", .module = macos },
                .{ .name = "objc", .module = objc },
                .{ .name = "zlua", .module = lua_dep.module("zlua")}
            },
        }),
    });
    // The frameworks are linked on the module that uses them; applying the SDK
    // paths and links to the final exe as well keeps the linker happy and
    // matches how Ghostty applies it to every compile step.
    try linkMacOSFrameworks(b, exe.root_module);
    // POSIX regex_t allocator shim for src/lib/regexp.zig (regex_t's layout is
    // opaque to Zig, so it's malloc'd where sizeof is known).
    exe.root_module.addCSourceFile(.{ .file = b.path("src/lib/regex_slim.c") });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    // Tests only run for the module they live in, so the macos module needs its
    // own test compile (its pure helpers, e.g. spaces.isManageable, test there).
    const macos_tests = b.addTest(.{ .root_module = macos });
    const run_macos_tests = b.addRunArtifact(macos_tests);
    test_step.dependOn(&run_macos_tests.step);

    // `zig build docs` — compile tools/gen_docs.zig, run it against
    // src/config/lua.zig (parsing its `// @doc` annotations), and emit:
    //   * types/agate.lua — LuaCATS type stub, copied into the source tree
    //     (committed; editors read it for completion).
    //   * zig-out/Configuration.md — settings reference for the GitHub wiki.
    //     The human-readable docs live only in the wiki, so this is installed
    //     to the build output (not committed) and `just publish-docs` pushes it.
    const gen_docs_exe = b.addExecutable(.{
        .name = "gen_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_docs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_gen_docs = b.addRunArtifact(gen_docs_exe);
    _ = run_gen_docs.addFileArg(b.path("src/config/lua.zig")); // argv[1]
    const md_out = run_gen_docs.addOutputFileArg("configuration.md"); // argv[2]
    const lua_out = run_gen_docs.addOutputFileArg("agate.lua");       // argv[3]

    const write_docs = b.addUpdateSourceFiles();
    write_docs.addCopyFileToSource(lua_out, "types/agate.lua");

    // The wiki markdown goes to zig-out/Configuration.md for `publish-docs`.
    const install_md = b.addInstallFile(md_out, "Configuration.md");

    const docs_step = b.step("docs", "Generate the Lua type defs and wiki reference");
    docs_step.dependOn(&write_docs.step);
    docs_step.dependOn(&install_md.step);
}

/// Link every macOS framework agate needs and point the module at the SDK.
fn linkMacOSFrameworks(b: *std.Build, m: *std.Build.Module) !void {
    // Public framework headers + includes from the bundled zig-build-macos-sdk
    // snapshot. Use the dependency path API so the paths resolve correctly to
    // the package cache directory (avoids the @src().file relative-path issue).
    const sdk_dep = b.dependency("macos_sdk", .{});
    m.addSystemFrameworkPath(sdk_dep.path("Frameworks"));
    m.addSystemIncludePath(sdk_dep.path("include"));
    m.addLibraryPath(sdk_dep.path("lib"));
    // SkyLight is a private framework whose .tbd stub lives under
    // PrivateFrameworks in the installed Xcode SDK — not bundled above.
    try addPrivateFrameworkPath(b, m);
    m.linkFramework("CoreFoundation", .{});
    m.linkFramework("CoreGraphics", .{});
    m.linkFramework("ApplicationServices", .{});
    m.linkFramework("AppKit", .{});
    // SkyLight: private window-server framework; API hand-declared in skylight.zig.
    m.linkFramework("SkyLight", .{});
}

/// Add the PrivateFrameworks path from the macOS SDK so the linker can find
/// SkyLight.tbd (not included in the zig-build-macos-sdk bundle). `$SDKROOT`
/// is preferred — Nix's darwin stdenv sets it and its sandbox has no xcrun —
/// with the installed Xcode SDK (via xcrun) as the fallback.
fn addPrivateFrameworkPath(b: *std.Build, m: *std.Build.Module) !void {
    const target = m.resolved_target.?.result;
    if (!target.os.tag.isDarwin()) return;
    const sdk_path: []const u8 = if (std.c.getenv("SDKROOT")) |p|
        std.mem.span(p)
    else
        std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target) orelse
            return error.XcodeMacOSSDKNotFound;
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "/System/Library/PrivateFrameworks" }) });
}
