/* The host tests' own ScreenCast portal backend (testportal.c): the real
 * xdg-desktop-portal frontend routes ScreenCast to it under headless.sh, and it answers
 * with one monitor stream on `node` without a dialog. Not part of the backend. */
#ifndef MLH_TESTPORTAL_H
#define MLH_TESTPORTAL_H

#include <stdint.h>

/* Owns the backend's bus name and serves it on a thread (once per process; later calls
 * do nothing). `cursor_modes`: what AvailableCursorModes says. */
int mlh_testportal_start(uint32_t node, uint32_t width, uint32_t height, uint32_t cursor_modes);
/* Start calls served, how many of them came with restore data from a restore token,
 * and the last session's cursor and persist modes. */
void mlh_testportal_counts(uint32_t *starts, uint32_t *restored_starts, uint32_t *cursor_mode, uint32_t *persist_mode);

#endif
