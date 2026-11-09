/* Reading a linear dma-buf from the CPU (the software encoder's path for GPU frames):
 * mmap with DMA_BUF_IOCTL_SYNC around the read. Tiled buffers (any modifier other than
 * LINEAR) are the GPU encoders' to import; here they are unsupported. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/dma-buf.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "enc_internal.h"

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define MOD_INVALID 0x00ffffffffffffffull

typedef struct mapping {
    void *addr;
    size_t len;
    int fd;
} mapping;

int mlh_dmabuf_map(const mlh_dmabuf *d, const uint8_t **data, uint32_t *stride, uint32_t *format, void **cookie) {
    if (d->modifier != 0 && d->modifier != MOD_INVALID)
        return mlh_fail(MLH_E_UNSUPPORTED, "dma-buf: modifier 0x%llx is not linear", (unsigned long long)d->modifier);
    size_t len;
    if (d->fourcc == FOURCC('X', 'R', '2', '4') || d->fourcc == FOURCC('A', 'R', '2', '4')) {
        *format = MLH_FMT_BGRA;
        len = (size_t)d->offset[0] + (size_t)d->pitch[0] * d->height;
    } else if (d->fourcc == FOURCC('N', 'V', '1', '2')) {
        if (d->num_planes != 2 || d->fd[1] != d->fd[0] || d->pitch[1] != d->pitch[0] ||
            d->offset[1] != d->offset[0] + d->pitch[0] * d->height)
            return mlh_fail(MLH_E_UNSUPPORTED, "dma-buf: NV12 planes must be contiguous in one buffer");
        *format = MLH_FMT_NV12;
        len = (size_t)d->offset[0] + (size_t)d->pitch[0] * d->height * 3 / 2;
    } else {
        return mlh_fail(MLH_E_UNSUPPORTED, "dma-buf: format 0x%08x", d->fourcc);
    }
    mapping *m = calloc(1, sizeof *m);
    if (!m) return MLH_E_NOMEM;
    m->addr = mmap(NULL, len, PROT_READ, MAP_SHARED, d->fd[0], 0);
    if (m->addr == MAP_FAILED) {
        free(m);
        return mlh_fail(MLH_E_FAIL, "dma-buf: mmap: %s", strerror(errno));
    }
    m->len = len;
    m->fd = d->fd[0];
    struct dma_buf_sync sync = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
    ioctl(m->fd, DMA_BUF_IOCTL_SYNC, &sync); /* not a dma-buf (memfd in tests): harmless */
    *data = (const uint8_t *)m->addr + d->offset[0];
    *stride = d->pitch[0];
    *cookie = m;
    return MLH_OK;
}

void mlh_dmabuf_unmap(void *cookie) {
    mapping *m = cookie;
    struct dma_buf_sync sync = {.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ};
    ioctl(m->fd, DMA_BUF_IOCTL_SYNC, &sync);
    munmap(m->addr, m->len);
    free(m);
}
