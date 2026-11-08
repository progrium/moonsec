/* A wl_shm window for the host tests: shows whatever BGRX picture the test draws, so the
 * capture tests have something known on the screen (the measurement test pattern). Not
 * part of the backend. */
#ifndef MLH_TESTWIN_H
#define MLH_TESTWIN_H

#include <stdint.h>

typedef struct mlh_testwin mlh_testwin;

/* Opens a fullscreen xdg_toplevel titled `title` on $WAYLAND_DISPLAY and waits for its
 * first configure; *width and *height get the size the compositor gave (or asked for). */
int mlh_testwin_create(const char *title, uint32_t *width, uint32_t *height, mlh_testwin **out);
void mlh_testwin_destroy(mlh_testwin *w);
/* A free buffer to draw into (B, G, R, X rows of *stride bytes); NULL when both are
 * still with the compositor. */
uint8_t *mlh_testwin_buffer(mlh_testwin *w, uint32_t *stride);
/* Attaches the buffer last returned by mlh_testwin_buffer, damages it all and commits. */
int mlh_testwin_commit(mlh_testwin *w);
/* Dispatches events, waiting up to timeout_ms for some. Negative when the connection broke. */
int mlh_testwin_dispatch(mlh_testwin *w, int timeout_ms);

#endif
