#include "lua_api.h"

#include <lauxlib.h>

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "../commands/commands.h"
#include "../input/keybind.h"
#include "../layout/layout.h"
#include "../tree/manager.h"
#include "../window/ax_window.h"

// The config state outlives config_load() so hotkey callbacks (which run a Lua
// function or command string stored in the registry) keep working.
static lua_State *g_lua;

// Modifiers the "hyper" keyword expands to. Configurable via agate.config.
static CGEventFlags g_hyper_mods =
    kCGEventFlagMaskCommand | kCGEventFlagMaskShift |
    kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;

// --- string parsing --------------------------------------------------------

// US-ANSI virtual keycode for a key name, or UINT16_MAX if unknown.
static CGKeyCode key_for_name(const char *s) {
    static const struct { const char *name; CGKeyCode code; } table[] = {
        {"a",0},{"s",1},{"d",2},{"f",3},{"h",4},{"g",5},{"z",6},{"x",7},{"c",8},
        {"v",9},{"b",11},{"q",12},{"w",13},{"e",14},{"r",15},{"y",16},{"t",17},
        {"1",18},{"2",19},{"3",20},{"4",21},{"6",22},{"5",23},{"9",25},{"7",26},
        {"8",28},{"0",29},{"o",31},{"u",32},{"i",34},{"p",35},{"l",37},{"j",38},
        {"k",40},{"n",45},{"m",46},
        {"return",0x24},{"enter",0x24},{"tab",0x30},{"space",0x31},
        {"escape",0x35},{"esc",0x35},{"delete",0x33},{"backspace",0x33},
        {"left",0x7B},{"right",0x7C},{"down",0x7D},{"up",0x7E},
        {"minus",27},{"equal",24},{"comma",43},{"period",47},{"slash",44},
    };
    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        if (strcasecmp(s, table[i].name) == 0) return table[i].code;
    }
    return UINT16_MAX;
}

// Modifier mask for a token, or 0 if it isn't a modifier. Writes the hyper flag.
static CGEventFlags mod_for_token(const char *s) {
    if (!strcasecmp(s,"cmd")||!strcasecmp(s,"command")||!strcasecmp(s,"super")) return kCGEventFlagMaskCommand;
    if (!strcasecmp(s,"alt")||!strcasecmp(s,"option")||!strcasecmp(s,"opt"))    return kCGEventFlagMaskAlternate;
    if (!strcasecmp(s,"ctrl")||!strcasecmp(s,"control"))                        return kCGEventFlagMaskControl;
    if (!strcasecmp(s,"shift"))                                                 return kCGEventFlagMaskShift;
    if (!strcasecmp(s,"hyper"))                                                 return g_hyper_mods;
    return 0;
}

// Parse "hyper+shift+h" into modifier mask + keycode. Returns false on error.
static bool parse_keyspec(const char *spec, CGEventFlags *out_mods, CGKeyCode *out_key) {
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", spec);

    CGEventFlags mods = 0;
    CGKeyCode    key  = UINT16_MAX;

    for (char *tok = strtok(buf, "+"); tok; tok = strtok(NULL, "+")) {
        CGEventFlags m = mod_for_token(tok);
        if (m) { mods |= m; continue; }
        CGKeyCode k = key_for_name(tok);
        if (k != UINT16_MAX) key = k;
        else return false;
    }
    if (key == UINT16_MAX) return false;
    *out_mods = mods;
    *out_key  = key;
    return true;
}

static bool parse_direction(const char *s, Direction *out) {
    if (!strcasecmp(s,"left"))  { *out = DIR_LEFT;  return true; }
    if (!strcasecmp(s,"down"))  { *out = DIR_DOWN;  return true; }
    if (!strcasecmp(s,"up"))    { *out = DIR_UP;    return true; }
    if (!strcasecmp(s,"right")) { *out = DIR_RIGHT; return true; }
    return false;
}

static bool parse_layout(const char *s, Layout *out) {
    if (!strcasecmp(s,"h")||!strcasecmp(s,"h_tiles")||!strcasecmp(s,"horizontal")) { *out = LAYOUT_H_TILES; return true; }
    if (!strcasecmp(s,"v")||!strcasecmp(s,"v_tiles")||!strcasecmp(s,"vertical"))   { *out = LAYOUT_V_TILES; return true; }
    return false;
}

// Run a "verb arg [arg]" command string (the string form of agate.bind).
static void run_command(const char *cmd) {
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", cmd);
    char *verb = strtok(buf, " ");
    char *arg1 = strtok(NULL, " ");
    char *arg2 = strtok(NULL, " ");
    if (!verb) return;

    Direction d; Layout l;
    if (!strcasecmp(verb,"focus")  && arg1 && parse_direction(arg1,&d)) cmd_focus(d);
    else if (!strcasecmp(verb,"move")   && arg1 && parse_direction(arg1,&d)) cmd_move(d);
    else if (!strcasecmp(verb,"split")  && arg1 && parse_layout(arg1,&l))    cmd_split(l);
    else if (!strcasecmp(verb,"layout") && arg1 && parse_layout(arg1,&l))    cmd_layout(l);
    else if (!strcasecmp(verb,"resize") && arg1 && parse_direction(arg1,&d)) cmd_resize(d, arg2 ? atoi(arg2) : 50);
    else fprintf(stderr, "agate: unknown command '%s'\n", cmd);
}

