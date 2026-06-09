-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Gaps and hyper-key definition.
agate.config({
  gaps = 8,         -- space between tiles
  outer_gaps = 8,   -- inset from the screen edge
  -- "hyper" expands to this modifier set in keyspecs below.
  hyper = { "ctrl", "alt", "cmd" },
})

-- Focus movement (i3-style hjkl).
agate.bind("hyper+h", function() agate.focus("left") end)
agate.bind("hyper+j", function() agate.focus("down") end)
agate.bind("hyper+k", function() agate.focus("up") end)
agate.bind("hyper+l", function() agate.focus("right") end)

-- Move the focused window to an adjacent slot.
agate.bind("hyper+shift+h", "move left")
agate.bind("hyper+shift+j", "move down")
agate.bind("hyper+shift+k", "move up")
agate.bind("hyper+shift+l", "move right")

-- Layout control.
agate.bind("hyper+b", function() agate.layout("h_tiles") end) -- horizontal split
agate.bind("hyper+v", function() agate.layout("v_tiles") end) -- vertical split

-- Resize the focused tile.
agate.bind("hyper+minus", function() agate.resize("left", 50) end)
agate.bind("hyper+equal", function() agate.resize("right", 50) end)

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

-- Cycle through spaces.
agate.bind("hyper+n", function() agate.space_next() end)
agate.bind("hyper+p", function() agate.space_prev() end)

print("agate: development config loaded")
