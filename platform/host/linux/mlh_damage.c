/* Damage rectangle lists (see mlh.h). Plain C, no PipeWire: the capture's process
 * callback builds one per buffer from SPA_META_VideoDamage and unites them while the
 * mailbox drops buffers, and test.zig checks the arithmetic without a producer. */
#include <string.h>

#include "mlh.h"

void mlh_damage_reset(mlh_damage *d, int known) {
    d->n = 0;
    d->known = known ? 1 : 0;
}

static void push(mlh_damage *d, uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1) {
    if (d->n < MLH_DAMAGE_MAX) {
        d->r[d->n++] = (mlh_rect){x0, y0, x1 - x0, y1 - y0};
        return;
    }
    /* Full: grow the last one to cover this one too. */
    mlh_rect *l = &d->r[MLH_DAMAGE_MAX - 1];
    uint32_t lx1 = l->x + l->w, ly1 = l->y + l->h;
    if (x0 < l->x) l->x = x0;
    if (y0 < l->y) l->y = y0;
    if (x1 > lx1) lx1 = x1;
    if (y1 > ly1) ly1 = y1;
    l->w = lx1 - l->x;
    l->h = ly1 - l->y;
}

void mlh_damage_add(mlh_damage *d, int32_t x, int32_t y, uint32_t w, uint32_t h, uint32_t width, uint32_t height) {
    if (!d->known) return;
    int64_t x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int64_t x1 = (int64_t)x + w, y1 = (int64_t)y + h;
    if (x1 > width) x1 = width;
    if (y1 > height) y1 = height;
    if (x1 <= x0 || y1 <= y0) return;
    push(d, (uint32_t)x0, (uint32_t)y0, (uint32_t)x1, (uint32_t)y1);
}

void mlh_damage_union(mlh_damage *d, const mlh_damage *s) {
    if (!s->known) d->known = 0;
    if (!d->known) {
        d->n = 0;
        return;
    }
    for (uint32_t i = 0; i < s->n; i++) push(d, s->r[i].x, s->r[i].y, s->r[i].x + s->r[i].w, s->r[i].y + s->r[i].h);
}

void mlh_damage_from_meta(mlh_damage *d, const void *regions, uint32_t size, uint32_t width, uint32_t height) {
    mlh_damage_reset(d, 1);
    uint32_t valid = 0;
    const uint8_t *p = regions;
    for (uint32_t off = 0; regions && off + 16 <= size; off += 16) {
        int32_t x, y;
        uint32_t w, h;
        memcpy(&x, p + off, 4);
        memcpy(&y, p + off + 4, 4);
        memcpy(&w, p + off + 8, 4);
        memcpy(&h, p + off + 12, 4);
        if (w == 0 || h == 0) break;
        valid++;
        mlh_damage_add(d, x, y, w, h, width, height);
    }
    if (valid == 0) mlh_damage_reset(d, 0);
}

void mlh_damage_crop(const mlh_damage *in, uint32_t x, uint32_t y, uint32_t w, uint32_t h, mlh_damage *out) {
    mlh_damage_reset(out, in->known);
    if (!in->known) return;
    for (uint32_t i = 0; i < in->n; i++) {
        const mlh_rect *r = &in->r[i];
        mlh_damage_add(out, (int32_t)((int64_t)r->x - x), (int32_t)((int64_t)r->y - y), r->w, r->h, w, h);
    }
}
