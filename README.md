<p align="center">
    </a>
    <h1 align="center"><code>Agate</code></h1>
    <h6 align="center">A macOS window manager that just works™</h2>
    <div style="display: grid;" align="center"></div>
</p>

---

> Agate (/ˈæɡɪt/ AG-it): A banded variety of fibrous chalcedony


> [!CAUTION]
> This project is in alpha!

Features:

- Instant space switching 
- Moving windows between spaces
- Correctly detect native tabs
- Lua configuration
- built-in global shortcuts daemon
- Built-in hyper key functionality

## Getting Started

### Required Settings

- Disable macOS's own space-switch-on-activate: System Settings → Desktop & Dock → scroll to Mission Control → turn OFF "When switching to an application, switch to a Space with open windows for the application".
- Disable space rearranging: System Settings → Desktop & Dock → scroll to Mission Control → turn OFF "Automatically rearrange Spaces based on most recent use"

### Installation

soon.

## Building

Needs Zig 0.16 and macOS. `zig build` compiles, `zig build run` starts the
daemon (requires the Accessibility permission), `zig build test` runs the
unit tests, `zig build docs` regenerates `docs/configuration.md` and
`types/agate.lua`.
