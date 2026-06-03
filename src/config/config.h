#ifndef CONFIG_H
#define CONFIG_H

#include <stdbool.h>

// Locate and run the user's Lua config (init.lua), executing it in a fresh Lua
// state with the standard libraries open. Search order:
//   1. $WM_CONFIG                       (explicit path override)
//   2. $XDG_CONFIG_HOME/wm/init.lua
//   3. $HOME/.config/wm/init.lua
//   4. ./init.lua                       (dev fallback: repo root)
// Returns true if a config file was found and ran without error.
bool config_load(void);

#endif // CONFIG_H
