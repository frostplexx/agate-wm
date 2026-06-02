# extern

Bridging declarations for the private macOS APIs used to drive windows. These
are symbols and methods that aren't in any public SDK header; the headers here
just declare them so the rest of the project can call them. No wrappers, no
abstractions — link the right framework and use them directly.

Background and live-measured behaviour: `../../skylight-snapping-report.md`.

## Files

| File | Framework | Lang | What |
|------|-----------|------|------|
| `ax_private.h` | ApplicationServices (HIServices) | C | `_AXUIElementGetWindow` (AX element → `CGWindowID`) and the undocumented `kAXTabbedWindowsAttribute` key. |
| `skylight.h` | SkyLight | C | Spaces (`SLSCopyManagedDisplaySpaces`, `SLSCopyWindowsWithOptionsAndTags`), window iteration (`SLSWindowQueryWindows`, `SLSWindowIterator*`), snap-zone detection (`SLSSnappingInfo*`), native tile spaces (`SLSSpaceCreateTile`, …). |
| `nswindow_spi.h` | AppKit | ObjC | `NSWindow` tiling SPI: `_zoomToScreenEdge:`, `_divideFrameForEdge:`, tile-state queries. For windows you own. |
| `window_management.h` | WindowManagement | ObjC | Tier-3 daemon path (`WMWindowTilingPosition`, transaction classes). Reference only — see below. |

## Linking

- `ax_private.h` — nothing extra; HIServices comes with ApplicationServices.
- `nswindow_spi.h` — nothing extra; AppKit selectors.
- `skylight.h` — `-F /System/Library/PrivateFrameworks -framework SkyLight`.
- `window_management.h` — classes are reached via `NSClassFromString`, not linked.

The `justfile` at the repo root already passes these flags and compiles every
`.c`/`.m` under `src/`.

## Which tier to use

- **Your own windows:** `nswindow_spi.h` → `_zoomToScreenEdge:` (halves) or
  `setFrame:` with a computed quarter rect. No permissions.
- **Other apps' windows:** Accessibility — resolve the AX element, then set
  `kAXPositionAttribute` / `kAXSizeAttribute`. Use `_AXUIElementGetWindow` to
  match AX windows to `CGWindowList` entries. Needs the Accessibility
  permission. This is the practical path for a layout tool.
- **Native Sequoia tiling (live divider, margins):** `skylight.h`. Snap
  detection works from any process. Creating a real tiled state via
  `SLSSpaceCreateTile` generally does not — the window server only treats it as
  tiled when the request comes from a registered WindowManager client.

## Telling real windows from tabs and sheets

AX is unreliable here: `kAXWindowsAttribute` returns tab siblings as separate
windows and sheets/drawers as windows too. Combine sources instead:

1. **Enumerate from `CGWindowListCopyWindowInfo` (public), not AX.** The window
   server only reports rendered windows, so non-selected tabs are already
   absent. Filter to layer 0 and a sane minimum size.
2. **Tab-group head:** read `kAXTabbedWindowsAttribute` (`ax_private.h`) — count
   > 1 means the other entries are tabs, not independent windows.
3. **Child window (sheet/drawer/popover):** check `kAXParentAttribute`; if the
   parent's `kAXRoleAttribute` is `kAXWindowRole`, skip it.
4. **Belt-and-suspenders for sheets AX misses:** iterate with
   `SLSWindowQueryWindows` / `SLSWindowIterator*` (`skylight.h`) and treat a
   non-zero `SLSWindowIteratorGetParentID` as a child window.

Only steps 2's key and step 4 are non-public; the rest is plain AX + CoreGraphics.

## Windows on other spaces

`CGWindowListCopyWindowInfo(..., kCGWindowListOptionOnScreenOnly, ...)` only
reports the current Mission Control space. To see every window:

1. `SLSCopyManagedDisplaySpaces` — list all spaces (walk each display's
   `"Spaces"` array, read each space's `"id64"`).
2. `SLSCopyWindowsWithOptionsAndTags(cid, 0, [spaceID], 0x2, …)` — the window
   ids in a space (a CFArray of CFNumbers).
3. `CGWindowListCreateDescriptionFromArray` — owner / title / bounds / layer for
   those ids. Note its input array stores ids as raw integer pointer values, not
   CFNumbers, so convert what SkyLight returns.

`src/enumerate.c` is a worked example of exactly this.

## Notes

- Coordinates: AX and CGWindowList use a top-left origin, y-down. `NSScreen`
  uses bottom-left, y-up — convert at the boundary.
- Setting size via AX can fail with `-25205` on apps that pin their size
  (e.g. terminals locked to a cell grid); position still applies.
- Private symbols can change or vanish between macOS releases. If you'd rather
  fail soft than fail to link, resolve them with `dlsym` instead of the `extern`
  declarations here.
