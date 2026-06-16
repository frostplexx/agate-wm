# agate package. Installs the prebuilt aarch64-darwin binary from the matching
# GitHub Release (see .github/workflows/release.yml) — so `nix run`/home-manager
# get the same artifact that's published for everyone else, with no Zig
# toolchain or compile step.
#
# Updating to a new release: bump `version` to the tag (without the leading `v`),
# set `hash` to `lib.fakeHash`, run `nix build .#agate`, and copy the real hash
# Nix prints back here. (The hash can only be known once the release asset is
# published, so it lands in a commit *after* the tag — Nix users pin a commit or
# branch, not the tag.)
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
    hash = "sha256-4BnHnRbBGlE0H14nXx7BUktgG9eMt8SRfFbYCwvuOs0=";
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
