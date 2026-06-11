# agate package derivation. Built with the Zig build system; Zig package
# dependencies (build.zig.zon) are prefetched into a fixed-output derivation
# (`deps`) so the main, sandboxed build is fully offline.
#
# SkyLight (private framework) links against the stub bundled with the
# nixpkgs apple-sdk; build.zig finds it via $SDKROOT, which the darwin
# stdenv sets — no Xcode or xcrun needed.
{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "agate";
  version = "0.0.0";

  # Only what the zig build needs; keeps zig-pkg/zig-out/.zig-cache and
  # unrelated files out of the source hash.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../tools
    ];
  };

  # All build.zig.zon dependencies as Zig's global package cache (`p/` of
  # tarballs, named by content hash). Fixed-output so it may touch the
  # network; refresh outputHash after changing build.zig.zon
  # (set it to lib.fakeHash, build, copy the reported hash).
  deps = stdenv.mkDerivation {
    pname = "${finalAttrs.pname}-deps";
    version = finalAttrs.version;
    src = finalAttrs.src;
    nativeBuildInputs = [ zig ];
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
      zig build --fetch=all
      mv $ZIG_GLOBAL_CACHE_DIR/p $out
      runHook postBuild
    '';
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-Pm+QKg//OA1H9oRraTFAteABei/EMLG22/zAUUMt+lY=";
  };

  nativeBuildInputs = [ zig ];

  dontConfigure = true;
  dontInstall = true; # `zig build install --prefix $out` is the install
  doCheck = true;

  # Zig normally locates the macOS libc headers by running xcrun, which the
  # sandbox doesn't have; without them it falls back to its bundled headers,
  # whose newer mach headers break the CoreFoundation @cImport. `--libc`
  # points it at the stdenv's apple-sdk explicitly (SDKROOT is set by the
  # darwin stdenv).
  preBuild = ''
    cat > "$TMPDIR/libc.txt" <<EOF
    include_dir=$SDKROOT/usr/include
    sys_include_dir=$SDKROOT/usr/include
    crt_dir=
    msvc_lib_dir=
    kernel32_lib_dir=
    gcc_dir=
    EOF
  '';

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    cp -r ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
    zig build install --libc "$TMPDIR/libc.txt" -Doptimize=ReleaseFast --color off --prefix $out
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    zig build test --libc "$TMPDIR/libc.txt" --color off
    runHook postCheck
  '';

  meta = {
    description = "Tiling window manager for macOS, scripted in Lua";
    homepage = "https://github.com/frostplexx/agate-wm";
    platforms = lib.platforms.darwin;
    mainProgram = "agate_wm";
  };
})
