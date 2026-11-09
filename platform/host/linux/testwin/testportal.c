/* A ScreenCast portal backend for the host tests (see testportal.h): what
 * xdg-desktop-portal-wlr or -gnome would be, minus the dialog. It runs on its own thread
 * with its own bus connection, owns org.freedesktop.impl.portal.desktop.moonsectest, and
 * answers the real portal frontend's calls:
 *
 *   CreateSession, SelectSources   remember the session's persist mode and whether the
 *                                  frontend passed restore data (from a restore token)
 *   Start                          one monitor stream: the configured PipeWire node, and
 *                                  restore data when persisting, which the frontend turns
 *                                  into the restore token the app gets
 *   Session.Close, Request.Close   acknowledged
 *
 * Interface: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.ScreenCast.html */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dbus/dbus.h>

#include "testportal.h"

#define IMPL_NAME "org.freedesktop.impl.portal.desktop.moonsectest"
#define IMPL_PATH "/org/freedesktop/portal/desktop"
#define SC_IFACE "org.freedesktop.impl.portal.ScreenCast"
#define RESTORE_KEY "moonsec-test"

struct session {
    char path[256];
    uint32_t persist_mode;
    uint32_t cursor_mode;
    int restored;
};

static struct {
    DBusConnection *conn;
    pthread_t thread;
    _Atomic int stop;
    _Atomic int running;
    uint32_t node, width, height, cursor_modes;
    struct session sessions[16];
    _Atomic uint32_t starts, restored_starts, last_cursor_mode, last_persist_mode;
} tp;

static struct session *find_session(const char *path, int create) {
    for (int i = 0; i < 16; i++)
        if (tp.sessions[i].path[0] && strcmp(tp.sessions[i].path, path) == 0) return &tp.sessions[i];
    if (!create) return NULL;
    for (int i = 0; i < 16; i++) {
        if (!tp.sessions[i].path[0]) {
            memset(&tp.sessions[i], 0, sizeof tp.sessions[i]);
            snprintf(tp.sessions[i].path, sizeof tp.sessions[i].path, "%s", path);
            return &tp.sessions[i];
        }
    }
    return NULL;
}

/* ------------------------------------------------------------------------ */
/* Variants */

static void open_entry(DBusMessageIter *dict, const char *key, const char *sig, DBusMessageIter *e, DBusMessageIter *v) {
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, e);
    dbus_message_iter_append_basic(e, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(e, DBUS_TYPE_VARIANT, sig, v);
}

static void close_entry(DBusMessageIter *dict, DBusMessageIter *e, DBusMessageIter *v) {
    dbus_message_iter_close_container(e, v);
    dbus_message_iter_close_container(dict, e);
}

static void add_u32(DBusMessageIter *dict, const char *key, uint32_t u) {
    DBusMessageIter e, v;
    open_entry(dict, key, "u", &e, &v);
    dbus_message_iter_append_basic(&v, DBUS_TYPE_UINT32, &u);
    close_entry(dict, &e, &v);
}

static void add_pair(DBusMessageIter *dict, const char *key, int32_t a, int32_t b) {
    DBusMessageIter e, v, s;
    open_entry(dict, key, "(ii)", &e, &v);
    dbus_message_iter_open_container(&v, DBUS_TYPE_STRUCT, NULL, &s);
    dbus_message_iter_append_basic(&s, DBUS_TYPE_INT32, &a);
    dbus_message_iter_append_basic(&s, DBUS_TYPE_INT32, &b);
    dbus_message_iter_close_container(&v, &s);
    close_entry(dict, &e, &v);
}

/* Finds `key` in the a{sv} at `it`; *val is the variant's content. */
static int find_key(DBusMessageIter *it, const char *key, DBusMessageIter *val) {
    if (dbus_message_iter_get_arg_type(it) != DBUS_TYPE_ARRAY) return 0;
    DBusMessageIter arr;
    dbus_message_iter_recurse(it, &arr);
    while (dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_DICT_ENTRY) {
        DBusMessageIter e;
        dbus_message_iter_recurse(&arr, &e);
        const char *k = NULL;
        dbus_message_iter_get_basic(&e, &k);
        dbus_message_iter_next(&e);
        if (k && strcmp(k, key) == 0) {
            dbus_message_iter_recurse(&e, val);
            return 1;
        }
        dbus_message_iter_next(&arr);
    }
    return 0;
}

static uint32_t opt_u32(DBusMessageIter *it, const char *key, uint32_t def) {
    DBusMessageIter v;
    if (!find_key(it, key, &v) || dbus_message_iter_get_arg_type(&v) != DBUS_TYPE_UINT32) return def;
    uint32_t u;
    dbus_message_iter_get_basic(&v, &u);
    return u;
}

