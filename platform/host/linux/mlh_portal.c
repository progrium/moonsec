/* xdg-desktop-portal ScreenCast over libdbus (see mlh.h).
 *
 * The portal's calls that may show a dialog answer through a Request object: the call
 * returns its path at once and the result comes later as its Response signal. We
 * subscribe to the signal on the path the portal will use (built from our unique bus
 * name and a handle_token we choose) before calling, so a fast answer is not missed.
 * The session lives as long as this bus connection; closing either stops the streams.
 * https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <dbus/dbus.h>

#include "mlh_internal.h"

#define PORTAL_BUS "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SCREENCAST_IFACE "org.freedesktop.portal.ScreenCast"
#define REQUEST_IFACE "org.freedesktop.portal.Request"
#define SESSION_IFACE "org.freedesktop.portal.Session"
#define MAX_STREAMS 16

struct mlh_portal {
    DBusConnection *conn;
    /* Our unique name as the portal spells it in object paths (":1.42" -> "1_42"). */
    char sender[128];
    char *session;
    char session_match[512];
    uint32_t version;
    uint32_t cursor_modes;
    uint32_t cursor_mode;
    char *restore_token;
    mlh_stream_info streams[MAX_STREAMS];
    uint32_t n_streams;
    int closed;
    unsigned token_seq;
};

/* ------------------------------------------------------------------------ */
/* a{sv} building */

static void dict_open(DBusMessageIter *it, DBusMessageIter *dict) {
    dbus_message_iter_open_container(it, DBUS_TYPE_ARRAY, "{sv}", dict);
}

static void dict_add(DBusMessageIter *dict, const char *key, int type, const char *sig, const void *val) {
    DBusMessageIter e, v;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &e);
    dbus_message_iter_append_basic(&e, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&e, DBUS_TYPE_VARIANT, sig, &v);
    dbus_message_iter_append_basic(&v, type, val);
    dbus_message_iter_close_container(&e, &v);
    dbus_message_iter_close_container(dict, &e);
}

static void dict_add_str(DBusMessageIter *dict, const char *key, const char *s) {
    dict_add(dict, key, DBUS_TYPE_STRING, "s", &s);
}

static void dict_add_u32(DBusMessageIter *dict, const char *key, uint32_t u) {
    dict_add(dict, key, DBUS_TYPE_UINT32, "u", &u);
}

static void dict_add_bool(DBusMessageIter *dict, const char *key, int b) {
    dbus_bool_t v = b ? TRUE : FALSE;
    dict_add(dict, key, DBUS_TYPE_BOOLEAN, "b", &v);
}

/* ------------------------------------------------------------------------ */
/* a{sv} reading: finds `key` and returns an iterator into its variant's value. */

static int dict_find(DBusMessageIter *dict_in, const char *key, DBusMessageIter *val) {
    if (dbus_message_iter_get_arg_type(dict_in) != DBUS_TYPE_ARRAY) return 0;
    DBusMessageIter arr;
    dbus_message_iter_recurse(dict_in, &arr);
    while (dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY) {
        DBusMessageIter e;
        dbus_message_iter_recurse(&arr, &e);
        const char *k = NULL;
        if (dbus_message_iter_get_arg_type(&e) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&e, &k);
            dbus_message_iter_next(&e);
            if (k && strcmp(k, key) == 0 && dbus_message_iter_get_arg_type(&e) == DBUS_TYPE_VARIANT) {
                dbus_message_iter_recurse(&e, val);
                return 1;
            }
        }
        dbus_message_iter_next(&arr);
    }
    return 0;
}

static const char *dict_str(DBusMessageIter *dict, const char *key) {
    DBusMessageIter v;
    if (!dict_find(dict, key, &v)) return NULL;
    int t = dbus_message_iter_get_arg_type(&v);
    if (t != DBUS_TYPE_STRING && t != DBUS_TYPE_OBJECT_PATH) return NULL;
    const char *s = NULL;
    dbus_message_iter_get_basic(&v, &s);
    return s;
}

