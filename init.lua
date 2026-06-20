-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Gaps and hyper-key definition.
agate.config({
    gaps = 4,              -- space between tiles
    outer_gaps = 4,        -- inset from the screen edge
    accordion_padding = 20, -- stacked-window "peek": how far each window fans out
    hyper_key = { enabled = true, keys = {"ctrl","alt","cmd"}, },
    smart_gaps = true, -- disable gaps when only one tile is visible
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
agate.bind("hyper+b", function() agate.layout("h_tiles") end)      -- horizontal split
agate.bind("hyper+v", function() agate.layout("v_tiles") end)      -- vertical split
agate.bind("hyper+e", function() agate.layout("toggle") end)       -- swap split orientation
agate.bind("hyper+s", function() agate.layout("accordion") end)    -- vertical stack (bottom peeks)
agate.bind("hyper+shift+s", function() agate.layout("h_stack") end) -- horizontal stack

-- Combine the focused window with a neighbour into a nested container, for mixed
-- layouts (e.g. left/right tiled with the left slot holding two stacked windows).
-- Second arg is the new container's layout (default "v_stack").
agate.bind("hyper+g", function() agate.join("right") end)              -- stack with right neighbour
agate.bind("hyper+shift+g", function() agate.join("right", "v_split") end) -- split with right neighbour

-- Resize the focused tile.
agate.bind("hyper+minus", function() agate.resize("smart", -50) end)
agate.bind("hyper+equal", function() agate.resize("smart",50) end)
-- Instant space switching — uses SLSManagedDisplaySetCurrentSpace directly,
-- not gesture emulation (which fails on macOS 26+).
agate.bind("hyper+1", function() agate.space(1) end)
agate.bind("hyper+2", function() agate.space(2) end)
agate.bind("hyper+3", function() agate.space(3) end)
-- Focus an app wherever it lives (any space, any monitor). `agate.focus_app`
-- switches the display holding the app to its space and raises it — works even
-- with the macOS "switch to a Space with open windows" setting off. Falls back
-- to launching the app when it isn't open yet. Expandable: add a line per app.
local function focus_app(name)
    if not agate.focus_app(name) then agate.exec("open -a " .. name) end
end
agate.bind("hyper+4", function() focus_app("Vesktop") end)
agate.bind("hyper+5", function() focus_app("Spotify") end)
agate.bind("hyper+6", function() agate.space(6) end)
agate.bind("hyper+7", function() agate.space(7) end)
agate.bind("hyper+8", function() agate.space(8) end)
agate.bind("hyper+9", function() agate.space(9) end)

-- Send the focused window to space N (does not follow focus).
agate.bind("hyper+shift+1", function()
    agate.move_to_space(1)
    agate.space(1)
end)
agate.bind("hyper+shift+2", function()
    agate.move_to_space(2)
    agate.space(2)
end)
agate.bind("hyper+shift+3", function()
    agate.move_to_space(3)
    agate.space(3)
end)
agate.bind("hyper+shift+4", function()
    agate.move_to_space(4)
    agate.space(4)
end)
agate.bind("hyper+shift+5", function()
    agate.move_to_space(5)
    agate.space(5)
end)
agate.bind("hyper+shift+6", function()
    agate.move_to_space(6)
    agate.space(6)
end)
agate.bind("hyper+shift+7", function()
    agate.move_to_space(7)
    agate.space(7)
end)
agate.bind("hyper+shift+8", function()
    agate.move_to_space(8)
    agate.space(8)
end)
agate.bind("hyper+shift+9", function()
    agate.move_to_space(9)
    agate.space(9)
end)

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

-- (Re)build the window assignment rules for the current display layout. Rules
-- (yabai-style) send a matching window to a space when it appears; `app`/`title`
-- are POSIX extended regexes (at least one required), last match wins. Cleared
-- first so re-running on a display change doesn't pile duplicates up.
local function apply_rules()
    agate.clear_rules()

    local internal_id, external_id, external_count = survey_displays()
    -- The "big" screen is the external when docked, else the laptop; the "small"
    -- screen is always the built-in panel (falls back to the only display).
    local big = external_id or internal_id
    local small = internal_id or external_id

    agate.rule({ app = "^Ghostty$", monitor = big, space = 2 })
    agate.rule({ app = "^Zen$", monitor = big, space = 1 })
    agate.rule({ app = "^Obsidian$", space = 3 })
    agate.rule({ app = "^Things$", monitor = small, space = 1 })
    agate.rule({ app = "^Mail$", monitor = small, space = 2 })

    -- Vesktop / Spotify: when an external is attached they live on the internal
    -- display (spaces 2 and 3); on the laptop alone they move to spaces 4 and 5.
    if internal_id and external_count > 0 then
        agate.rule({ app = "^Vesktop$", monitor = internal_id, space = 2 })
        agate.rule({ app = "^Spotify$", monitor = internal_id, space = 3 })
    else
        agate.rule({ app = "^Vesktop$", space = 4 })
        agate.rule({ app = "^Spotify$", space = 5 })
    end
end

-- Apply now, and re-apply whenever a display is plugged in or unplugged so the
-- placement tracks docking/undocking.
apply_rules()
agate.on("monitors_changed", function(e)
    print(string.format("agate: monitors changed -> %d connected; reapplying rules", e.count))
    apply_rules()
end)

print("agate: config loaded")
