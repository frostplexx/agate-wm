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
            },
        }),
    });
    // The frameworks are linked on the module that uses them; applying the SDK
    // paths and links to the final exe as well keeps the linker happy and
    // matches how Ghostty applies it to every compile step.
    try linkMacOSFrameworks(b, exe.root_module);
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
}

/// Link every macOS framework agate needs and point the module at the active
/// SDK. `linkFramework` on a module both adds the linker flag and (combined
/// with `addAppleSDK`) lets `@cImport` resolve the umbrella headers.
fn linkMacOSFrameworks(b: *std.Build, m: *std.Build.Module) !void {
    try addAppleSDK(b, m);
    // CoreFoundation: CFString, CFArray, CFDictionary, retain/release.
    m.linkFramework("CoreFoundation", .{});
    // CoreGraphics: CGWindowID, CGRect, CGWindowListCopyWindowInfo, CGEvent.
    m.linkFramework("CoreGraphics", .{});
    // ApplicationServices: the Accessibility (AX) API lives in its HIServices
    // sub-framework (AXUIElement, AXObserver, AXIsProcessTrusted).
    m.linkFramework("ApplicationServices", .{});
    // AppKit: NSWorkspace, NSRunningApplication, NSScreen (used via objc).
    m.linkFramework("AppKit", .{});
    // SkyLight: the private window-server framework (Spaces, window iteration,
    // snap detection, native tile spaces). It has no public headers — the API
    // is hand-declared in `src/macos/skylight.zig` — but the SDK ships a
    // `SkyLight.tbd` stub under PrivateFrameworks, so it links normally. The
    // CGS* symbols it pairs with live in CoreGraphics (linked above).
    m.linkFramework("SkyLight", .{});
}

/// Resolve the active Apple SDK with `xcrun` and add its framework, include,
/// and library paths to the module. This is the keystone of the strategy: it
/// is what lets `@cInclude("CoreFoundation/CoreFoundation.h")` and
/// `linkFramework` find anything. Lifted from mitchellh/zig-objc's build.zig,
/// which itself follows Ghostty's apple-sdk package.
pub fn addAppleSDK(b: *std.Build, m: *std.Build.Module) !void {
    const target = m.resolved_target.?.result;
    if (!target.os.tag.isDarwin()) return;

    const Cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            os: std.Target.Os.Tag,
            abi: std.Target.Abi,
        };
        var map: std.AutoHashMapUnmanaged(Key, ?[]const u8) = .{};
    };

    const gop = try Cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });
    if (!gop.found_existing) {
        // Runs `xcrun --show-sdk-path` (cached, since it spawns a subprocess).
        gop.value_ptr.* = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target);
    }

    const path = gop.value_ptr.* orelse return error.XcodeMacOSSDKNotFound;
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    // Private frameworks (SkyLight & co.) ship `.tbd` stubs here in the SDK.
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/PrivateFrameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}