static int dict_u32(DBusMessageIter *dict, const char *key, uint32_t *out) {
    DBusMessageIter v;
    if (!dict_find(dict, key, &v) || dbus_message_iter_get_arg_type(&v) != DBUS_TYPE_UINT32) return 0;
    dbus_message_iter_get_basic(&v, out);
    return 1;
}

/* A (ii) struct. */
static int dict_pair(DBusMessageIter *dict, const char *key, int32_t *a, int32_t *b) {
    DBusMessageIter v, s;
    if (!dict_find(dict, key, &v) || dbus_message_iter_get_arg_type(&v) != DBUS_TYPE_STRUCT) return 0;
    dbus_message_iter_recurse(&v, &s);
    if (dbus_message_iter_get_arg_type(&s) != DBUS_TYPE_INT32) return 0;
    dbus_message_iter_get_basic(&s, a);
    dbus_message_iter_next(&s);
    if (dbus_message_iter_get_arg_type(&s) != DBUS_TYPE_INT32) return 0;
    dbus_message_iter_get_basic(&s, b);
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Properties */

static int get_u32_property(mlh_portal *p, const char *prop, uint32_t *out) {
    DBusMessage *m = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get");
    if (!m) return MLH_E_NOMEM;
    const char *iface = SCREENCAST_IFACE;
    dbus_message_append_args(m, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &prop, DBUS_TYPE_INVALID);
    DBusError err;
    dbus_error_init(&err);
    /* The first call may start the portal (D-Bus activation): allow for that. */
    DBusMessage *r = dbus_connection_send_with_reply_and_block(p->conn, m, 25000, &err);
    dbus_message_unref(m);
    if (!r) {
        int rc = mlh_fail(MLH_E_NODEVICE, "ScreenCast portal: %s", err.message ? err.message : "no reply");
        dbus_error_free(&err);
        return rc;
    }
    DBusMessageIter it, v;
    int ok = 0;
    if (dbus_message_iter_init(r, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&it, &v);
        if (dbus_message_iter_get_arg_type(&v) == DBUS_TYPE_UINT32) {
            dbus_message_iter_get_basic(&v, out);
            ok = 1;
        }
    }
    dbus_message_unref(r);
    return ok ? MLH_OK : mlh_fail(MLH_E_FAIL, "ScreenCast portal: property %s is not a u32", prop);
}

/* ------------------------------------------------------------------------ */
/* Requests */

/* Handles a message that is not the one being waited for: the session's Closed. */
static void handle_other(mlh_portal *p, DBusMessage *m) {
    if (p->session && dbus_message_is_signal(m, SESSION_IFACE, "Closed") && dbus_message_has_path(m, p->session)) {
        if (!p->closed) mlh_log("ScreenCast session closed by the portal");
        p->closed = 1;
    }
}

typedef void (*append_fn)(mlh_portal *p, DBusMessageIter *args, const char *token, void *ctx);
typedef int (*results_fn)(mlh_portal *p, DBusMessageIter *results, void *ctx);

/* Calls ScreenCast.`method` (args from `append`, which must add handle_token = token to its
 * options) and waits for the Request's Response; `on_results` reads the results. */
static int request(mlh_portal *p, const char *method, append_fn append, results_fn on_results, void *ctx, uint32_t timeout_ms) {
    char token[64], path[512], match[768];
    snprintf(token, sizeof token, "moonsec%d_%u", (int)getpid(), ++p->token_seq);
    snprintf(path, sizeof path, PORTAL_PATH "/request/%s/%s", p->sender, token);
    snprintf(match, sizeof match, "type='signal',interface='" REQUEST_IFACE "',member='Response',path='%s'", path);
    DBusError err;
    dbus_error_init(&err);
    dbus_bus_add_match(p->conn, match, &err);
    if (dbus_error_is_set(&err)) {
        int rc = mlh_fail(MLH_E_FAIL, "D-Bus AddMatch: %s", err.message);
        dbus_error_free(&err);
        return rc;
    }

    int rc = MLH_E_FAIL;
    DBusMessage *m = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH, SCREENCAST_IFACE, method);
    if (!m) {
        rc = MLH_E_NOMEM;
        goto out;
    }
    DBusMessageIter args;
    dbus_message_iter_init_append(m, &args);
    append(p, &args, token, ctx);
    DBusMessage *r = dbus_connection_send_with_reply_and_block(p->conn, m, 10000, &err);
    dbus_message_unref(m);
    if (!r) {
        rc = mlh_fail(MLH_E_FAIL, "ScreenCast.%s: %s", method, err.message ? err.message : "no reply");
        dbus_error_free(&err);
        goto out;
    }
    /* Portals before 0.9 returned another path than the one built from the token. */
    const char *got_path = NULL;
    char returned[512] = "";
    if (dbus_message_get_args(r, NULL, DBUS_TYPE_OBJECT_PATH, &got_path, DBUS_TYPE_INVALID) && got_path)
        snprintf(returned, sizeof returned, "%s", got_path);
    dbus_message_unref(r);
    if (returned[0] && strcmp(returned, path) != 0) {
        char match2[768];
        snprintf(match2, sizeof match2, "type='signal',interface='" REQUEST_IFACE "',member='Response',path='%s'", returned);
        dbus_bus_add_match(p->conn, match2, NULL);
        snprintf(path, sizeof path, "%s", returned);
    }

    int64_t deadline = mlh_now_us() + (int64_t)(timeout_ms ? timeout_ms : 300000) * 1000;
    for (;;) {
        DBusMessage *s;
        while ((s = dbus_connection_pop_message(p->conn)) != NULL) {
            if (dbus_message_is_signal(s, REQUEST_IFACE, "Response") && dbus_message_has_path(s, path)) {
                DBusMessageIter it;
                uint32_t response = 2;
                if (dbus_message_iter_init(s, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_UINT32) {
                    dbus_message_iter_get_basic(&it, &response);
                    dbus_message_iter_next(&it);
                }
                if (response == 0)
                    rc = on_results ? on_results(p, &it, ctx) : MLH_OK;
                else if (response == 1)
                    rc = mlh_fail(MLH_E_DENIED, "ScreenCast.%s: cancelled", method);
                else
                    rc = mlh_fail(MLH_E_DENIED, "ScreenCast.%s: refused (response %u)", method, response);
                dbus_message_unref(s);
                goto out;
            }
            handle_other(p, s);
            dbus_message_unref(s);
        }
        int64_t left = deadline - mlh_now_us();
        if (left <= 0) {
            rc = mlh_fail(MLH_E_DENIED, "ScreenCast.%s: no answer in %u ms", method, timeout_ms ? timeout_ms : 300000);
            /* Dismiss the dialog. */
            DBusMessage *c = dbus_message_new_method_call(PORTAL_BUS, path, REQUEST_IFACE, "Close");
            if (c) {
                dbus_connection_send(p->conn, c, NULL);
                dbus_connection_flush(p->conn);
                dbus_message_unref(c);
            }
            goto out;
        }
        if (!dbus_connection_read_write(p->conn, (int)(left / 1000 > 200 ? 200 : left / 1000 + 1))) {
            rc = mlh_fail(MLH_E_CLOSED, "ScreenCast.%s: the session bus went away", method);
            goto out;
        }
    }
out:
    dbus_bus_remove_match(p->conn, match, NULL);
    return rc;
}

/* CreateSession(a{sv} options) -> session_handle */
static void append_create(mlh_portal *p, DBusMessageIter *args, const char *token, void *ctx) {
    (void)p;
    (void)ctx;
    char stoken[64];
    snprintf(stoken, sizeof stoken, "moonsec_session%d", (int)getpid());
    DBusMessageIter d;
    dict_open(args, &d);
    dict_add_str(&d, "handle_token", token);
    dict_add_str(&d, "session_handle_token", stoken);
    dbus_message_iter_close_container(args, &d);
}

static int results_create(mlh_portal *p, DBusMessageIter *results, void *ctx) {
    (void)ctx;
    const char *s = dict_str(results, "session_handle");
    if (!s) return mlh_fail(MLH_E_FAIL, "CreateSession: no session_handle");
    p->session = strdup(s);
    return p->session ? MLH_OK : MLH_E_NOMEM;
}

/* SelectSources(o session, a{sv} options) */
static void append_select(mlh_portal *p, DBusMessageIter *args, const char *token, void *ctx) {
    const mlh_portal_options *o = ctx;
    const char *session = p->session;
    dbus_message_iter_append_basic(args, DBUS_TYPE_OBJECT_PATH, &session);
    DBusMessageIter d;
    dict_open(args, &d);
    dict_add_str(&d, "handle_token", token);
    dict_add_u32(&d, "types", MLH_SOURCE_MONITOR);
    dict_add_bool(&d, "multiple", o->multiple);
    if (p->version >= 2 && p->cursor_mode) dict_add_u32(&d, "cursor_mode", p->cursor_mode);
    if (p->version >= 4) {
        dict_add_u32(&d, "persist_mode", o->persist_mode);
        if (o->restore_token && o->restore_token[0]) dict_add_str(&d, "restore_token", o->restore_token);
    }
    dbus_message_iter_close_container(args, &d);
}

/* Start(o session, s parent_window, a{sv} options) -> streams, restore_token */
static void append_start(mlh_portal *p, DBusMessageIter *args, const char *token, void *ctx) {
    (void)ctx;
    const char *session = p->session;
    const char *parent = "";
    dbus_message_iter_append_basic(args, DBUS_TYPE_OBJECT_PATH, &session);
    dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &parent);
    DBusMessageIter d;
    dict_open(args, &d);
    dict_add_str(&d, "handle_token", token);
    dbus_message_iter_close_container(args, &d);
}

