/* Error reporting for the encoders when they are built on their own (tests, the hardware
 * check). Linked with the capture side, mlh_common.c defines the same functions. */
#include <stdarg.h>
#include <stdio.h>

#include "enc_internal.h"

static _Thread_local char last_error[512];

const char *mlh_last_error(void) { return last_error; }

void mlh_clear_error(void) { last_error[0] = 0; }

int mlh_fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(last_error, sizeof last_error, fmt, ap);
    va_end(ap);
    fprintf(stderr, "host-linux: %s\n", last_error);
    return code;
}

void mlh_log(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "host-linux: %s\n", buf);
}
