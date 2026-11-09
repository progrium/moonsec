/* For the C files only: error reporting shared by mlc_*.c. */
#ifndef MLC_INTERNAL_H
#define MLC_INTERNAL_H

#include "mlc.h"

/* Records (and prints to stderr) the last error on this thread; returns `code`. */
int mlc_fail(int code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void mlc_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
