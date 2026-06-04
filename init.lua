-- agate-wm configuration.
-- Loaded on startup from $WM_CONFIG, $XDG_CONFIG_HOME/agate/init.lua,
-- ~/.config/agate/init.lua, or ./init.lua (this file, for development).

-- Gaps and normalization (i3/AeroSpace tiling rules).
agate.config({
  gaps = 8,         -- space between tiles
  outer_gaps = 8,   -- inset from the screen edge
  -- "hyper" expands to this modifier set in keyspecs below.
  hyper = { "ctrl", "alt", "cmd", "shift" },
  enable_normalization_flatten_containers = true,
  enable_normalization_opposite_orientation_for_nested_containers = true,
})

-- Focus movement (i3-style hjkl).
agate.bind("hyper+h", function() agate.focus("left") end)
agate.bind("hyper+j", function() agate.focus("down") end)
agate.bind("hyper+k", function() agate.focus("up") end)
agate.bind("hyper+l", function() agate.focus("right") end)

-- Move the focused window (string-command form also works).
agate.bind("hyper+shift+h", "move left")
agate.bind("hyper+shift+j", "move down")
agate.bind("hyper+shift+k", "move up")
agate.bind("hyper+shift+l", "move right")

-- Layout control.
agate.bind("hyper+b", function() agate.layout("h_tiles") end) -- split horizontally
agate.bind("hyper+v", function() agate.layout("v_tiles") end) -- split vertically

-- Resize the focused tile.
agate.bind("hyper+minus", function() agate.resize("left", 50) end)
agate.bind("hyper+equal", function() agate.resize("right", 50) end)

-- Per-app overrides for the dialog heuristic. Dialogs (and windows without a
-- fullscreen button) float automatically; use these to force an app one way.
-- agate.on_window_detected({ app_id = "com.apple.systempreferences", action = "float" })
-- agate.on_window_detected({ app_id = "com.apple.ActivityMonitor", action = "tile" })

print("agate: config loaded")