static int results_start(mlh_portal *p, DBusMessageIter *results, void *ctx) {
    (void)ctx;
    DBusMessageIter v;
    if (!dict_find(results, "streams", &v) || dbus_message_iter_get_arg_type(&v) != DBUS_TYPE_ARRAY)
        return mlh_fail(MLH_E_FAIL, "Start: no streams");
    DBusMessageIter arr;
    dbus_message_iter_recurse(&v, &arr);
    p->n_streams = 0;
    while (dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_STRUCT && p->n_streams < MAX_STREAMS) {
        DBusMessageIter s;
        dbus_message_iter_recurse(&arr, &s);
        mlh_stream_info *si = &p->streams[p->n_streams];
        memset(si, 0, sizeof *si);
        si->x = si->y = -1;
        if (dbus_message_iter_get_arg_type(&s) == DBUS_TYPE_UINT32) {
            dbus_message_iter_get_basic(&s, &si->node_id);
            dbus_message_iter_next(&s);
            dict_pair(&s, "position", &si->x, &si->y);
            dict_pair(&s, "size", &si->width, &si->height);
            dict_u32(&s, "source_type", &si->source_type);
            const char *mid = dict_str(&s, "mapping_id");
            if (mid) snprintf(si->mapping_id, sizeof si->mapping_id, "%s", mid);
            p->n_streams++;
        }
        dbus_message_iter_next(&arr);
    }
    if (p->n_streams == 0) return mlh_fail(MLH_E_FAIL, "Start: empty stream list");
    const char *tok = dict_str(results, "restore_token");
    free(p->restore_token);
    p->restore_token = tok ? strdup(tok) : NULL;
    return MLH_OK;
}

