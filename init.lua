-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Gaps and hyper-key definition.
agate.config({
    gaps = 4,               -- space between tiles
    outer_gaps = 4,         -- inset from the screen edge
    accordion_padding = 20, -- stacked-window "peek": how far each window fans out
    hyper_key = { enabled = true, keys = { "ctrl", "alt", "cmd" }, },
    smart_gaps = true,      -- disable gaps when only one tile is visible
})



-- Gestures
agate.gesture("3:left", function() agate.focus("right") end)
agate.gesture("3:down", function() agate.focus("down") end)
agate.gesture("3:up", function() agate.focus("up") end)
agate.gesture("3:right", function() agate.focus("left") end)


-- Focus movement (i3-style hjkl).
agate.bind("hyper+h", function() agate.focus("left") end)
agate.bind("hyper+j", function() agate.focus("down") end)
agate.bind("hyper+k", function() agate.focus("up") end)
agate.bind("hyper+l", function() agate.focus("right") end)

agate.bind("hyper+comma", function() agate.focus_monitor("left") end)
agate.bind("hyper+period", function() agate.focus_monitor("right") end)



agate.bind("hyper+shift+comma", function() agate.move_to_monitor("left") end)
agate.bind("hyper+shift+period", function() agate.move_to_monitor("right") end)

agate.bind("hyper+space", function() agate.zoom_fullscreen() end)

-- Move the focused window to an adjacent slot.
agate.bind("hyper+shift+h", "move left")
agate.bind("hyper+shift+j", "move down")
agate.bind("hyper+shift+k", "move up")
agate.bind("hyper+shift+l", "move right")

-- Layout control.
agate.bind("hyper+b", function() agate.layout("h_tiles") end)       -- horizontal split
agate.bind("hyper+v", function() agate.layout("v_tiles") end)       -- vertical split
agate.bind("hyper+e", function() agate.layout("toggle") end)        -- swap split orientation
agate.bind("hyper+s", function() agate.layout("accordion") end)     -- vertical stack (bottom peeks)
agate.bind("hyper+shift+s", function() agate.layout("h_stack") end) -- horizontal stack

-- Combine the focused window with a neighbour into a nested container, for mixed
-- layouts (e.g. left/right tiled with the left slot holding two stacked windows).
-- Second arg is the new container's layout (default "v_stack").
agate.bind("hyper+g", function() agate.join("right") end)                  -- stack with right neighbour
agate.bind("hyper+shift+g", function() agate.join("right", "v_split") end) -- split with right neighbour

-- Resize the focused tile.
agate.bind("hyper+minus", function() agate.resize("smart", -50) end)
agate.bind("hyper+equal", function() agate.resize("smart", 50) end)

local space_keys = {
    { name = "web" },   -- hyper+1  Zen (big monitor)
    { name = "term" },  -- hyper+2  Ghostty (big monitor)
    { name = "notes" }, -- hyper+3  Obsidian (big monitor)
    { name = "comms" }, -- hyper+4
    { name = "music" }, -- hyper+5
    { name = "tasks" }, -- hyper+6  Things (built-in panel)
    { name = "mail" },  -- hyper+7  Mail (built-in panel)
}
for i, s in ipairs(space_keys) do
    agate.bind("hyper+" .. i, function()
        agate.space(s.name)
    end)
    agate.bind("hyper+shift+" .. i, function()
        agate.move_to_space(s.name)
        agate.space(s.name)
    end)
end

-- Identify displays by NAME rather than by number, because `agate.monitors()`
-- numbers displays by spatial position (left→right), which can differ from how
-- you think of them and flips when you rearrange screens. The built-in panel
-- reports as "Built-in ..."; anything else is an external. Returns the monitor
-- `id` (the number rules/`move_to_space` take) for the internal and the external,
-- plus how many externals are attached.
local function survey_displays()
    local internal_id, external_id, external_count = nil, nil, 0
    for _, m in ipairs(agate.monitors()) do
        if m.name:find("Built-in", 1, true) then
            internal_id = m.id
        else
            external_count = external_count + 1
            external_id = external_id or m.id
        end
    end
    return internal_id, external_id, external_count
end

-- Window assignment rules (yabai-style): a matching window is sent to a space
-- when it appears; `app`/`title` are POSIX extended regexes (at least one
-- required), last match wins. These are STATIC — they reference named spaces by
-- name, and agate resolves the name (and its monitor) each time a window appears,
-- so a rule automatically follows the dynamic music/comms remapping below without
-- being re-registered.
agate.rule({ app = "^Zen$", space = "web" })
agate.rule({ app = "^Ghostty$", space = "term" })
agate.rule({ app = "^Obsidian$", space = "notes" })
agate.rule({ app = "^Things$", space = "tasks" })
agate.rule({ app = "^Mail$", space = "mail" })
agate.rule({ app = "^Vesktop$", space = "comms" })
agate.rule({ app = "^Spotify$", space = "music" })

-- (Re)declare the named spaces for the current display layout. Named spaces
-- (`agate.name_space`) give a (monitor, space) slot a name, so the binds and
-- rules above can say "music" instead of a monitor+number; the same name works in
-- `agate.space`, `agate.move_to_space`, and `agate.rule{space=...}`. This is the
-- only dynamic part: re-run on every display change (a name overwrites its old
-- slot), so the music/comms spaces follow docking. `monitor` is the 1-based
-- arrangement number from `agate.monitors()`; omit it to mean "the focused
-- display".
local function name_spaces()
    local internal_id, external_id, external_count = survey_displays()
    -- The "big" screen is the external when docked, else the laptop; the "small"
    -- screen is always the built-in panel (falls back to the only display).
    local big = external_id or internal_id
    local small = internal_id or external_id

    agate.name_space("web", { monitor = big, space = 1 })     -- Zen
    agate.name_space("term", { monitor = big, space = 2 })    -- Ghostty
    agate.name_space("notes", { monitor = big, space = 3 })   -- Obsidian
    agate.name_space("tasks", { monitor = small, space = 1 }) -- Things
    agate.name_space("mail", { monitor = small, space = 2 })  -- Mail
    -- comms/music: docked, they live on the built-in panel (spaces 2 and 3); on
    -- the laptop alone they move to its own spaces 4 and 5.
    if internal_id and external_count > 0 then
        agate.name_space("comms", { monitor = internal_id, space = 2 })
        agate.name_space("music", { monitor = internal_id, space = 3 })
    else
        agate.name_space("comms", { space = 4 })
        agate.name_space("music", { space = 5 })
    end
end

-- Name the spaces now, and re-name them whenever a display is plugged in or
-- unplugged so music/comms track docking/undocking.
name_spaces()
agate.on("monitors_changed", function(e)
    print(string.format("agate: monitors changed -> %d connected; renaming spaces", e.count))
    name_spaces()
end)

print("agate: config loaded")
