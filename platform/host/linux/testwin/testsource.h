/* A PipeWire video source the host tests control (testsource.c): RGBx pictures of one
 * colour with cursor metadata, or cursor-only buffers. Not part of the backend. */
#ifndef MLH_TESTSOURCE_H
#define MLH_TESTSOURCE_H

#include <stdint.h>

typedef struct mlh_testsource mlh_testsource;

/* A Video/Source node of width x height RGBx on the default PipeWire daemon. */
int mlh_testsource_create(uint32_t width, uint32_t height, mlh_testsource **out, uint32_t *node_id);
void mlh_testsource_destroy(mlh_testsource *s);
/* Waits until a consumer linked and the stream runs. */
int mlh_testsource_wait_streaming(mlh_testsource *s, int timeout_ms);
/* Sends one buffer: a picture of colour r, g, b (or, with picture = 0, an empty chunk)
 * with the cursor at (x, y), hotspot (2, 3). A new `bitmap_serial` sends a 16x16 RGBA
 * bitmap (opaque red top half) with it. */
int mlh_testsource_push(mlh_testsource *s, int picture, uint8_t r, uint8_t g, uint8_t b, int32_t cursor_x, int32_t cursor_y, uint32_t bitmap_serial);

#endif