/* ------------------------------------------------------------------------ */

static uint32_t pick_cursor_mode(uint32_t want, uint32_t available) {
    if (want == 0) return 0;
    const uint32_t order_meta[] = {MLH_CURSOR_METADATA, MLH_CURSOR_EMBEDDED, MLH_CURSOR_HIDDEN};
    const uint32_t order_emb[] = {MLH_CURSOR_EMBEDDED, MLH_CURSOR_METADATA, MLH_CURSOR_HIDDEN};
    const uint32_t order_hidden[] = {MLH_CURSOR_HIDDEN, MLH_CURSOR_METADATA, MLH_CURSOR_EMBEDDED};
    const uint32_t *order = want == MLH_CURSOR_METADATA ? order_meta : want == MLH_CURSOR_EMBEDDED ? order_emb : order_hidden;
    for (int i = 0; i < 3; i++)
        if (available & order[i]) return order[i];
    return 0;
}

int mlh_portal_open(const mlh_portal_options *o, mlh_portal **out) {
    *out = NULL;
    struct mlh_portal *p = calloc(1, sizeof *p);
    if (!p) return MLH_E_NOMEM;
    DBusError err;
    dbus_error_init(&err);
    /* A private connection: the session is ours alone and ends when we close it. */
    p->conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!p->conn) {
        int rc = mlh_fail(MLH_E_NODEVICE, "session bus: %s", err.message ? err.message : "unavailable");
        dbus_error_free(&err);
        free(p);
        return rc;
    }
    dbus_connection_set_exit_on_disconnect(p->conn, FALSE);
    const char *unique = dbus_bus_get_unique_name(p->conn);
    size_t j = 0;
    for (const char *c = unique ? unique + 1 : ""; *c && j + 1 < sizeof p->sender; c++) p->sender[j++] = *c == '.' ? '_' : *c;
    p->sender[j] = 0;

    int rc = get_u32_property(p, "version", &p->version);
    if (rc < 0) goto fail;
    if (p->version >= 2 && get_u32_property(p, "AvailableCursorModes", &p->cursor_modes) < 0) p->cursor_modes = 0;
    p->cursor_mode = pick_cursor_mode(o->cursor_mode, p->cursor_modes);

    if ((rc = request(p, "CreateSession", append_create, results_create, NULL, 10000)) < 0) goto fail;
    snprintf(p->session_match, sizeof p->session_match, "type='signal',interface='" SESSION_IFACE "',member='Closed',path='%s'", p->session);
    dbus_bus_add_match(p->conn, p->session_match, NULL);
    if ((rc = request(p, "SelectSources", append_select, NULL, (void *)o, o->timeout_ms)) < 0) goto fail;
    if ((rc = request(p, "Start", append_start, results_start, NULL, o->timeout_ms)) < 0) goto fail;
    mlh_log("ScreenCast portal v%u: %u stream(s), node %u %dx%d, cursor mode %u (available %u), restore token %s",
            p->version, p->n_streams, p->streams[0].node_id, p->streams[0].width, p->streams[0].height, p->cursor_mode,
            p->cursor_modes, p->restore_token ? "yes" : "no");
    *out = p;
    return MLH_OK;
