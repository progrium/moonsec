/* Errors and the clock for the Linux host's C files (see mlh.h). */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#include <pipewire/pipewire.h>

#include "mlh_internal.h"

static _Thread_local char last_error[512];

const char *mlh_last_error(void) {
    return last_error;
}

void mlh_clear_error(void) {
    last_error[0] = 0;
}

int mlh_fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(last_error, sizeof last_error, fmt, ap);
    va_end(ap);
    fprintf(stderr, "host_linux: %s\n", last_error);
    return code;
}

void mlh_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "host_linux: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

int64_t mlh_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static pthread_once_t pw_once = PTHREAD_ONCE_INIT;

static void pw_init_once(void) {
    pw_init(NULL, NULL);
}

void mlh_pw_init(void) {
    pthread_once(&pw_once, pw_init_once);
}
