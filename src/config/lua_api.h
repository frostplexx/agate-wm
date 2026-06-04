#ifndef CONFIG_LUA_API_H
#define CONFIG_LUA_API_H

#include <lua.h>

// Register the global `agate` table (commands, bindings, config options) into
// `L`. Call once, before running the user's init.lua. The state must stay alive
// for the daemon's lifetime so hotkey callbacks can be invoked.
void lua_api_register(lua_State *L);

#endif // CONFIG_LUA_API_H