/* ------------------------------------------------------------------------ */
/* Replies */

static void reply_response(DBusMessage *m, void (*fill)(DBusMessageIter *dict, void *ctx), void *ctx) {
    DBusMessage *r = dbus_message_new_method_return(m);
    DBusMessageIter it, dict;
    dbus_message_iter_init_append(r, &it);
    uint32_t ok = 0;
    dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &ok);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &dict);
    if (fill) fill(&dict, ctx);
    dbus_message_iter_close_container(&it, &dict);
    dbus_connection_send(tp.conn, r, NULL);
    dbus_message_unref(r);
}

static void reply_empty(DBusMessage *m) {
    DBusMessage *r = dbus_message_new_method_return(m);
    dbus_connection_send(tp.conn, r, NULL);
    dbus_message_unref(r);
}

static void append_prop(DBusMessageIter *it, const char *prop) {
    uint32_t v = strcmp(prop, "AvailableSourceTypes") == 0 ? 1u : strcmp(prop, "AvailableCursorModes") == 0 ? tp.cursor_modes : 5u;
    DBusMessageIter var;
    dbus_message_iter_open_container(it, DBUS_TYPE_VARIANT, "u", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_UINT32, &v);
    dbus_message_iter_close_container(it, &var);
}

static void fill_start(DBusMessageIter *dict, void *ctx) {
    struct session *s = ctx;
    DBusMessageIter e, v, arr, st, props;
    open_entry(dict, "streams", "a(ua{sv})", &e, &v);
    dbus_message_iter_open_container(&v, DBUS_TYPE_ARRAY, "(ua{sv})", &arr);
    dbus_message_iter_open_container(&arr, DBUS_TYPE_STRUCT, NULL, &st);
    dbus_message_iter_append_basic(&st, DBUS_TYPE_UINT32, &tp.node);
    dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "{sv}", &props);
    add_pair(&props, "position", 0, 0);
    add_pair(&props, "size", (int32_t)tp.width, (int32_t)tp.height);
    add_u32(&props, "source_type", 1);
    dbus_message_iter_close_container(&st, &props);
    dbus_message_iter_close_container(&arr, &st);
    dbus_message_iter_close_container(&v, &arr);
    close_entry(dict, &e, &v);
    if (s && s->persist_mode) {
        add_u32(dict, "persist_mode", s->persist_mode);
        /* restore_data (suv): a vendor key, a version and our data (the output). */
        DBusMessageIter rs, data;
        open_entry(dict, "restore_data", "(suv)", &e, &v);
        dbus_message_iter_open_container(&v, DBUS_TYPE_STRUCT, NULL, &rs);
        const char *key = RESTORE_KEY;
        uint32_t ver = 1;
        const char *out = "weston.pipewire";
        dbus_message_iter_append_basic(&rs, DBUS_TYPE_STRING, &key);
        dbus_message_iter_append_basic(&rs, DBUS_TYPE_UINT32, &ver);
        dbus_message_iter_open_container(&rs, DBUS_TYPE_VARIANT, "s", &data);
        dbus_message_iter_append_basic(&data, DBUS_TYPE_STRING, &out);
        dbus_message_iter_close_container(&rs, &data);
        dbus_message_iter_close_container(&v, &rs);
        close_entry(dict, &e, &v);
    }
}

