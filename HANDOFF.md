# agate-wm-zig — session handoff

A macOS tiling window manager in Zig (0.16), on the `zig` branch. Long-running
daemon: builds a container tree of all windows across Spaces, tiles the active
Space, and stays live reacting to window create/destroy and mouse drags.

## Run / build

- `zig build` — compile. `zig build run` — run the daemon (blocks on the macOS
  run loop; Ctrl-C to stop). Needs Accessibility permission (checked at startup).
- It tiles the **active Space** immediately and prints the tree once at startup.
- Stop a backgrounded instance: `pkill -f agate_wm`.
- I can't synthesize real mouse drags in the harness, so drag features were
  validated by readback/logging + reasoning, not on-screen — worth a manual pass.

## Architecture (module boundaries)

- `src/main.zig` — entry; checks AX trust; builds `AppState`; calls `wm.init_wm`.
- `src/state.zig` — `AppState { skylight_cid, arena, gpa, tree }`.
- `src/macos/` — platform layer (the only place that touches macOS APIs). It is a
  standalone Zig module (`macos`); **must not import from `src/wm/`** (that caused
  a circular-module error once — keep the dependency one-way: wm → macos).
  - `c.zig` — the single `@cImport` (CoreFoundation + CGGeometry only; the CG and
    ApplicationServices umbrellas break translate-c, so other C APIs are
    hand-declared `extern`).
  - `ax.zig` — Accessibility extern decls incl. private SPI:
    `_AXUIElementGetWindow`, `_AXUIElementCreateWithRemoteToken`,
    `AXUIElementGetPid`, `AXObserver*`.
  - `accessibility.zig` — `Element` wrapper (position/size/setFrame/windowId/pid,
    `windowForId`, `windowForIdViaRemoteToken`, `enableManualAccessibility`,
    `enhancedUserInterface`/`setEnhancedUserInterface`).
  - `skylight.zig` — SkyLight/CGS private SPI (spaces, window iterator,
    `SLSWindowIsOrderedIn`, snap, notifications).
  - `spaces.zig` — `allSpaces`, `activeSpace`, `windowsOnSpace`,
    `manageableWindowsOnSpace` (+ `isManageable` tag/attribute filter).
  - `window_list.zig` — CoreGraphics window metadata (`listAll`, `infoForId`).
  - `cg.zig`, `foundation.zig`, `workspace.zig` (NSWorkspace via objc:
    `regularAppPids`, `appName`, frontmost), `display.zig` (`mainVisibleFrame`
    via NSScreen, AX/top-left coords), `clock.zig` (monotonic ms), `event_tap.zig`
    (CGEventTap externs).
- `src/wm/` — WM logic.
  - `data.zig` — i3-inspired `Con` (tree node) and `Window`. `Con` has
    `con_type`, `window`, `layout`, `gaps`, `parent`, `ratio`, `children`
    (intrusive `std.DoublyLinkedList`), `node`.
  - `tree.zig` — `build_tree`, add/remove/find leaf, `findWorkspace`,
    `findTabSibling`, `flushActive`, `applyManualResize`, `applyManualMove`.
  - `layout.zig` — `flushWorkspace`/`layoutChildren` (ratio-weighted split),
    `applyFrame` (the real frame setter).
  - `window.zig` — `init`/`fromElement`/`resolveElement`/`isOrderedIn`.
  - `observer.zig` — the daemon: per-app `AXObserver`s + the mouse event tap;
    create/destroy and drag handling; owns `CFRunLoopRun`.
  - `wm.zig` — `init_wm` + `print_tree`.

## What works

- **Discovery**: tree = Root → Monitor (per display) → Workspace (per Space) →
  Container leaves, across **all** Spaces. Manageable-window filter ported from
  yabai's `space_window_list_for_connection` (exact tag/attribute bitmasks),
  plus an `SLSWindowIsOrderedIn` filter to drop background tabs / minimized.
- **AX element resolution** is lazy (`resolveElement`): fast path = app's
  `AXWindows`; fallback = `_AXUIElementCreateWithRemoteToken` (the only way to
  get a movable ref for a window on a never-activated Space).
- **Flush** (tree → OS): `applyFrame` = `size → position → size` wrapped in the
  `AXEnhancedUserInterface` disable/restore dance (yabai `AX_ENHANCED_UI_WORKAROUND`).
  EUI-off makes native apps tile **instantly** (no animation); the double size
  is the macOS visible-area clamp workaround.
