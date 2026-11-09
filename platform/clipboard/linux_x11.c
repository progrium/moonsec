// X11 clipboard backend (the fallback when no Wayland data-control protocol is there): the
// CLIPBOARD selection through an unmapped window, XFixes for change notification.
//
// The thread owns its own Display. On every ownership change it converts the selection to
// UTF8_STRING (following INCR transfers) and caches the text; while we own the selection it
// answers SelectionRequest for TARGETS and the text targets, refusing (not INCR-sending)
// text larger than one property can carry.
#define _GNU_SOURCE
#include "linux_clip.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct x_clip {
    struct msc_clip_common common;
    Display *dpy;
    Window win;
    int fixes_event;
    Atom clipboard, utf8, targets, text, incr, prop, timestamp;
    char *own;
    size_t own_len;
    int owner;
    Time own_time;
};

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void serve(struct x_clip *x, XSelectionRequestEvent *rq) {
    XSelectionEvent ev = {
        .type = SelectionNotify,
        .display = rq->display,
        .requestor = rq->requestor,
        .selection = rq->selection,
        .target = rq->target,
        .property = None,
        .time = rq->time,
    };
    Atom prop = rq->property != None ? rq->property : rq->target;
    size_t max = (size_t)XExtendedMaxRequestSize(x->dpy);
    if (max == 0) max = (size_t)XMaxRequestSize(x->dpy);
    max = max * 4 - 1024;
    if (x->owner && rq->selection == x->clipboard) {
        if (rq->target == x->targets) {
            Atom list[] = {x->targets, x->timestamp, x->utf8, x->text, XA_STRING};
            XChangeProperty(x->dpy, rq->requestor, prop, XA_ATOM, 32, PropModeReplace, (unsigned char *)list, 5);
            ev.property = prop;
        } else if (rq->target == x->timestamp) {
            long t = (long)x->own_time;
            XChangeProperty(x->dpy, rq->requestor, prop, XA_INTEGER, 32, PropModeReplace, (unsigned char *)&t, 1);
            ev.property = prop;
        } else if ((rq->target == x->utf8 || rq->target == x->text || rq->target == XA_STRING) && x->own_len <= max) {
            // STRING is Latin-1 by the book; most clients accept UTF-8 there anyway.
            XChangeProperty(x->dpy, rq->requestor, prop, x->utf8, 8, PropModeReplace, (unsigned char *)x->own, (int)x->own_len);
            ev.property = prop;
        }
    }
    XSendEvent(x->dpy, rq->requestor, False, NoEventMask, (XEvent *)&ev);
    XFlush(x->dpy);
}

static void handle(struct x_clip *x, XEvent *e);

// Waits for an event of `type` on our window (handling everything else meanwhile).
static int wait_for(struct x_clip *x, int type, Atom atom, XEvent *out, int timeout_ms) {
    int64_t deadline = now_ms() + timeout_ms;
    int fd = ConnectionNumber(x->dpy);
    for (;;) {
        while (XPending(x->dpy)) {
            XEvent e;
            XNextEvent(x->dpy, &e);
            if (e.type == type && e.xany.window == x->win) {
                if (type == SelectionNotify && e.xselection.selection == atom) {
                    *out = e;
                    return 0;
                }
                if (type == PropertyNotify && e.xproperty.atom == atom && e.xproperty.state == PropertyNewValue) {
                    *out = e;
                    return 0;
                }
            }
            handle(x, &e);
        }
        int64_t left = deadline - now_ms();
        if (left <= 0) return -1;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, (int)left) < 0 && errno != EINTR) return -1;
    }
}

// Reads and deletes our property. Returns 1 with data, 0 for INCR (size hint), -1 on error.
static int take_prop(struct x_clip *x, char **out, size_t *len, int *is_incr) {
    Atom type;
    int format;
    unsigned long n, after;
    unsigned char *data = NULL;
    if (XGetWindowProperty(x->dpy, x->win, x->prop, 0, (MSC_CLIP_MAX + 3) / 4, True, AnyPropertyType, &type, &format, &n, &after, &data) != Success) return -1;
    *is_incr = type == x->incr;
    if (after > 0 || format != 8) {
        if (data) XFree(data);
        return *is_incr ? 0 : -1;
    }
    *out = malloc(n + 1);
    if (*out == NULL) {
        XFree(data);
        return -1;
    }
    memcpy(*out, data, n);
    *len = n;
    XFree(data);
    return 1;
}

static void fetch(struct x_clip *x) {
    if (x->owner) {
        msc_common_set(&x->common, x->own, x->own_len);
        return;
    }
    XConvertSelection(x->dpy, x->clipboard, x->utf8, x->prop, x->win, CurrentTime);
    XFlush(x->dpy);
    XEvent e;
    if (wait_for(x, SelectionNotify, x->clipboard, &e, 1000) != 0 || e.xselection.property == None) {
        msc_common_set(&x->common, NULL, 0); // no owner, or no text
        return;
    }
    char *text = NULL;
    size_t len = 0;
    int incr = 0;
    int r = take_prop(x, &text, &len, &incr);
    if (r == 1 && !incr) {
        msc_common_set(&x->common, text, len);
        free(text);
        return;
    }
    free(text);
    if (!incr) return;
    // INCR: the owner sends chunks as we delete the property; a zero-length chunk ends it.
    char *all = NULL;
    size_t all_len = 0;
    for (;;) {
        if (wait_for(x, PropertyNotify, x->prop, &e, 1000) != 0) break;
        char *chunk = NULL;
        size_t n = 0;
        int dummy;
        if (take_prop(x, &chunk, &n, &dummy) != 1) break;
        if (n == 0) {
            free(chunk);
            msc_common_set(&x->common, all ? all : "", all_len);
            break;
        }
        if (all_len + n > MSC_CLIP_MAX) {
            free(chunk);
            break;
        }
        char *grown = realloc(all, all_len + n);
        if (grown == NULL) {
            free(chunk);
            break;
        }
        all = grown;
        memcpy(all + all_len, chunk, n);
        all_len += n;
        free(chunk);
    }
    free(all);
}

