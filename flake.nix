{
  description = "agate — a tiling window manager for macOS, scripted in Lua";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      lib = nixpkgs.lib;
      # We only ship a prebuilt Apple Silicon binary (see nix/package.nix), so
      # the package/checks are aarch64-darwin only.
      packageSystems = [ "aarch64-darwin" ];
      darwinSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      allSystems = darwinSystems ++ [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forSystems = systems: f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forSystems packageSystems (pkgs: rec {
        agate = pkgs.callPackage ./nix/package.nix { };
        default = agate;
      });

      # home-manager module. Add it to your home-manager imports and set
      # `services.agate.enable = true;` — see nix/module.nix for all options.
      homeManagerModules = rec {
        agate = import ./nix/module.nix self;
        default = agate;
      };

      overlays.default = final: prev: {
        agate = final.callPackage ./nix/package.nix { };
      };

      checks = forSystems packageSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.agate;
      });

      devShells = forSystems allSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            lua
            pkg-config
            clang
            gnumake
            zig
          ];
        };
      });
    };
}
