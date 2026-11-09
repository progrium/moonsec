// Wayland clipboard backend: ext-data-control-v1, or wlr-data-control-unstable-v1 where the
// compositor has only that (wlroots before 0.19, sway 1.9). Both let a client without a
// focused surface read and set the selection. The two protocols have the same requests and
// events, so one set of handlers serves both.
//
// The thread fetches each new selection's text as soon as it is announced (the offer is only
// valid until the next selection) and serves paste requests for text we own.
#define _GNU_SOURCE
#include "linux_clip.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

#include "protocols/ext-data-control-v1-client.h"
#include "protocols/wlr-data-control-unstable-v1-client.h"

static const char *const text_mimes[] = {
    "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT",
};
#define N_MIMES (sizeof(text_mimes) / sizeof(text_mimes[0]))

struct offer {
    void *proxy;
    int best; /* index into text_mimes, or -1 */
};

struct wl_clip {
    struct msc_clip_common common;
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    int ext; /* 1: ext-data-control, 0: wlr */
    void *manager;
    void *device;
    void *source; /* our current source, if we own the selection */
    char *own;
    size_t own_len;
    int expect_own;
};

// --- protocol-neutral requests ---------------------------------------------------------

static void offer_receive(struct wl_clip *w, void *o, const char *mime, int fd) {
    if (w->ext) ext_data_control_offer_v1_receive(o, mime, fd);
    else zwlr_data_control_offer_v1_receive(o, mime, fd);
}
static void offer_destroy(struct wl_clip *w, struct offer *o) {
    if (o == NULL) return;
    if (w->ext) ext_data_control_offer_v1_destroy(o->proxy);
    else zwlr_data_control_offer_v1_destroy(o->proxy);
    free(o);
}
static void source_destroy(struct wl_clip *w, void *s) {
    if (w->ext) ext_data_control_source_v1_destroy(s);
    else zwlr_data_control_source_v1_destroy(s);
}

// --- offers ----------------------------------------------------------------------------

static void on_offer_mime(void *data, void *proxy, const char *mime) {
    (void)proxy;
    struct offer *o = data;
    for (int i = 0; i < (int)N_MIMES; i++) {
        if (strcmp(mime, text_mimes[i]) == 0 && (o->best < 0 || i < o->best)) o->best = i;
    }
}
static const struct ext_data_control_offer_v1_listener offer_listener = {
    .offer = (void (*)(void *, struct ext_data_control_offer_v1 *, const char *))on_offer_mime,
};

// --- device ----------------------------------------------------------------------------

static void on_data_offer(void *data, void *dev, void *proxy) {
    (void)dev;
    struct wl_clip *w = data;
    struct offer *o = calloc(1, sizeof(*o));
    if (o == NULL) return;
    o->proxy = proxy;
    o->best = -1;
    // Same layout for both protocols' offer listeners.
    if (w->ext) ext_data_control_offer_v1_add_listener(proxy, &offer_listener, o);
    else zwlr_data_control_offer_v1_add_listener(proxy, (const struct zwlr_data_control_offer_v1_listener *)&offer_listener, o);
}

static struct offer *offer_of(void *proxy) {
    return proxy ? wl_proxy_get_user_data(proxy) : NULL;
}

static void on_selection(void *data, void *dev, void *proxy) {
    (void)dev;
    struct wl_clip *w = data;
    struct offer *o = offer_of(proxy);
    if (w->expect_own && w->source != NULL) {
        // The compositor announces our own source back to us: no need to read it.
        w->expect_own = 0;
        msc_common_set(&w->common, w->own, w->own_len);
        offer_destroy(w, o);
        return;
    }
    if (o == NULL) {
        msc_common_set(&w->common, NULL, 0);
        return;
    }
    if (o->best < 0) {
        msc_common_set(&w->common, NULL, 0); // something other than text
        offer_destroy(w, o);
        return;
    }
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) {
        offer_destroy(w, o);
        return;
    }
    offer_receive(w, o->proxy, text_mimes[o->best], fds[1]);
    close(fds[1]);
    wl_display_flush(w->display);
    char *text = NULL;
    size_t len = 0;
    if (msc_read_fd_all(fds[0], 1000, &text, &len) == 0) {
        msc_common_set(&w->common, text, len);
        free(text);
    }
    close(fds[0]);
    offer_destroy(w, o);
}

