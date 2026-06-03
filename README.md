- Instant space switching 
- Moving windows between spaces
- Correctly detect native tabs
- Lua configuration
- built-in global shortcuts daemon
- Built-in hyper key functionality



Disable macOS's own space-switch-on-activate:

System Settings → Desktop & Dock → scroll to Mission Control → turn OFF:

▎ "When switching to an application, switch to a Space with open windows for the application"

This is mandatory. With it on, macOS does its own animated swoosh to the target space the instant you Cmd+Tab — beating our handler, so by the time we check, the
space is already current and we skip. You see macOS's animation, not our instant gesture. (yabai's skip_window_focus_animation requires the same.)
