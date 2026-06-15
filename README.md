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

- Instant space switching 
- Moving windows between spaces
- Correctly detect native tabs
- Lua configuration
- built-in global shortcuts daemon
- Built-in hyper key functionality

## Getting Started

Please refer to the [GitHub wiki](https://github.com/frostplexx/agate-wm/wiki) to get started. It contains detailed installation and configuration instructions, known issues, and a list of all settings and commands. 
For an example config, please refer to [todo: examples].

## Building

Needs Zig 0.16 and macOS. `zig build` compiles, `zig build run` starts the
daemon (requires the Accessibility permission), `zig build test` runs the
unit tests, `zig build docs` regenerates `types/agate.lua` and the wiki's
configuration reference (`zig-out/Configuration.md`, published with
`just publish-docs`). The full settings reference lives in the
[GitHub wiki](https://github.com/frostplexx/agate-wm/wiki).