static void on_primary_selection(void *data, void *dev, void *proxy) {
    (void)dev;
    offer_destroy(data, offer_of(proxy));
}

static void on_finished(void *data, void *dev) {
    (void)dev;
    struct wl_clip *w = data;
    pthread_mutex_lock(&w->common.mu);
    w->common.dead = 1;
    pthread_mutex_unlock(&w->common.mu);
}

static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = (void (*)(void *, struct ext_data_control_device_v1 *, struct ext_data_control_offer_v1 *))on_data_offer,
    .selection = (void (*)(void *, struct ext_data_control_device_v1 *, struct ext_data_control_offer_v1 *))on_selection,
    .finished = (void (*)(void *, struct ext_data_control_device_v1 *))on_finished,
    .primary_selection = (void (*)(void *, struct ext_data_control_device_v1 *, struct ext_data_control_offer_v1 *))on_primary_selection,
};

// --- our source ------------------------------------------------------------------------

static void on_send(void *data, void *src, const char *mime, int fd) {
    (void)mime;
    struct wl_clip *w = data;
    if (src == w->source && w->own != NULL) msc_write_fd_all(fd, w->own, w->own_len);
    close(fd);
}

static void on_cancelled(void *data, void *src) {
    struct wl_clip *w = data;
    if (src == w->source) {
        w->source = NULL;
        w->expect_own = 0;
    }
    source_destroy(w, src);
}

static const struct ext_data_control_source_v1_listener source_listener = {
    .send = (void (*)(void *, struct ext_data_control_source_v1 *, const char *, int32_t))on_send,
    .cancelled = (void (*)(void *, struct ext_data_control_source_v1 *))on_cancelled,
};

static void own_text(struct wl_clip *w, char *text, size_t len) {
    free(w->own);
    w->own = text;
    w->own_len = len;
    void *src;
    if (w->ext) {
        src = ext_data_control_manager_v1_create_data_source(w->manager);
        ext_data_control_source_v1_add_listener(src, &source_listener, w);
        for (size_t i = 0; i < N_MIMES; i++) ext_data_control_source_v1_offer(src, text_mimes[i]);
        ext_data_control_device_v1_set_selection(w->device, src);
    } else {
        src = zwlr_data_control_manager_v1_create_data_source(w->manager);
        zwlr_data_control_source_v1_add_listener(src, (const struct zwlr_data_control_source_v1_listener *)&source_listener, w);
        for (size_t i = 0; i < N_MIMES; i++) zwlr_data_control_source_v1_offer(src, text_mimes[i]);
        zwlr_data_control_device_v1_set_selection(w->device, src);
    }
    // The old source gets `cancelled` and is destroyed there.
    w->source = src;
    w->expect_own = 1;
    wl_display_flush(w->display);
}

// --- registry --------------------------------------------------------------------------

static void on_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    struct wl_clip *w = data;
    if (strcmp(iface, wl_seat_interface.name) == 0 && w->seat == NULL) {
        w->seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(iface, ext_data_control_manager_v1_interface.name) == 0) {
        if (w->manager != NULL && !w->ext) zwlr_data_control_manager_v1_destroy(w->manager);
        if (w->manager == NULL || !w->ext) {
            w->manager = wl_registry_bind(reg, name, &ext_data_control_manager_v1_interface, 1);
            w->ext = 1;
        }
    } else if (strcmp(iface, zwlr_data_control_manager_v1_interface.name) == 0 && w->manager == NULL) {
        // Version 2 adds primary selection events (ignored, but harmless).
        w->manager = wl_registry_bind(reg, name, &zwlr_data_control_manager_v1_interface, version >= 2 ? 2 : 1);
        w->ext = 0;
    }
}
static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data, (void)reg, (void)name;
}
static const struct wl_registry_listener registry_listener = {.global = on_global, .global_remove = on_global_remove};

