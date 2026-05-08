// ax_private.h — private Accessibility (HIServices) symbols.
//
// Not in any public SDK header. Links automatically against
// ApplicationServices (HIServices); no extra -framework flag needed.

#ifndef EXTERN_AX_PRIVATE_H
#define EXTERN_AX_PRIVATE_H

#include <ApplicationServices/ApplicationServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maps an AX window element to its window-server CGWindowID — the missing link
// between the AX world and CGWindowList / SkyLight. Used by Rectangle, yabai,
// Moom, etc. Returns kAXErrorSuccess and writes *outID on success.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outID);

// Undocumented AX attribute: an array of the AXUIElements for every tab in a
// native NSWindow tab group, exposed on the currently-visible tab. There is no
// public kAX… constant. Pass to the public AXUIElementCopyAttributeValue:
//   count > 1  -> this element is a tab-group head (the others are tabs, not
//                 independent windows)
//   absent / 1 -> a standalone window
// This is how you keep AX from reporting tabs as separate manageable windows.
#define kAXTabbedWindowsAttribute CFSTR("AXTabbedWindows")

#ifdef __cplusplus
}
#endif

#endif // EXTERN_AX_PRIVATE_H