static void handle(struct x_clip *x, XEvent *e) {
    if (e->type == SelectionRequest) {
        serve(x, &e->xselectionrequest);
    } else if (e->type == SelectionClear && e->xselectionclear.selection == x->clipboard) {
        x->owner = 0;
    } else if (e->type == x->fixes_event + XFixesSelectionNotify) {
        XFixesSelectionNotifyEvent *fe = (XFixesSelectionNotifyEvent *)e;
        if (fe->selection == x->clipboard) {
            if (fe->owner != x->win) x->owner = 0;
            fetch(x);
        }
    }
}

static void own_text(struct x_clip *x, char *text, size_t len) {
    free(x->own);
    x->own = text;
    x->own_len = len;
    // A timestamp from the server (a zero-length property append) rather than CurrentTime,
    // as ICCCM asks of selection owners.
    XChangeProperty(x->dpy, x->win, x->prop, XA_STRING, 8, PropModeAppend, NULL, 0);
    XEvent e;
    Time t = CurrentTime;
    if (wait_for(x, PropertyNotify, x->prop, &e, 500) == 0) t = e.xproperty.time;
    XSetSelectionOwner(x->dpy, x->clipboard, x->win, t);
    x->owner = XGetSelectionOwner(x->dpy, x->clipboard) == x->win;
    x->own_time = t;
    XFlush(x->dpy);
    // The XFixes notification for our own ownership caches the text (fetch, owner path).
}

static void *run(void *arg) {
    struct x_clip *x = arg;
    int fd = ConnectionNumber(x->dpy);
    for (;;) {
        pthread_mutex_lock(&x->common.mu);
        int stop = x->common.stop;
        pthread_mutex_unlock(&x->common.mu);
        if (stop) break;
        while (XPending(x->dpy)) {
            XEvent e;
            XNextEvent(x->dpy, &e);
            handle(x, &e);
        }
        char *text;
        size_t len;
        if (msc_common_take_want(&x->common, &text, &len)) {
            own_text(x, text, len);
            continue;
        }
        struct pollfd p[2] = {{.fd = fd, .events = POLLIN}, {.fd = x->common.wake[0], .events = POLLIN}};
        int r = poll(p, 2, 1000);
        if (r > 0 && (p[0].revents & (POLLERR | POLLHUP))) {
            pthread_mutex_lock(&x->common.mu);
            x->common.dead = 1;
            pthread_mutex_unlock(&x->common.mu);
            break;
        }
        if (r > 0 && (p[1].revents & POLLIN)) msc_common_drain_wake(&x->common);
    }
    return NULL;
}

static void destroy(struct msc_clip_common *c) {
    struct x_clip *x = (struct x_clip *)c;
    if (x->dpy) {
        if (x->win) XDestroyWindow(x->dpy, x->win);
        XCloseDisplay(x->dpy);
    }
    free(x->own);
}

msc_clip *msc_clip_open_x11(void) {
    struct x_clip *x = calloc(1, sizeof(*x));
    if (x == NULL) return NULL;
    if (msc_common_init(&x->common) != 0) {
        free(x);
        return NULL;
    }
    x->common.destroy = destroy;
    x->dpy = XOpenDisplay(NULL);
    if (x->dpy == NULL) goto fail;
    int err;
    if (!XFixesQueryExtension(x->dpy, &x->fixes_event, &err)) goto fail;
    x->win = XCreateSimpleWindow(x->dpy, DefaultRootWindow(x->dpy), 0, 0, 1, 1, 0, 0, 0);
    XSelectInput(x->dpy, x->win, PropertyChangeMask);
    x->clipboard = XInternAtom(x->dpy, "CLIPBOARD", False);
    x->utf8 = XInternAtom(x->dpy, "UTF8_STRING", False);
    x->targets = XInternAtom(x->dpy, "TARGETS", False);
    x->text = XInternAtom(x->dpy, "TEXT", False);
    x->incr = XInternAtom(x->dpy, "INCR", False);
    x->timestamp = XInternAtom(x->dpy, "TIMESTAMP", False);
    x->prop = XInternAtom(x->dpy, "MOONSEC_CLIP", False);
    XFixesSelectSelectionInput(x->dpy, x->win, x->clipboard, XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask | XFixesSelectionClientCloseNotifyMask);
    // The content at start.
    fetch(x);
    if (msc_common_start(&x->common, run) != 0) goto fail;
    return (msc_clip *)x;
fail:
    destroy(&x->common);
    msc_common_destroy(&x->common);
    free(x);
    return NULL;
}
