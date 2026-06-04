#ifndef UTILS_LOG_H
#define UTILS_LOG_H

#include <stdbool.h>

// Lightweight debug logging to stderr, enabled when the environment variable
// AGATE_DEBUG is set to a non-empty value. Each line is prefixed with a
// monotonic timestamp and a short tag so event ordering/timing is visible:
//   [12345.678][tag] message
//
// Run with logging:  AGATE_DEBUG=1 just run

void agate_log(const char *tag, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
bool agate_log_enabled(void);

// Convenience wrapper that stamps the call site's tag.
#define LOG(tag, ...) agate_log((tag), __VA_ARGS__)

#endif // UTILS_LOG_H
