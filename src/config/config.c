#include "config.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Write the resolved init.lua path into `buf`, or return false if none exists.
static bool resolve_config_path(char *buf, size_t n) {
    const char *env = getenv("WM_CONFIG");
    if (env && env[0]) {
        snprintf(buf, n, "%s", env);
        return access(buf, R_OK) == 0;
    }

    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) {
        snprintf(buf, n, "%s/wm/init.lua", xdg);
        if (access(buf, R_OK) == 0) return true;
    }

    const char *home = getenv("HOME");
    if (home && home[0]) {
        snprintf(buf, n, "%s/.config/wm/init.lua", home);
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
                        "(set $WM_CONFIG or create ~/.config/wm/init.lua)\n");
        return false;
    }

    lua_State *L = luaL_newstate();
    if (!L) return false;
    luaL_openlibs(L);

    bool ok = luaL_dofile(L, path) == LUA_OK;
    if (!ok) {
        fprintf(stderr, "config error: %s\n", lua_tostring(L, -1));
    }

    lua_close(L);
    return ok;
}