- **Live daemon**: per-app `AXObserver` (observe every regular running app via
  `regularAppPids`, so a window-less app's first window still fires).
  `AXWindowCreated` on the app element; `AXUIElementDestroyed` per window with the
  wid smuggled through `refcon`.
- **Mouse drags** via a listen-only `CGEventTap` (yabai `mouse_handler.c` model):
  nothing moves mid-drag; on `LeftMouseUp` we scan the active workspace for the
  window whose real frame changed, classify resize-vs-move from the frame delta,
  influence the tree (resize → ratio transfer to the fenced neighbour using
  yabai's changed-field direction logic; move → swap slots), and reflush once.
  Tap re-enables on `kCGEventTapDisabledBy*`.
- **Native tabs** (the last big fix): the window server has **no** tab concept
  (tabbing is pure AppKit — confirmed by dyld-cache symbol search on 26.5.1: only
  movement/ordering/shadow groups exist at CGS level, all tab symbols are
  `NSWindowTabGroup*`/`AX…TabGroup` UI roles). Detection signal = **same pid +
  identical frame** (AppKit gives a tab group one shared frame). `findTabSibling`
  → on create, a matching window **replaces** the group's leaf instead of adding
  a tile.
  - On tab **close**, `onWindowDestroyed` → `repairTabLeaf` re-pairs the leaf to
    the surviving same-frame sibling (`Element.windowMatchingFrame` over the
    app's `AXWindows`) so the group keeps its tile; a `was_tabbed` grace timer
    retries once if the promoted tab hasn't surfaced yet. Before this, closing a
    tab dropped the whole leaf (the group untiled).
  - **There is no `AXTabbedWindows` attribute on macOS 26** (dyld-cache search:
    absent) — the prior `isTabbed()` always returned false, so tab membership is
    now tracked by *observing the join* (`is_tabbed=true` when `findTabSibling`
    hits), not by querying AX. `AXFocusedTabChanged` IS a real AX notification,
    useful for the future tab-switch re-tile (issue #1).

## Key learnings (non-obvious; will save re-deriving)

- macOS won't hand out AX elements for windows on never-activated Spaces →
  remote-token fallback is required.
- `SLSWindowIsOrderedIn` = "mapped", **true for windows on inactive Spaces**, and
  **false for background tabs / minimized**. But it's **unreliable at create-time**
  (even real new windows read `false` for a moment) — do not gate create on it.
- The trailing `setSize` in `size→pos→size` is fine *as long as EUI is disabled*;
  the "terminal re-anchor" I first blamed on it was actually the EUI animation.
- Resize math conserves total ratio, so gaps are not a model bug; exact frames
  applied with EUI-off stick (`want == got`), so no readback compensation needed.

## Known issues / limitations (good next-session targets)

1. **No focus/space-change observers.** A pure tab switch (Cmd+1/click) or Space
   change doesn't re-tile until the next flush-causing event.
   `kCGSNotificationSpaceChanged` is already declared in `skylight.zig`;
   `CGSRegisterNotifyProc` is the hook. This also unlocks proper deviation
   snap-back and tab-switch re-tile.
2. **Window created on an inactive Space** is added to the *active* workspace
   (`onWindowCreated` assumes active). Should resolve the window's real Space
   (`SLSCopySpacesForWindows`).
3. **Tab edges**: frame-match can misfire if an app opens a genuine new window
   exactly atop a same-app window (rare). (Closing the *tracked* front tab while
   the group persists is now handled by `repairTabLeaf` — fixed.)
4. **Multi-display**: tree has per-display Monitors, but `flushActive` only uses
   `display.mainVisibleFrame()` (main screen). Needs per-display frames.
5. **Layout is flat** (one split level, single-neighbour resize). No nested
   split containers / true BSP like i3/yabai yet (`Con` supports it; the ops
   don't build nesting). No `tree_flatten` equivalent.
6. Debug logging remains: `[observer] +window/-window` one-liners.
7. No config, keybindings, or IPC yet. `data.zig` has unused i3-style
   `Match`/`Assignment` scaffolding and a `lib/regexp.zig` binding.

## Attribution

Techniques ported from yabai (koekeishiya/yabai) are cited in-code with the
source file/function: SLS manageable filter (`src/space.c`), remote token &
`set_window_frame` (`src/window_manager.c`), `AX_ENHANCED_UI_WORKAROUND`
(`src/misc/helpers.h`), observer model (`src/application.c`), mouse handler
(`src/mouse_handler.c`). Native-tab handling is **not** from yabai (it doesn't do
it) — it's our frame-identity approach.
