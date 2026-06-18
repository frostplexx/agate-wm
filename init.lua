-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Gaps, hyper key, and Flow strip tuning.
--
-- Every workspace is a Flow strip: a horizontally scrollable row of columns.
-- While the columns fit at `min_column_width` the strip fills the screen like a
-- classic tiler; only past that capacity does it scroll, keeping off-screen
-- columns peeking at the edges. A column can itself be a vertical split/stack
-- (see consume/expel below), so traditional tiling lives inside the strip.
agate.config({
    gaps = 4,                           -- space between tiles
    outer_gaps = 4,                     -- inset from the screen edge
    accordion_padding = 20,             -- stacked-window "peek": how far each window fans out
    hyper_key = { enabled = true, keys = { "ctrl", "alt", "cmd" }, },
    smart_gaps = true,                  -- disable gaps when only one tile is visible

    -- Animate frame changes: the strip glides when you scroll / focus / resize a
    -- column instead of snapping. (A live trackpad scroll-drag still tracks your
    -- finger 1:1 and only eases on release.)
    animations = true,
    animation_duration = 130,           -- milliseconds (lower = snappier)

    -- Flow strip. On-screen capacity before it scrolls is ~floor(1/min_column_width):
    -- 0.4 → 2 columns fit, so a 3rd window starts scrolling; 0.33 → 3 fit; 0.25 → 4 fit.
    default_column_width = 0.5,         -- a new column targets half the viewport
    min_column_width = 0.4,             -- shrink to here before the strip scrolls (≈2 columns fit)
    preset_column_widths = { 1/3, 1/2, 2/3, 1.0 }, -- cycled by column_width wider/narrower
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
agate.bind("hyper+shift+h", function() agate.scroll("start") end)              -- leftmost column
agate.bind("hyper+shift+l", function() agate.scroll("end") end)               -- rightmost column
agate.bind("hyper+0", function() agate.scroll("center") end)                  -- center focused column

agate.bind("hyper+space", function() agate.zoom_fullscreen() end)

-- Move the focused window to an adjacent slot / column.
agate.bind("hyper+shift+j", "move down")
agate.bind("hyper+shift+k", "move up")
agate.bind("hyper+shift+comma", "move left")                                   -- swap with the left column
agate.bind("hyper+shift+period", "move right")                                 -- swap with the right column

-- Column width (Flow strip): cycle the focused column through the presets, or
-- snap it to a specific fraction. `fit` re-equalizes every column (classic tiling).
agate.bind("hyper+plus", function() agate.column_width("wider") end)
agate.bind("hyper+minus", function() agate.column_width("narrower") end)
agate.bind("hyper+f", function() agate.fit() end)                              -- tile columns evenly
agate.bind("hyper+m", function() agate.column_width("full") end)              -- maximize the column

-- Consume / expel: merge the focused column with a neighbour into a vertical
-- split (traditional tiling inside a column), or eject a window back to its own
-- column on the strip.
agate.bind("hyper+comma", function() agate.consume("left") end)               -- pull the left column in
agate.bind("hyper+period", function() agate.expel("right") end)               -- eject to its own column

-- Layout of the *focused column's* internal tiling (only applies once a column
-- holds more than one window, e.g. after `consume`). The workspace itself is
-- always the Flow strip and can't be switched away from it.
agate.bind("hyper+v", function() agate.layout("v_split") end)                   -- split the column vertically
agate.bind("hyper+b", function() agate.layout("h_split") end)                   -- split the column horizontally
agate.bind("hyper+e", function() agate.layout("toggle") end)                    -- swap split orientation
agate.bind("hyper+s", function() agate.layout("accordion") end)                 -- stack the column (peek)

-- Resize the focused tile within its column (column width uses hyper+r above).
agate.bind("hyper+minus", function() agate.resize("smart", -50) end)
agate.bind("hyper+equal", function() agate.resize("smart", 50) end)
-- Instant space switching — uses SLSManagedDisplaySetCurrentSpace directly,
-- not gesture emulation (which fails on macOS 26+).
agate.bind("hyper+1", function() agate.space(1) end)
agate.bind("hyper+2", function() agate.space(2) end)
agate.bind("hyper+3", function() agate.space(3) end)
agate.bind("hyper+4", function() agate.space(4) end)
agate.bind("hyper+5", function() agate.space(5) end)
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