fail:
    mlh_portal_close(p);
    return rc;
}

void mlh_portal_close(mlh_portal *p) {
    if (!p) return;
    if (p->conn) {
        if (p->session && !p->closed) {
            DBusMessage *m = dbus_message_new_method_call(PORTAL_BUS, p->session, SESSION_IFACE, "Close");
            if (m) {
                DBusMessage *r = dbus_connection_send_with_reply_and_block(p->conn, m, 2000, NULL);
                if (r) dbus_message_unref(r);
                dbus_message_unref(m);
            }
        }
        dbus_connection_close(p->conn);
        dbus_connection_unref(p->conn);
    }
    free(p->session);
    free(p->restore_token);
    free(p);
}

uint32_t mlh_portal_version(const mlh_portal *p) {
    return p->version;
}

uint32_t mlh_portal_cursor_mode(const mlh_portal *p) {
    return p->cursor_mode;
}

uint32_t mlh_portal_stream_count(const mlh_portal *p) {
    return p->n_streams;
}

int mlh_portal_stream(const mlh_portal *p, uint32_t i, mlh_stream_info *out) {
    if (i >= p->n_streams) return MLH_E_UNSUPPORTED;
    *out = p->streams[i];
    return MLH_OK;
}

const char *mlh_portal_restore_token(const mlh_portal *p) {
    return p->restore_token;
}

