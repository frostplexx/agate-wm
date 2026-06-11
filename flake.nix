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
      packages = forSystems darwinSystems (pkgs: rec {
        agate = pkgs.callPackage ./nix/package.nix { };
        default = agate;
      });

      # `services.agate.enable = true;` — see nix/module.nix for all options.
      darwinModules = rec {
        agate = import ./nix/module.nix self;
        default = agate;
      };

      overlays.default = final: prev: {
        agate = final.callPackage ./nix/package.nix { };
      };

      checks = forSystems darwinSystems (pkgs: {
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
