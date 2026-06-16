# home-manager module for agate. Imported curried with the flake's `self` so
# `services.agate.package` defaults to the flake's own package:
#
#   # flake.nix of your home-manager / nix-darwin+home-manager config
#   inputs.agate.url = "github:frostplexx/agate-wm";
#   ...
#   # in your home-manager configuration:
#   imports = [ inputs.agate.homeManagerModules.default ];
#   services.agate = {
#     enable = true;
#     config = ''
#       agate.config({ gaps = 8, outer_gaps = 8 })
#       agate.bind("hyper+l", "focus right")
#     '';
#   };
#
# What it does:
#   * installs the agate package into the user environment,
#   * writes the init.lua you give it (inline `config` or a `configFile`) to
#     `~/.config/agate/init.lua` — agate's own config search path — so the
#     config you declare in Nix is the config agate actually loads,
#   * runs agate as a per-user launchd agent so it starts at login and is
#     restarted if it exits (a macOS "service").
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

  # Whether the user wants Nix to manage the init.lua at all. When false, agate
  # falls back to whatever is already on its search path (hand-written, or a
  # `~/.config/agate/init.lua` you manage with another home.file entry).
  manageConfig = cfg.config != null || cfg.configFile != null;

  # The path the managed init.lua lands at — agate's primary search location.
  # Exported as WM_CONFIG too, so the agent finds it even if XDG_CONFIG_HOME is
  # not propagated into the launchd session.
  configTarget = "${config.xdg.configHome}/agate/init.lua";
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
        Contents of agate's init.lua, managed by Nix. Written verbatim to
        `~/.config/agate/init.lua` (under {option}`xdg.configHome`), which is
        where agate loads its config from. Mutually exclusive with
        {option}`services.agate.configFile`. When neither is set, agate falls
        back to whatever already exists on its search path.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''./agate/init.lua'';
      description = ''
        Path to an init.lua to use. Symlinked to `~/.config/agate/init.lua`,
        so you can keep the config in your dotfiles repo. Mutually exclusive
        with {option}`services.agate.config`.
      '';
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Logs/agate.log";
      description = "Where the agent's stdout goes.";
    };

    errorLogFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Logs/agate.error.log";
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

    home.packages = [ cfg.package ];

    # Write the declared config to agate's real search path. agate then loads it
    # with no env-var indirection — so inline `config` is actually applied.
    xdg.configFile."agate/init.lua" = lib.mkIf manageConfig (
      if cfg.configFile != null then
        { source = cfg.configFile; }
      else
        { text = cfg.config; }
    );

    # Per-user launchd agent: agate must run inside the user's GUI session to
    # reach the window server and Accessibility, so it's an agent, not a daemon.
    launchd.agents.agate = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe cfg.package) ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.errorLogFile;
      }
      // lib.optionalAttrs manageConfig {
        EnvironmentVariables = {
          WM_CONFIG = configTarget;
        };
      };
    };

    # Kickstart (or restart) the agent on every `home-manager switch` so the
    # new store-path binary is picked up immediately without a re-login.
    home.activation.agateRestart = lib.hm.dag.entryAfter [ "launchctlActivation" ] ''
      $DRY_RUN_CMD /bin/launchctl kickstart -k gui/"$(id -u)"/org.nix-community.home.agate 2>/dev/null || true
    '';
  };
}
