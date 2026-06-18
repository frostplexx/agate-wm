<p align="center">
    </a>
    <h1 align="center">Agate</h1>
    <h4 align="center">Agate (/ˈæɡɪt/ AG-it): A macOS window manager that just works™</h4>
    <div style="display: grid;" align="center">
        <img alt="GitHub License" src="https://img.shields.io/github/license/frostplexx/agate-wm">
        <img alt="CI Status" src="https://github.com/frostplexx/agate-wm/actions/workflows/ci.yml/badge.svg">
        <a href="https://github.com/frostplexx/agate-wm/wiki">
            <img src="https://img.shields.io/badge/view-wiki-green.svg" alt="Wiki Badge">
        </a>
    </div>
</p>

---

> [!CAUTION]
> This project is in alpha!

Features:

- **Flow**: a hybrid scrollable + traditional tiling layout (see below)
- Instant space switching 
- Moving windows between spaces
- Correctly detect native tabs
- Lua configuration
- built-in global shortcuts daemon
- Built-in hyper key functionality

## Flow — hybrid scrollable tiling

Every workspace in agate is a **Flow strip**: a horizontally scrollable row of
columns, in the spirit of [niri] / [PaperWM] / [paneru]. It blends sliding and
traditional tiling into one model, with no mode switch:

- **Few windows → classic tiling.** While the columns fit at a usable width the
  strip *fills the whole screen* like a normal tiler. One window fills the
  screen; two share it; N share it down to a minimum width.
- **Many windows → scrolling strip.** Only once there are more columns than fit at
  `columns.min_width` does the strip start to scroll. Opening a window then
  **never resizes** the others — it just adds a column next to the focused one.
- **Never lost.** It's *bounded*, not infinite: the screen stays full until a
  predictable capacity, and once it scrolls, off-screen columns always keep a
  thin **edge-peek** sliver visible, so the next window is one nudge away.
- **Tile inside a column.** A column can itself be a traditional split/stack of
  windows (`agate.consume`/`agate.expel` merge and split columns), so you get
  vertical tiling within the horizontal strip.

```lua
agate.bind("hyper+h", "focus left")          -- move between columns (auto-scrolls)
agate.bind("hyper+l", "focus right")
agate.bind("hyper+r", "column_width wider")   -- cycle the focused column's width
agate.bind("hyper+f", "column_width fit")     -- re-tile columns evenly (classic)
agate.bind("hyper+comma", "consume left")     -- pull the left column into this one
agate.bind("hyper+period", "expel right")     -- eject the focused window to its own column
agate.bind("hyper+0", "scroll center")        -- center the focused column
```

A 3-finger horizontal trackpad swipe scrolls the strip live and snaps to a column
on release (`swipe_scroll_fingers`). Tune the strip with
`agate.config{ columns = { default_width = 0.5, min_width = 0.22,
presets = { 1/3, 1/2, 2/3, 1.0 } } }`. See the
[wiki](https://github.com/frostplexx/agate-wm/wiki) for the full reference.

[niri]: https://github.com/YaLTeR/niri
[PaperWM]: https://github.com/paperwm/PaperWM
[paneru]: https://github.com/karinushka/paneru

## Getting Started

Please refer to the [GitHub wiki](https://github.com/frostplexx/agate-wm/wiki) to get started. It contains detailed installation and configuration instructions, known issues, and a list of all settings and commands. 
For an example config, please refer to [todo: examples].

### Nix (home-manager)

agate ships a [home-manager](https://github.com/nix-community/home-manager)
module. Add the flake as an input and import the module in your home-manager
configuration:

```nix
{
  inputs.agate.url = "github:frostplexx/agate-wm";

  # in your home-manager configuration:
  imports = [ inputs.agate.homeManagerModules.default ];

  services.agate = {
    enable = true;
    # inline config, written to ~/.config/agate/init.lua:
    config = ''
      agate.config({ gaps = 8 })
      agate.bind("hyper+l", "focus right")
      agate.bind("hyper+h", "focus left")
    '';
    # ...or point at a file instead (mutually exclusive with `config`):
    # configFile = ./agate/init.lua;
  };
}
```

`enable` installs agate and registers a per-user launchd agent, so it starts at
login and restarts if it exits. The `config`/`configFile` you declare is written
to `~/.config/agate/init.lua` (agate's own config path) — so the settings you put
in Nix are the settings agate actually loads. Logs go to `~/Library/Logs/agate.log`
and `agate.error.log`.

> Grant the Accessibility permission (System Settings → Privacy & Security →
> Accessibility) to the agate binary. macOS keys this to the binary path, which
> changes on every package rebuild, so you may need to re-grant after updates.

## Building

Needs Zig 0.16 and macOS. `zig build` compiles, `zig build run` starts the
daemon (requires the Accessibility permission), `zig build test` runs the
unit tests, `zig build docs` regenerates `types/agate.lua` and the wiki's
configuration reference (`zig-out/Configuration.md`, published with
`just publish-docs`). The full settings reference lives in the
[GitHub wiki](https://github.com/frostplexx/agate-wm/wiki).
