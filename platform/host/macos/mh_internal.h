/* Shared by the Objective-C files only (not translated for Zig). */
#pragma once
#include "mh.h"

/* Sets this thread's mh_last_error and returns `code`. */
int mh_fail(int code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void mh_clear_error(void);

/* Pixel format constants for MH_FMT_*. */
uint32_t mh_fmt_to_cv(uint32_t fmt);
uint32_t mh_cv_to_fmt(uint32_t cv);

/* Waits on a dispatch semaphore for at most `ms`; 0 when signalled. */
#define MH_WAIT(sem, ms) dispatch_semaphore_wait((sem), dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms) * NSEC_PER_MSEC))

#ifdef __OBJC__
@class SCDisplay;
/* The ScreenCaptureKit display for display `index` (as mh_display_id), fetched
 * synchronously (waits up to 5 s). Nil with *rc set (and the error message) on failure;
 * a TCC refusal is MH_ERR_PERMISSION. Initializes the window server connection first. */
SCDisplay *mh_sc_display(uint32_t index, int *rc);
/* Maps an SCStream / SCShareableContent error to an MH_ERR code and sets the message. */
int mh_sc_fail(NSError *err, const char *what);
#endif
