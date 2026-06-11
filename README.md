```
  src/
    main.zig              # entry point, CLI arg parsing, run loop

    macos/                # macOS platform bindings (already solid — keep as-is)
      macos.zig
      c.zig
      ax.zig, cg.zig, skylight.zig, foundation.zig
      accessibility.zig
      spaces.zig, window_list.zig, workspace.zig

    wm/                   # core WM domain logic
      wm.zig              # AppState, init/deinit, main event loop
      window.zig          # Window type: id + AX element + cached metadata
      space.zig           # Space state, active space tracking
      tree.zig            # tiling tree: nodes, insert, remove, swap
      layout.zig          # layout algorithms (BSP, float, stack variants)

    input/                # user input
      keybind.zig         # keybinding registry + CGEvent tap
      mouse.zig           # mouse tracking, snap zones

    config/               # configuration
      config.zig          # config types, defaults, load/reload
      lua.zig             # Lua scripting layer (mirrors lua_api.c)

    ipc/                  # CLI control socket (mirrors commands.c)
      ipc.zig             # Unix domain socket server
      commands.zig        # command dispatch (focus, move, layout, etc.)
```

  Key decisions:

  - macos/ stays unchanged — it's the platform abstraction boundary. Nothing above it should @cImport directly.
  - wm/ is the heart: tree.zig owns the tiling data structure, layout.zig translates tree state into window frames, wm.zig wires them to the event loop.
  - input/ and config/ are thin — flat files, no sub-directories needed yet.
  - ipc/ is for the agated socket so a CLI binary can send commands (yabai-style). Skip it if you don't need that.










# agate-wm
- Instant space switching 
- Moving windows between spaces
- Correctly detect native tabs
- Lua configuration
- built-in global shortcuts daemon
- Built-in hyper key functionality

## Getting Started

Disable macOS's own space-switch-on-activate:

System Settings → Desktop & Dock → scroll to Mission Control → turn OFF:

▎ "When switching to an application, switch to a Space with open windows for the application"

This is mandatory. With it on, macOS does its own animated swoosh to the target space the instant you Cmd+Tab — beating our handler, so by the time we check, the
space is already current and we skip. You see macOS's animation, not our instant gesture.

## Building

Needs Zig 0.16 and macOS. `zig build` compiles, `zig build run` starts the
daemon (requires the Accessibility permission), `zig build test` runs the
unit tests, `zig build docs` regenerates `docs/configuration.md` and
`types/agate.lua`.

## Nix

The flake provides the package and a nix-darwin module:

```nix
# flake.nix of your system configuration
{
  inputs.agate.url = "github:frostplexx/agate-wm";

  outputs = { nix-darwin, agate, ... }: {
    darwinConfigurations.myhost = nix-darwin.lib.darwinSystem {
      modules = [
        agate.darwinModules.default
        {
          services.agate = {
            enable = true;
            # Optional: manage init.lua with Nix. Without it agate reads
            # ~/.config/agate/init.lua.
            config = ''
              agate.config({ gaps = 8, outer_gaps = 8 })
              agate.bind("hyper+l", "focus right")
            '';
            # Or point at a mutable file instead (live-editable, no rebuild):
            # configFile = "/Users/me/.config/agate/init.lua";
          };
        }
      ];
    };
  };
}
```

This runs agate as a launchd user agent (`launchd.user.agents.agate`); logs
go to `/tmp/agate.log` / `/tmp/agate.error.log` (configurable via
`services.agate.logFile` / `errorLogFile`).

> [!NOTE]
> agate needs the Accessibility permission (System Settings → Privacy &
> Security → Accessibility). macOS grants it per binary path, and the nix
> store path changes when the package updates — re-grant after updates.
> Until granted, the agent exits and launchd keeps retrying.

`nix build .#agate` builds the package by itself. When `build.zig.zon`
changes, refresh the pinned dependency hash in `nix/package.nix`
(`deps.outputHash`): set it to `lib.fakeHash`, build, and copy the hash
from the mismatch error.
