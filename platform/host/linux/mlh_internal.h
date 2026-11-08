/* For the C files only: error reporting shared by mlh_*.c. */
#ifndef MLH_INTERNAL_H
#define MLH_INTERNAL_H

#include "mlh.h"

/* Records (and prints to stderr) the last error on this thread; returns `code`. */
int mlh_fail(int code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void mlh_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
/* pw_init once per process. */
void mlh_pw_init(void);

#endif