// --- keybinding callback ---------------------------------------------------

// Invoked from the event tap for a matched binding. `ctx` carries the Lua
// registry ref of the stored callback (a function or a command string).
static void invoke_binding(void *ctx) {
    int ref = (int)(intptr_t)ctx;
    lua_State *L = g_lua;
    if (!L) return;

    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    if (lua_isfunction(L, -1)) {
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            fprintf(stderr, "agate: keybinding error: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    } else if (lua_isstring(L, -1)) {
        run_command(lua_tostring(L, -1));
        lua_pop(L, 1);
    } else {
        lua_pop(L, 1);
    }
}

// --- Lua-exposed functions -------------------------------------------------

// agate.bind(keyspec, function|command_string)
static int l_bind(lua_State *L) {
    const char *spec = luaL_checkstring(L, 1);
    luaL_argcheck(L, lua_isfunction(L, 2) || lua_isstring(L, 2), 2,
                  "function or command string expected");

    CGEventFlags mods; CGKeyCode key;
    if (!parse_keyspec(spec, &mods, &key)) {
        return luaL_error(L, "agate.bind: invalid keyspec '%s'", spec);
    }

    lua_pushvalue(L, 2);                          // copy the callback to the top
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);     // store it, pops the copy
    keybind_register(mods, key, invoke_binding, (void *)(intptr_t)ref);
    return 0;
}

static int l_focus(lua_State *L) {
    Direction d;
    if (parse_direction(luaL_checkstring(L, 1), &d)) cmd_focus(d);
    return 0;
}
static int l_move(lua_State *L) {
    Direction d;
    if (parse_direction(luaL_checkstring(L, 1), &d)) cmd_move(d);
    return 0;
}
static int l_split(lua_State *L) {
    Layout l;
    if (parse_layout(luaL_checkstring(L, 1), &l)) cmd_split(l);
    return 0;
}
static int l_layout(lua_State *L) {
    Layout l;
    if (parse_layout(luaL_checkstring(L, 1), &l)) cmd_layout(l);
    return 0;
}
static int l_resize(lua_State *L) {
    Direction d;
    if (parse_direction(luaL_checkstring(L, 1), &d)) {
        cmd_resize(d, (int)luaL_optinteger(L, 2, 50));
    }
    return 0;
}

// agate.on_window_detected{ app_id="...", action="float"|"tile" }
// Force all windows of an app to float or tile, overriding the dialog heuristic.
// `app` is accepted as an alias for `app_id`; `run = "layout floating"|
// "layout tiling"` is accepted as an alias for `action` (AeroSpace syntax).
static int l_on_window_detected(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "app_id");
    if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_getfield(L, 1, "app"); }
    const char *app_id = lua_tostring(L, -1);
    if (!app_id) return luaL_error(L, "on_window_detected: missing app_id");

    lua_getfield(L, 1, "action");
    if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_getfield(L, 1, "run"); }
    const char *action = lua_tostring(L, -1);
    if (!action) return luaL_error(L, "on_window_detected: missing action");

    WindowRule rule;
    if (strstr(action, "float")) rule = WINDOW_RULE_FLOAT;
    else if (strstr(action, "til")) rule = WINDOW_RULE_TILE; // "tile" / "tiling"
    else return luaL_error(L, "on_window_detected: action must be 'float' or 'tile'");

    ax_window_add_rule(app_id, rule);
    return 0;
}

// agate.config{ gaps=, outer_gaps=, hyper={...}, enable_normalization_* = }
static int l_config(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "gaps");
    if (lua_isnumber(L, -1)) g_layout_gaps.inner = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "outer_gaps");
    if (lua_isnumber(L, -1)) g_layout_gaps.outer = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "enable_normalization_flatten_containers");
    if (lua_isboolean(L, -1)) g_manager_normalization.flatten = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "enable_normalization_opposite_orientation_for_nested_containers");
    if (lua_isboolean(L, -1)) g_manager_normalization.opposite = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "hyper");
    if (lua_istable(L, -1)) {
        CGEventFlags mods = 0;
        lua_Integer n = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, (int)i);
            if (lua_isstring(L, -1)) mods |= mod_for_token(lua_tostring(L, -1));
            lua_pop(L, 1);
        }
        if (mods) g_hyper_mods = mods;
    }
    lua_pop(L, 1);

    return 0;
}

void lua_api_register(lua_State *L) {
    g_lua = L;

    static const luaL_Reg fns[] = {
        {"bind",   l_bind},
        {"focus",  l_focus},
        {"move",   l_move},
        {"split",  l_split},
        {"layout", l_layout},
        {"resize", l_resize},
        {"config", l_config},
        {"on_window_detected", l_on_window_detected},
        {NULL, NULL},
    };

    lua_newtable(L);
    luaL_setfuncs(L, fns, 0);
    lua_setglobal(L, "agate");
}
