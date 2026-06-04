#include "log.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

bool agate_log_enabled(void) {
    static int state = -1; // -1 = not yet resolved
    if (state < 0) {
        const char *e = getenv("AGATE_DEBUG");
        state = (e && e[0]) ? 1 : 0;
    }
    return state == 1;
}

void agate_log(const char *tag, const char *fmt, ...) {
    if (!agate_log_enabled()) return;

    // Seconds since the CF epoch — only the relative ordering/timing matters.
    fprintf(stderr, "[%.3f][%-6s] ", CFAbsoluteTimeGetCurrent(), tag);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);

    fputc('\n', stderr);
}
