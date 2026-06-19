-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Every workspace is a Flow strip: a horizontally scrollable row of columns.
-- While the columns fit at `columns.min_width` the strip fills the screen like a
-- classic tiler; only past that capacity does it scroll, keeping off-screen
-- columns peeking at the edges. A column can itself be a vertical split/stack
-- (see consume/expel below), so traditional tiling lives inside the strip.
agate.config({
    gaps = { inner = 4, outer = 4, smart = true }, -- inner/edge gaps; smart drops the edge gap for a lone window
    peek = 48,                          -- how far a hidden window peeks: accordion fan AND the strip's off-screen edge
    hyper_key = { enabled = true, keys = { "ctrl", "alt", "cmd" } },

    -- Animate frame changes: the strip glides when you scroll / focus / resize a
    -- column instead of snapping. A number is the per-frame duration in ms
    -- (lower = snappier); use `true`/`false` for the default speed / off.
    animations = 130,

    -- Flow strip columns. On-screen capacity before it scrolls is ~floor(1/min_width):
    -- 0.4 → 2 columns fit, so a 3rd window starts scrolling; 0.33 → 3 fit; 0.25 → 4 fit.
    columns = {
        default_width = 0.5,            -- a new column targets half the viewport
        min_width = 0.4,                -- shrink to here before the strip scrolls (≈2 columns fit)
        presets = { 1/3, 1/2, 2/3, 1.0 }, -- cycled by column_width wider/narrower
    },
    swipe_scroll_fingers = 3,           -- 3-finger horizontal swipe scrolls the strip live
})


-- Gestures. A 3-finger *horizontal* swipe scrolls the strip live (set above), so
-- only the vertical 3-finger swipes are free for discrete actions here.
agate.gesture("3:down", function() agate.focus("down") end)
agate.gesture("3:up", function() agate.focus("up") end)


-- Focus movement (i3-style hjkl). On the strip, left/right step between columns
-- (auto-scrolling the focused one into view); up/down move within a column.
agate.bind("hyper+h", function() agate.focus("left") end)
agate.bind("hyper+j", function() agate.focus("down") end)
agate.bind("hyper+k", function() agate.focus("up") end)
agate.bind("hyper+l", function() agate.focus("right") end)

-- Jump to the strip's ends / center the focused column.
agate.bind("hyper+shift+comma", function() agate.scroll("start") end)         -- leftmost column
agate.bind("hyper+shift+period", function() agate.scroll("end") end)          -- rightmost column
agate.bind("hyper+0", function() agate.scroll("center") end)                  -- center focused column

agate.bind("hyper+space", function() agate.toggle("fullscreen") end)

-- Move the focused window to an adjacent slot / column.
agate.bind("hyper+shift+j", "move down")
agate.bind("hyper+shift+k", "move up")
agate.bind("hyper+shift+l", "move left")                                      -- swap with the left column
agate.bind("hyper+shift+h", "move right")                                     -- swap with the right column

-- Column width (Flow strip): cycle the focused column through the presets, snap
-- it to a width, or `"fit"` to re-equalize every column (classic tiling).
agate.bind("hyper+plus", function() agate.column_width("wider") end)
agate.bind("hyper+minus", function() agate.column_width("narrower") end)
agate.bind("hyper+f", function() agate.column_width("fit") end)               -- tile columns evenly
agate.bind("hyper+m", function() agate.column_width("full") end)              -- maximize the column

-- Consume / expel: merge the focused column with a neighbour into a vertical
-- split (traditional tiling inside a column), or eject a window back to its own
-- column on the strip.
agate.bind("hyper+comma", function() agate.consume("left") end)              -- pull the left column in
agate.bind("hyper+period", function() agate.expel("right") end)             -- eject to its own column

-- Layout of the *focused column's* internal tiling. On a single-window column
-- this arms the split (i3-style): the next window you open tiles into this column
-- with the chosen layout instead of starting its own column on the strip. On a
-- multi-window column it re-tiles right away. The workspace itself is always the
-- Flow strip and can't be switched away from it.
agate.bind("hyper+v", function() agate.layout("v_split") end)                 -- split the column vertically
agate.bind("hyper+b", function() agate.layout("h_split") end)                 -- split the column horizontally
agate.bind("hyper+e", function() agate.layout("toggle") end)                  -- swap split orientation
agate.bind("hyper+s", function() agate.layout("accordion") end)              -- stack the column (peek)

-- Resize the focused tile within its column (column width uses hyper+plus/minus above).
agate.bind("hyper+bracketleft", function() agate.resize("smart", -50) end)
agate.bind("hyper+bracketright", function() agate.resize("smart", 50) end)

for i = 1, 9 do
    agate.bind("hyper+" .. i, function() agate.space(i) end)
    -- Send the focused window to space i, then follow it there.
    agate.bind("hyper+shift+" .. i, function()
        agate.move("space", i)
        agate.space(i)
    end)
end

-- Window assignment rules (yabai-style): when a matching window appears, it is
-- sent to the given space and the view follows it there (`follow = false` to
-- route it in the background instead). `app`/`title` are POSIX extended regexes
-- (at least one required). The last matching rule wins.
agate.rule({ app = "^Ghostty$", space = 2 })
agate.rule({ app = "^Zen$", space = 1 })
agate.rule({ app = "^Obsidian$", space = 3 })
agate.rule({ app = "^Things$", space = 3 })
agate.rule({ app = "^Spotify$", space = 5 })
agate.rule({ app = "^Vesktop$", space = 4 })

print("agate: config loaded")