static void handle(DBusMessage *m) {
    if (dbus_message_get_type(m) != DBUS_MESSAGE_TYPE_METHOD_CALL) return;
    const char *iface = dbus_message_get_interface(m);
    const char *member = dbus_message_get_member(m);
    if (!iface || !member) return;
    DBusMessageIter it;
    dbus_message_iter_init(m, &it);

    if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0) {
        const char *piface = NULL, *prop = NULL;
        if (strcmp(member, "Get") == 0 && dbus_message_get_args(m, NULL, DBUS_TYPE_STRING, &piface, DBUS_TYPE_STRING, &prop, DBUS_TYPE_INVALID)) {
            DBusMessage *r = dbus_message_new_method_return(m);
            DBusMessageIter ri;
            dbus_message_iter_init_append(r, &ri);
            append_prop(&ri, prop);
            dbus_connection_send(tp.conn, r, NULL);
            dbus_message_unref(r);
            return;
        }
        if (strcmp(member, "GetAll") == 0) {
            DBusMessage *r = dbus_message_new_method_return(m);
            DBusMessageIter ri, dict, e;
            dbus_message_iter_init_append(r, &ri);
            dbus_message_iter_open_container(&ri, DBUS_TYPE_ARRAY, "{sv}", &dict);
            const char *props[] = {"AvailableSourceTypes", "AvailableCursorModes", "version"};
            for (int i = 0; i < 3; i++) {
                dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL, &e);
                dbus_message_iter_append_basic(&e, DBUS_TYPE_STRING, &props[i]);
                append_prop(&e, props[i]);
                dbus_message_iter_close_container(&dict, &e);
            }
            dbus_message_iter_close_container(&ri, &dict);
            dbus_connection_send(tp.conn, r, NULL);
            dbus_message_unref(r);
            return;
        }
    } else if (strcmp(iface, SC_IFACE) == 0) {
        /* (o handle, o session, s app_id, [s parent,] a{sv} options) */
        const char *session = NULL;
        dbus_message_iter_next(&it);
        dbus_message_iter_get_basic(&it, &session);
        dbus_message_iter_next(&it);
        dbus_message_iter_next(&it);
        if (strcmp(member, "Start") == 0) dbus_message_iter_next(&it);
        if (strcmp(member, "CreateSession") == 0) {
            find_session(session, 1);
            reply_response(m, NULL, NULL);
            return;
        }
        struct session *s = find_session(session, 0);
        if (strcmp(member, "SelectSources") == 0 && s) {
            s->persist_mode = opt_u32(&it, "persist_mode", 0);
            s->cursor_mode = opt_u32(&it, "cursor_mode", 1);
            DBusMessageIter v, st;
            s->restored = 0;
            if (find_key(&it, "restore_data", &v) && dbus_message_iter_get_arg_type(&v) == DBUS_TYPE_STRUCT) {
                dbus_message_iter_recurse(&v, &st);
                const char *key = NULL;
                if (dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_STRING) dbus_message_iter_get_basic(&st, &key);
                s->restored = key && strcmp(key, RESTORE_KEY) == 0;
            }
            reply_response(m, NULL, NULL);
            return;
        }
        if (strcmp(member, "Start") == 0 && s) {
            atomic_fetch_add(&tp.starts, 1);
            if (s->restored) atomic_fetch_add(&tp.restored_starts, 1);
            atomic_store(&tp.last_cursor_mode, s->cursor_mode);
            atomic_store(&tp.last_persist_mode, s->persist_mode);
            reply_response(m, fill_start, s);
            return;
        }
    } else if (strcmp(iface, "org.freedesktop.impl.portal.Session") == 0 && strcmp(member, "Close") == 0) {
        struct session *s = find_session(dbus_message_get_path(m), 0);
        if (s) s->path[0] = 0;
        reply_empty(m);
        return;
    } else if (strcmp(iface, "org.freedesktop.impl.portal.Request") == 0 && strcmp(member, "Close") == 0) {
        reply_empty(m);
        return;
    }
    DBusMessage *r = dbus_message_new_error(m, DBUS_ERROR_UNKNOWN_METHOD, member);
    dbus_connection_send(tp.conn, r, NULL);
    dbus_message_unref(r);
}

static void *run(void *arg) {
    (void)arg;
    while (!atomic_load(&tp.stop)) {
        if (!dbus_connection_read_write(tp.conn, 50)) break;
        DBusMessage *m;
        while ((m = dbus_connection_pop_message(tp.conn)) != NULL) {
            handle(m);
            dbus_message_unref(m);
        }
    }
    return NULL;
}

int mlh_testportal_start(uint32_t node, uint32_t width, uint32_t height, uint32_t cursor_modes) {
    if (atomic_load(&tp.running)) return 0;
    DBusError err;
    dbus_error_init(&err);
    tp.conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!tp.conn) {
        fprintf(stderr, "testportal: %s\n", err.message ? err.message : "no session bus");
        dbus_error_free(&err);
        return -1;
    }
    dbus_connection_set_exit_on_disconnect(tp.conn, FALSE);
    int r = dbus_bus_request_name(tp.conn, IMPL_NAME, DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
    if (r != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        fprintf(stderr, "testportal: cannot own %s: %s\n", IMPL_NAME, err.message ? err.message : "taken");
        dbus_error_free(&err);
        return -1;
    }
    tp.node = node;
    tp.width = width;
    tp.height = height;
    tp.cursor_modes = cursor_modes;
    if (pthread_create(&tp.thread, NULL, run, NULL) != 0) return -1;
    atomic_store(&tp.running, 1);
    return 0;
}

void mlh_testportal_counts(uint32_t *starts, uint32_t *restored_starts, uint32_t *cursor_mode, uint32_t *persist_mode) {
    *starts = atomic_load(&tp.starts);
    *restored_starts = atomic_load(&tp.restored_starts);
    *cursor_mode = atomic_load(&tp.last_cursor_mode);
    *persist_mode = atomic_load(&tp.last_persist_mode);
}