int mlh_portal_pipewire_fd(mlh_portal *p, int *fd) {
    *fd = -1;
    DBusMessage *m = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH, SCREENCAST_IFACE, "OpenPipeWireRemote");
    if (!m) return MLH_E_NOMEM;
    DBusMessageIter args, d;
    dbus_message_iter_init_append(m, &args);
    const char *session = p->session;
    dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &session);
    dict_open(&args, &d);
    dbus_message_iter_close_container(&args, &d);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage *r = dbus_connection_send_with_reply_and_block(p->conn, m, 10000, &err);
    dbus_message_unref(m);
    if (!r) {
        int rc = mlh_fail(MLH_E_FAIL, "OpenPipeWireRemote: %s", err.message ? err.message : "no reply");
        dbus_error_free(&err);
        return rc;
    }
    int got = -1;
    if (!dbus_message_get_args(r, &err, DBUS_TYPE_UNIX_FD, &got, DBUS_TYPE_INVALID)) {
        int rc = mlh_fail(MLH_E_FAIL, "OpenPipeWireRemote: %s", err.message ? err.message : "no fd");
        dbus_error_free(&err);
        dbus_message_unref(r);
        return rc;
    }
    dbus_message_unref(r);
    *fd = got;
    return MLH_OK;
}

int mlh_portal_poll(mlh_portal *p) {
    if (!p->closed) {
        if (!dbus_connection_read_write(p->conn, 0)) {
            p->closed = 1;
        } else {
            DBusMessage *s;
            while ((s = dbus_connection_pop_message(p->conn)) != NULL) {
                handle_other(p, s);
                dbus_message_unref(s);
            }
        }
    }
    return p->closed ? MLH_E_LOST : MLH_OK;
}

/* ------------------------------------------------------------------------ */
/* Restore token file */

int mlh_token_load(const char *path, char *buf, size_t cap) {
    if (cap == 0) return MLH_E_FAIL;
    buf[0] = 0;
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) return MLH_TIMEOUT;
        return mlh_fail(MLH_E_FAIL, "%s: %s", path, strerror(errno));
    }
    if (!fgets(buf, (int)cap, f)) buf[0] = 0;
    fclose(f);
    size_t n = strlen(buf);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) buf[--n] = 0;
    return n ? MLH_OK : MLH_TIMEOUT;
}

static void mkdirs(const char *path) {
    char dir[4096];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (!slash || slash == dir) return;
    *slash = 0;
    for (char *c = dir + 1; *c; c++) {
        if (*c != '/') continue;
        *c = 0;
        mkdir(dir, 0700);
        *c = '/';
    }
    mkdir(dir, 0700);
}

int mlh_token_store(const char *path, const char *token) {
    mkdirs(path);
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.%d.tmp", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return mlh_fail(MLH_E_FAIL, "%s: %s", tmp, strerror(errno));
    size_t n = strlen(token);
    int ok = write(fd, token, n) == (ssize_t)n && write(fd, "\n", 1) == 1 && fsync(fd) == 0;
    close(fd);
    if (!ok || rename(tmp, path) != 0) {
        int rc = mlh_fail(MLH_E_FAIL, "%s: %s", path, strerror(errno));
        unlink(tmp);
        return rc;
    }
    return MLH_OK;
}
