// Shared state and helpers for the Linux clipboard backends (linux_clip.h).
#define _GNU_SOURCE
#include "linux_clip.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int msc_common_init(struct msc_clip_common *c) {
    memset(c, 0, sizeof(*c));
    if (pthread_mutex_init(&c->mu, NULL) != 0) return -1;
    if (pipe2(c->wake, O_CLOEXEC | O_NONBLOCK) != 0) {
        pthread_mutex_destroy(&c->mu);
        return -1;
    }
    // A paste target that closes its pipe early must not kill the process.
    signal(SIGPIPE, SIG_IGN);
    return 0;
}

void msc_common_destroy(struct msc_clip_common *c) {
    close(c->wake[0]);
    close(c->wake[1]);
    free(c->text);
    free(c->want);
    pthread_mutex_destroy(&c->mu);
}

void msc_common_set(struct msc_clip_common *c, const char *text, size_t len) {
    char *copy = NULL;
    if (text != NULL) {
        copy = malloc(len + 1);
        if (copy == NULL) return;
        memcpy(copy, text, len);
        copy[len] = 0;
    }
    pthread_mutex_lock(&c->mu);
    free(c->text);
    c->text = copy;
    c->text_len = text ? len : 0;
    c->has_text = text != NULL;
    c->count++;
    pthread_mutex_unlock(&c->mu);
}

int msc_common_take_want(struct msc_clip_common *c, char **text, size_t *len) {
    pthread_mutex_lock(&c->mu);
    int has = c->has_want;
    if (has) {
        *text = c->want;
        *len = c->want_len;
        c->want = NULL;
        c->has_want = 0;
    }
    pthread_mutex_unlock(&c->mu);
    return has;
}

void msc_common_drain_wake(struct msc_clip_common *c) {
    char b[64];
    while (read(c->wake[0], b, sizeof(b)) > 0) {
    }
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int msc_read_fd_all(int fd, int timeout_ms, char **out, size_t *len) {
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    if (buf == NULL) return -1;
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        int64_t left = deadline - now_ms();
        if (left <= 0) goto fail;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int r = poll(&p, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) goto fail;
        if (n == cap) {
            if (cap >= MSC_CLIP_MAX + 1) goto fail;
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (nb == NULL) goto fail;
            buf = nb;
        }
        ssize_t got = read(fd, buf + n, cap - n);
        if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (got < 0) goto fail;
        if (got == 0) break;
        n += (size_t)got;
    }
    if (n > MSC_CLIP_MAX) goto fail;
    *out = buf;
    *len = n;
    return 0;
fail:
    free(buf);
    return -1;
}

void msc_write_fd_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, buf, len);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        buf += w;
        len -= (size_t)w;
    }
}

// --- the public API over either backend --------------------------------------------------

// Every backend struct starts with the common part.
struct msc_clip {
    struct msc_clip_common common;
};

uint64_t msc_clip_count(msc_clip *c) {
    pthread_mutex_lock(&c->common.mu);
    uint64_t n = c->common.count;
    pthread_mutex_unlock(&c->common.mu);
    return n;
}

int msc_clip_read(msc_clip *c, char **out, size_t *len) {
    int r = 0;
    pthread_mutex_lock(&c->common.mu);
    if (c->common.has_text) {
        char *b = malloc(c->common.text_len + 1);
        if (b == NULL) {
            r = -1;
        } else {
            memcpy(b, c->common.text, c->common.text_len);
            b[c->common.text_len] = 0;
            *out = b;
            *len = c->common.text_len;
            r = 1;
        }
    }
    pthread_mutex_unlock(&c->common.mu);
    return r;
}

int msc_clip_write(msc_clip *c, const char *text, size_t len) {
    if (len > MSC_CLIP_MAX) return 0;
    char *copy = malloc(len + 1);
    if (copy == NULL) return 0;
    memcpy(copy, text, len);
    copy[len] = 0;
    pthread_mutex_lock(&c->common.mu);
    free(c->common.want);
    c->common.want = copy;
    c->common.want_len = len;
    c->common.has_want = 1;
    int dead = c->common.dead;
    pthread_mutex_unlock(&c->common.mu);
    char b = 1;
    (void)!write(c->common.wake[1], &b, 1);
    return dead ? 0 : 1;
}

void msc_clip_free(char *p) { free(p); }

int msc_clip_dead(msc_clip *c) {
    pthread_mutex_lock(&c->common.mu);
    int d = c->common.dead;
    pthread_mutex_unlock(&c->common.mu);
    return d;
}

int msc_common_start(struct msc_clip_common *c, void *(*run)(void *)) {
    return pthread_create(&c->thread, NULL, run, c) == 0 ? 0 : -1;
}

void msc_clip_close(msc_clip *c) {
    if (c == NULL) return;
    pthread_mutex_lock(&c->common.mu);
    c->common.stop = 1;
    pthread_mutex_unlock(&c->common.mu);
    char b = 1;
    (void)!write(c->common.wake[1], &b, 1);
    pthread_join(c->common.thread, NULL);
    if (c->common.destroy) c->common.destroy(&c->common);
    msc_common_destroy(&c->common);
    free(c);
}
