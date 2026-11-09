/* Linux clipboard backends (Wayland data-control, X11), C ABI for platform/clipboard/linux.zig.
 *
 * Each backend runs its own thread with its own display connection, so it can answer other
 * clients' paste requests at once and fetch the new selection as soon as it changes. The
 * caller only reads the cached text and the change count, and hands over text to own. */
#ifndef MSC_LINUX_CLIP_H
#define MSC_LINUX_CLIP_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

typedef struct msc_clip msc_clip;

/* NULL when the display or the needed protocol is not there. */
msc_clip *msc_clip_open_wayland(void);
msc_clip *msc_clip_open_x11(void);
void msc_clip_close(msc_clip *c);
uint64_t msc_clip_count(msc_clip *c);
/* 1: *out (malloc'd, free with msc_clip_free) holds *len bytes of UTF-8 text.
 * 0: the clipboard holds no text. -1: out of memory. */
int msc_clip_read(msc_clip *c, char **out, size_t *len);
/* 1 on success. */
int msc_clip_write(msc_clip *c, const char *text, size_t len);
void msc_clip_free(char *p);
/* The backend's thread failed (display gone): 1. */
int msc_clip_dead(msc_clip *c);

/* --- shared between the backends (linux_common.c) --- */

/* Text larger than this is neither fetched nor served (the control channel's 1 MiB cap). */
#define MSC_CLIP_MAX (1u << 20)

struct msc_clip_common {
    pthread_mutex_t mu;
    pthread_t thread;
    int wake[2]; /* pipe: the caller pokes the thread */
    int stop;
    int dead;
    uint64_t count;
    /* The current selection's text (cached), or has_text = 0. */
    char *text;
    size_t text_len;
    int has_text;
    /* Text the caller asked us to own, not yet taken by the thread. */
    char *want;
    size_t want_len;
    int has_want;
    /* Backend teardown, run on the caller's thread after the thread has stopped. */
    void (*destroy)(struct msc_clip_common *c);
};

/* Starts the backend's thread (run(c)); on failure the caller frees. */
int msc_common_start(struct msc_clip_common *c, void *(*run)(void *));

int msc_common_init(struct msc_clip_common *c);
void msc_common_destroy(struct msc_clip_common *c);
/* The thread learned the selection's new text (copies it; text may be NULL for none). */
void msc_common_set(struct msc_clip_common *c, const char *text, size_t len);
/* Takes the caller's pending text, if any (ownership moves to the thread). */
int msc_common_take_want(struct msc_clip_common *c, char **text, size_t *len);
void msc_common_drain_wake(struct msc_clip_common *c);
/* Reads a pipe fd to EOF with a deadline, appending to a growing buffer. -1 on error/timeout. */
int msc_read_fd_all(int fd, int timeout_ms, char **out, size_t *len);
/* Writes all of buf to fd (blocking), ignoring errors from a reader that went away. */
void msc_write_fd_all(int fd, const char *buf, size_t len);

#endif
