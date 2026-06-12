# TODOs


## "Small Screen Mode" — DONE

Implemented (see `docs/configuration.md`):

- On the built-in display (or any display ≤ `small_screen.max_width` points),
  workspaces on the default split layout switch to a horizontal accordion
  (`small_screen.layout`, also `"tabs"` = zero-peek full-size stack); they
  switch back when a big external display takes over (dock/undock
  re-evaluates; hand-set layouts are left alone).
- Trackpad gestures à la Hyprland: raw touches via the private
  MultitouchSupport framework (`src/macos/multitouch.zig`), a discrete-step
  swipe recognizer (`src/wm/gestures.zig`), Lua bindings via
  `agate.gesture("3:left", fn)`. Default config: 3-finger swipe cycles the
  accordion (`agate.cycle`), also on `hyper+tab`.

Possible follow-ups:

- Continuous swipe: drag the accordion live with the fingers (1:1 tracking
  with rubber-banding) instead of discrete steps.
- A drawn tab bar for the "tabs" variant (needs our own overlay window).

## UX — DONE

Implemented (see `docs/configuration.md`):

- Drag preview (`drag_preview = true`): while dragging a window, a translucent
  rounded overlay (`src/macos/overlay.zig`, borderless NSWindow) highlights the
  tile it will swap into — the same centre-over-slot test `applyManualMove`
  uses on drop. Drag detection now recurses into nested containers, so windows
  inside sub-stacks can be dragged too.
- Space indicator in the menu bar (`space_indicator = true`):
  `src/macos/statusbar.zig` NSStatusItem showing the active user-space index
  ("–" on fullscreen spaces), updated from `onSpaceChanged`.
- Animations:
    - `animations = true` + `animation_duration = 0.15` (seconds): window-server
      transform animation (`src/wm/animate.zig`, yabai's model). Real frames
      apply instantly via AX (EUI disabled), then `SLSSetWindowTransform`
      sweeps the windows visually old→new at 120 Hz with ease-out cubic. No
      per-frame app/AX involvement → works for every app incl. Electron, and
      the speed is just the duration. Self-disables (windows snap) if the
      window server rejects cross-process transforms. The earlier
      AXEnhancedUserInterface approach was removed: uncontrollable speed,
      app-dependent, and the app relayouts on every step.
    - `space_animation = "fast" | "very_fast" | "instant"` — the synthetic
      dock-swipe's `ended`-phase velocity is the speed knob (instant = 9999,
      yabai #2781). fast/very_fast values may need empirical tuning.