// --- thread ----------------------------------------------------------------------------

static void *run(void *arg) {
    struct wl_clip *w = arg;
    int fd = wl_display_get_fd(w->display);
    for (;;) {
        pthread_mutex_lock(&w->common.mu);
        int stop = w->common.stop;
        pthread_mutex_unlock(&w->common.mu);
        if (stop) break;
        while (wl_display_prepare_read(w->display) != 0) {
            if (wl_display_dispatch_pending(w->display) < 0) goto dead;
        }
        wl_display_flush(w->display);
        struct pollfd p[2] = {{.fd = fd, .events = POLLIN}, {.fd = w->common.wake[0], .events = POLLIN}};
        int r = poll(p, 2, 1000);
        if (r > 0 && (p[0].revents & POLLIN)) {
            if (wl_display_read_events(w->display) < 0) goto dead;
        } else {
            wl_display_cancel_read(w->display);
        }
        if (r > 0 && (p[0].revents & (POLLERR | POLLHUP))) goto dead;
        if (wl_display_dispatch_pending(w->display) < 0) goto dead;
        if (r > 0 && (p[1].revents & POLLIN)) msc_common_drain_wake(&w->common);
        char *text;
        size_t len;
        if (msc_common_take_want(&w->common, &text, &len)) own_text(w, text, len);
    }
    return NULL;
dead:
    pthread_mutex_lock(&w->common.mu);
    w->common.dead = 1;
    pthread_mutex_unlock(&w->common.mu);
    return NULL;
}

static void destroy(struct msc_clip_common *c) {
    struct wl_clip *w = (struct wl_clip *)c;
    if (w->source) source_destroy(w, w->source);
    if (w->device) {
        if (w->ext) ext_data_control_device_v1_destroy(w->device);
        else zwlr_data_control_device_v1_destroy(w->device);
    }
    if (w->manager) {
        if (w->ext) ext_data_control_manager_v1_destroy(w->manager);
        else zwlr_data_control_manager_v1_destroy(w->manager);
    }
    if (w->seat) wl_seat_destroy(w->seat);
    if (w->registry) wl_registry_destroy(w->registry);
    if (w->display) wl_display_disconnect(w->display);
    free(w->own);
}

msc_clip *msc_clip_open_wayland(void) {
    struct wl_clip *w = calloc(1, sizeof(*w));
    if (w == NULL) return NULL;
    if (msc_common_init(&w->common) != 0) {
        free(w);
        return NULL;
    }
    w->common.destroy = destroy;
    // libwayland complains on stderr when there is no compositor; don't ask then.
    if (getenv("WAYLAND_DISPLAY") == NULL && getenv("WAYLAND_SOCKET") == NULL) goto fail;
    w->display = wl_display_connect(NULL);
    if (w->display == NULL) goto fail;
    w->registry = wl_display_get_registry(w->display);
    wl_registry_add_listener(w->registry, &registry_listener, w);
    if (wl_display_roundtrip(w->display) < 0 || w->seat == NULL || w->manager == NULL) goto fail;
    if (w->ext) {
        w->device = ext_data_control_manager_v1_get_data_device(w->manager, w->seat);
        ext_data_control_device_v1_add_listener(w->device, &device_listener, w);
    } else {
        w->device = zwlr_data_control_manager_v1_get_data_device(w->manager, w->seat);
        zwlr_data_control_device_v1_add_listener(w->device, (const struct zwlr_data_control_device_v1_listener *)&device_listener, w);
    }
    // The current selection arrives in this roundtrip.
    if (wl_display_roundtrip(w->display) < 0) goto fail;
    if (msc_common_start(&w->common, run) != 0) goto fail;
    return (msc_clip *)w;
fail:
    destroy(&w->common);
    msc_common_destroy(&w->common);
    free(w);
    return NULL;
}
