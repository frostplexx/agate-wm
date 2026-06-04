#include "config.h"
#include "lua_api.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// The config Lua state is kept alive for the daemon's lifetime: hotkey
// callbacks registered from init.lua run stored Lua functions long after
// config_load() returns.
static lua_State *g_config_lua;

// Write the resolved init.lua path into `buf`, or return false if none exists.
static bool resolve_config_path(char *buf, size_t n) {
    const char *env = getenv("WM_CONFIG");
    if (env && env[0]) {
        snprintf(buf, n, "%s", env);
        return access(buf, R_OK) == 0;
    }

    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) {
        snprintf(buf, n, "%s/agate/init.lua", xdg);
        if (access(buf, R_OK) == 0) return true;
    }

    const char *home = getenv("HOME");
    if (home && home[0]) {
        snprintf(buf, n, "%s/.config/agate/init.lua", home);
        if (access(buf, R_OK) == 0) return true;
    }

    // Dev fallback: init.lua next to where we were launched (repo root).
    snprintf(buf, n, "init.lua");
    return access(buf, R_OK) == 0;
}

bool config_load(void) {
    char path[1024];
    if (!resolve_config_path(path, sizeof(path))) {
        fprintf(stderr, "config: no init.lua found "
                        "(set $WM_CONFIG or create ~/.config/agate/init.lua)\n");
        return false;
    }

    lua_State *L = luaL_newstate();
    if (!L) return false;
    luaL_openlibs(L);

    // Expose the agate API before running the user's config so binds/commands
    // are available. The state is intentionally NOT closed here.
    lua_api_register(L);
    g_config_lua = L;

    bool ok = luaL_dofile(L, path) == LUA_OK;
    if (!ok) {
        fprintf(stderr, "config error: %s\n", lua_tostring(L, -1));
    }

    return ok;
}

void config_shutdown(void) {
    if (g_config_lua) {
        lua_close(g_config_lua);
        g_config_lua = NULL;
    }
}
