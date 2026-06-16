# agate package. Installs the prebuilt aarch64-darwin binary from the matching
# GitHub Release (see .github/workflows/release.yml) — so `nix run`/home-manager
# get the same artifact that's published for everyone else, with no Zig
# toolchain or compile step.
#
# `version` and `hash` here are updated automatically by the release workflow:
# pushing a `v*` tag builds the binary, publishes the release, and commits the
# pinned version + artifact hash back to this file on main. (The hash can only be
# known once the asset is published, so it lands in a commit *after* the tag —
# Nix consumers pin a commit or branch, not the tag.) No manual edits needed.
{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "agate";
  version = "0.1.0-alpha.1";

  src = fetchurl {
    url = "https://github.com/frostplexx/agate-wm/releases/download/v${finalAttrs.version}/agate-aarch64-apple-darwin.tar.gz";
    hash = "sha256-hqiuwCtVM/+KtfDQ85AAVHqta9eMZ2z8xekuOiUg1a8=";
  };

  # The tarball is just the binary — nothing to configure or compile.
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 agate_wm "$out/bin/agate_wm"
    runHook postInstall
  '';

  meta = {
    description = "Tiling window manager for macOS, scripted in Lua";
    homepage = "https://github.com/frostplexx/agate-wm";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "agate_wm";
  };
})
