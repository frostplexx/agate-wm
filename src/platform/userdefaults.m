#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

bool platform_get_default_bool(const char *domain, const char *key)
{
    CFStringRef domainRef = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef keyRef    = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    if (!domainRef || !keyRef) {
        if (domainRef) CFRelease(domainRef);
        if (keyRef) CFRelease(keyRef);
        return false;
    }

    Boolean keyExists = false;

    Boolean value = CFPreferencesGetAppBooleanValue(
        keyRef,
        domainRef,
        &keyExists
    );

    CFRelease(domainRef);
    CFRelease(keyRef);

    if (!keyExists) {
        return false;
    }

    return value;
}
