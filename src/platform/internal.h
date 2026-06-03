#ifndef PLATFORM_INTERNAL_H
#define PLATFORM_INTERNAL_H

#import <Foundation/Foundation.h>

// Shared between the platform implementation files (not part of the public API).

// ManagedSpaceID (preferred) or id64 out of a SkyLight space / "Current Space"
// dictionary, as returned by SLSCopyManagedDisplaySpaces. 0 if neither is
// present. Implemented in space.m; also used by the follow.m space scan.
uint64_t platform_managed_space_id(NSDictionary *dict);

#endif // PLATFORM_INTERNAL_H
