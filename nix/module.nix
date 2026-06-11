# nix-darwin module for agate. Imported curried with the flake's `self` so
# `services.agate.package` defaults to the flake's own package:
#
#   # flake.nix of your system config
#   inputs.agate.url = "github:frostplexx/agate-wm";
#   ...
#   darwinConfigurations.myhost = darwin.lib.darwinSystem {
#     modules = [ inputs.agate.darwinModules.default { services.agate.enable = true; } ];
#   };
#
# NOTE: agate needs the Accessibility permission (System Settings → Privacy &
# Security → Accessibility). macOS keys that grant on the binary's path, and
# the nix store path changes with every rebuild of the package — expect to
# re-grant after updates. Until granted, the agent exits and launchd retries.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.agate;
  configFile =
    if cfg.configFile != null then
      cfg.configFile
    else if cfg.config != null then
      pkgs.writeText "agate-init.lua" cfg.config
    else
      null;
in
{
  options.services.agate = {
    enable = lib.mkEnableOption "agate, a tiling window manager for macOS";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.agate;
      defaultText = lib.literalExpression "agate.packages.\${system}.agate";
      description = "The agate package to run.";
    };

    config = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      example = ''
        agate.config({ gaps = 8, outer_gaps = 8 })
        agate.bind("hyper+l", "focus right")
        agate.bind("hyper+h", "focus left")
      '';
      description = ''
        Contents of agate's init.lua, managed by Nix. When neither this nor
        {option}`services.agate.configFile` is set, agate falls back to its
        own search path (`$XDG_CONFIG_HOME/agate/init.lua`,
        `~/.config/agate/init.lua`), which you can manage by hand or with
        home-manager.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''"''${config.users.users.me.home}/.config/agate/init.lua"'';
      description = ''
        Path to an init.lua to use (exported as `WM_CONFIG`). Mutually
        exclusive with {option}`services.agate.config`. Point this at a file
        in your home directory if you want to edit the config without a
        darwin-rebuild.
      '';
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/agate.log";
      description = "Where the agent's stdout goes.";
    };

    errorLogFile = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/agate.error.log";
      description = "Where the agent's stderr goes (agate logs to stderr).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.config != null && cfg.configFile != null);
        message = "services.agate: set at most one of `config` and `configFile`.";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # User agent, not a daemon: agate must run inside the user's GUI session
    # to reach the window server and Accessibility.
    launchd.user.agents.agate = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe cfg.package) ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.errorLogFile;
        EnvironmentVariables = lib.mkIf (configFile != null) {
          WM_CONFIG = "${configFile}";
        };
      };
    };
  };
}
