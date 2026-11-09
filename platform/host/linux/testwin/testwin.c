/* See testwin.h. */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <wayland-client.h>

#include "../../../client/linux/protocol/xdg-shell-client-protocol.h"
#include "testwin.h"

struct buf {
    struct wl_buffer *wb;
    uint8_t *px;
    int busy;
};

struct mlh_testwin {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    uint32_t width, height, stride;
    int configured;
    struct buf bufs[2];
    int current;
    uint8_t *map;
    size_t map_size;
};

static void on_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    struct mlh_testwin *w = data;
    (void)version;
    if (strcmp(iface, wl_compositor_interface.name) == 0) w->compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0) w->shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0) w->wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
}
static void on_global_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data, (void)r, (void)name;
}
static const struct wl_registry_listener registry_listener = {on_global, on_global_remove};

static void on_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = {on_ping};

static void on_xdg_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    struct mlh_testwin *w = data;
    xdg_surface_ack_configure(s, serial);
    w->configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = {on_xdg_configure};

static void on_toplevel_configure(void *data, struct xdg_toplevel *t, int32_t width, int32_t height, struct wl_array *states) {
    struct mlh_testwin *w = data;
    (void)t, (void)states;
    if (width > 0 && height > 0 && !w->bufs[0].wb) {
        w->width = (uint32_t)width;
        w->height = (uint32_t)height;
    }
}
static void on_toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)data, (void)t;
}
static const struct xdg_toplevel_listener toplevel_listener = {.configure = on_toplevel_configure, .close = on_toplevel_close};

static void on_buffer_release(void *data, struct wl_buffer *b) {
    (void)b;
    ((struct buf *)data)->busy = 0;
}
static const struct wl_buffer_listener buffer_listener = {on_buffer_release};

int mlh_testwin_create(const char *title, uint32_t *width, uint32_t *height, mlh_testwin **out) {
    *out = NULL;
    struct mlh_testwin *w = calloc(1, sizeof *w);
    if (!w) return -1;
    w->width = 1280;
    w->height = 720;
    w->display = wl_display_connect(NULL);
    if (!w->display) {
        free(w);
        return -2;
    }
    w->registry = wl_display_get_registry(w->display);
    wl_registry_add_listener(w->registry, &registry_listener, w);
    wl_display_roundtrip(w->display);
    if (!w->compositor || !w->shm || !w->wm_base) {
        mlh_testwin_destroy(w);
        return -3;
    }
    xdg_wm_base_add_listener(w->wm_base, &wm_base_listener, w);
    w->surface = wl_compositor_create_surface(w->compositor);
    w->xdg_surface = xdg_wm_base_get_xdg_surface(w->wm_base, w->surface);
    xdg_surface_add_listener(w->xdg_surface, &xdg_surface_listener, w);
    w->toplevel = xdg_surface_get_toplevel(w->xdg_surface);
    xdg_toplevel_add_listener(w->toplevel, &toplevel_listener, w);
    xdg_toplevel_set_title(w->toplevel, title);
    xdg_toplevel_set_fullscreen(w->toplevel, NULL);
    wl_surface_commit(w->surface);
    for (int i = 0; i < 100 && !w->configured; i++) wl_display_roundtrip(w->display);
    if (!w->configured) {
        mlh_testwin_destroy(w);
        return -4;
    }
    w->stride = w->width * 4;
    size_t one = (size_t)w->stride * w->height;
    w->map_size = one * 2;
    int fd = memfd_create("moonsec-testwin", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)w->map_size) < 0) {
        if (fd >= 0) close(fd);
        mlh_testwin_destroy(w);
        return -5;
    }
    w->map = mmap(NULL, w->map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (w->map == MAP_FAILED) {
        w->map = NULL;
        close(fd);
        mlh_testwin_destroy(w);
        return -5;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(w->shm, fd, (int32_t)w->map_size);
    for (int i = 0; i < 2; i++) {
        w->bufs[i].px = w->map + one * (size_t)i;
        w->bufs[i].wb = wl_shm_pool_create_buffer(pool, (int32_t)(one * (size_t)i), (int32_t)w->width, (int32_t)w->height,
                                                  (int32_t)w->stride, WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(w->bufs[i].wb, &buffer_listener, &w->bufs[i]);
    }
    wl_shm_pool_destroy(pool);
    close(fd);
    w->current = -1;
    *width = w->width;
    *height = w->height;
    *out = w;
    return 0;
}

void mlh_testwin_destroy(mlh_testwin *w) {
    if (!w) return;
    for (int i = 0; i < 2; i++)
        if (w->bufs[i].wb) wl_buffer_destroy(w->bufs[i].wb);
    if (w->map) munmap(w->map, w->map_size);
    if (w->toplevel) xdg_toplevel_destroy(w->toplevel);
    if (w->xdg_surface) xdg_surface_destroy(w->xdg_surface);
    if (w->surface) wl_surface_destroy(w->surface);
    if (w->wm_base) xdg_wm_base_destroy(w->wm_base);
    if (w->shm) wl_shm_destroy(w->shm);
    if (w->compositor) wl_compositor_destroy(w->compositor);
    if (w->registry) wl_registry_destroy(w->registry);
    if (w->display) wl_display_disconnect(w->display);
    free(w);
}

uint8_t *mlh_testwin_buffer(mlh_testwin *w, uint32_t *stride) {
    for (int i = 0; i < 2; i++) {
        int k = (w->current + 1 + i) & 1;
        if (!w->bufs[k].busy) {
            w->current = k;
            *stride = w->stride;
            return w->bufs[k].px;
        }
    }
    return NULL;
}

int mlh_testwin_commit(mlh_testwin *w) {
    if (w->current < 0) return -1;
    struct buf *b = &w->bufs[w->current];
    b->busy = 1;
    wl_surface_attach(w->surface, b->wb, 0, 0);
    wl_surface_damage_buffer(w->surface, 0, 0, (int32_t)w->width, (int32_t)w->height);
    wl_surface_commit(w->surface);
    return wl_display_flush(w->display) < 0 && errno != EAGAIN ? -1 : 0;
}

int mlh_testwin_dispatch(mlh_testwin *w, int timeout_ms) {
    while (wl_display_prepare_read(w->display) != 0) wl_display_dispatch_pending(w->display);
    wl_display_flush(w->display);
    struct pollfd p = {.fd = wl_display_get_fd(w->display), .events = POLLIN};
    if (poll(&p, 1, timeout_ms) > 0) {
        if (wl_display_read_events(w->display) < 0) return -1;
    } else {
        wl_display_cancel_read(w->display);
    }
    return wl_display_dispatch_pending(w->display) < 0 ? -1 : 0;
}
