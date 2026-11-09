/* A multi-user host through the C ABI over iroh on loopback (spec/multi-user-v0.md): one
 * host with max_clients 2 streams to two clients at once; a third is refused while both
 * are in. Input follows the owner policy: the first member holds it, the second's input
 * is dropped until the host gives it input; INPUT_OWNER says who holds it on both
 * sides. One member leaving keeps the other streaming and frees a slot. */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

static int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            char err_[512];                                                      \
            size_t n_ = 0;                                                       \
            moonsec_last_error(err_, sizeof err_, &n_);                          \
            fprintf(stderr, "%s:%d: CHECK(%s) failed (last error: %s)\n",        \
                    __FILE__, __LINE__, #cond, n_ < sizeof err_ ? err_ : "?");   \
            failures++;                                                          \
        }                                                                        \
    } while (0)

#define OK(call) CHECK((call) == MOONSEC_OK)

static void sleep_ms(int ms) {
#ifdef _WIN32
    Sleep(ms);
#else
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
#endif
}

/* Host events: input per session, and the last input owner, are recorded as they pass. */
static moonsec_session *input_from[64];
static int n_inputs = 0;
static moonsec_session *host_owner = NULL;
static int host_owner_events = 0;

static void note_host(const moonsec_event *ev) {
    if (ev->type == MOONSEC_EVENT_INPUT && n_inputs < 64) input_from[n_inputs++] = ev->session;
    if (ev->type == MOONSEC_EVENT_INPUT_OWNER) {
        host_owner = ev->session;
        host_owner_events++;
    }
}

static int wait_host(moonsec_host *h, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_host_poll_event(h, &ev, 50) == 1) {
            note_host(&ev);
            if (ev.type == type) {
                if (out) *out = ev;
                return 1;
            }
        }
    }
    return 0;
}

static void drain_host(moonsec_host *h, uint32_t ms) { wait_host(h, 0xffff, ms, NULL); }

/* Client events: the last INPUT_OWNER per client. */
typedef struct {
    moonsec_client *c;
    moonsec_session *s;
    int owner_events;
    moonsec_session *owner; /* this client's session when it holds input, else NULL */
} client;

static int wait_client(client *cl, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_client_poll_event(cl->c, &ev, 50) == 1) {
            if (ev.type == MOONSEC_EVENT_INPUT_OWNER) {
                cl->owner_events++;
                cl->owner = ev.session;
            }
            if (ev.type == type) {
                if (out) *out = ev;
                return 1;
            }
        }
    }
    return 0;
}

static void new_client(client *cl, const char *name) {
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = "";
    cc.name = name;
    cc.clipboard = MOONSEC_CLIPBOARD_APP;
    memset(cl, 0, sizeof *cl);
    OK(moonsec_client_create(&cc, &cl->c));
}

static void key(moonsec_session *s, uint32_t code) {
    moonsec_input in;
    memset(&in, 0, sizeof in);
    in.kind = MOONSEC_INPUT_KEY;
    in.code = code;
    in.down = 1;
    OK(moonsec_session_send_input(s, &in));
    in.down = 0;
    OK(moonsec_session_send_input(s, &in));
}

static int inputs_from(moonsec_session *s) {
    int n = 0;
    for (int i = 0; i < n_inputs; i++) n += input_from[i] == s;
    return n;
}

int main(void) {
    if (!(moonsec_features() & MOONSEC_FEATURE_MULTI_USER)) {
        fprintf(stderr, "abi multi test: this library has no multi-user sessions\n");
        return 1;
    }
    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = "";
    hc.name = "abi multi host";
    hc.max_clients = 2;
    hc.flags = MOONSEC_HOST_APP_INPUT;
    hc.clipboard = MOONSEC_CLIPBOARD_APP;
    hc.width = 320;
    hc.height = 180;
    hc.relay_mode = MOONSEC_RELAY_DISABLED;
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));
    hc.max_clients = 33;
    moonsec_host *bad = NULL;
    CHECK(moonsec_host_create(&hc, &bad) == MOONSEC_ERR_INVALID);
    if (!h) return 1;
    CHECK(moonsec_host_give_input(h, NULL) == MOONSEC_ERR_STATE); /* nobody yet */
    OK(moonsec_host_listen(h));
    char ticket[1024];
    size_t len = 0;
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));

    client a, b, c;
    new_client(&a, "alice");
    new_client(&b, "bob");
    new_client(&c, "carol");
    moonsec_event ev;

    /* Two members join and both stream the one encode. */
    OK(moonsec_client_connect(a.c, ticket, 10000, &a.s));
    CHECK(wait_client(&a, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));
    CHECK(ev.width == 320 && ev.format.codec == MOONSEC_CODEC_PASSTHROUGH);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_STARTED, 5000, &ev));
    moonsec_session *ha = ev.session;
    OK(moonsec_client_connect(b.c, ticket, 10000, &b.s));
    CHECK(wait_client(&b, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_STARTED, 5000, &ev));
    moonsec_session *hb = ev.session;
    CHECK(ha && hb && ha != hb);

    /* Full: the third is refused as busy. */
    CHECK(moonsec_client_connect(c.c, ticket, 10000, &c.s) == MOONSEC_ERR_REFUSED);
    CHECK(wait_host(h, MOONSEC_EVENT_REFUSED, 5000, &ev));
    CHECK(ev.code == 1);

    /* The first member holds input (owner policy, auto owner); the second's is dropped. */
    wait_client(&a, 0xffff, 1500, NULL);
    wait_client(&b, 0xffff, 500, NULL);
    CHECK(a.owner_events >= 1 && a.owner == a.s);
    CHECK(b.owner_events >= 1 && b.owner == NULL);
    drain_host(h, 200);
    CHECK(host_owner == ha);
    key(a.s, 0x04);
    key(b.s, 0x05);
    sleep_ms(1000);
    drain_host(h, 300);
    CHECK(inputs_from(ha) >= 2);
    CHECK(inputs_from(hb) == 0);

    /* The host's user gives input to the second member. */
    OK(moonsec_session_request_input(b.s));
    CHECK(moonsec_session_request_input(ha) == MOONSEC_ERR_STATE); /* from the client side only */
    OK(moonsec_host_give_input(h, hb));
    CHECK(wait_client(&b, MOONSEC_EVENT_INPUT_OWNER, 5000, &ev));
    CHECK(b.owner == b.s);
    wait_client(&a, 0xffff, 500, NULL);
    CHECK(a.owner == NULL);
    drain_host(h, 200);
    CHECK(host_owner == hb);
    int before = inputs_from(hb);
    key(b.s, 0x06);
    sleep_ms(1000);
    drain_host(h, 300);
    CHECK(inputs_from(hb) >= before + 2);

    /* Clipboard per member. */
    const char *text = "from bob";
    OK(moonsec_session_clipboard_set(b.s, text, strlen(text)));
    CHECK(wait_host(h, MOONSEC_EVENT_CLIPBOARD, 5000, &ev));
    CHECK(ev.session == hb);
    char got[64];
    OK(moonsec_session_clipboard_get(hb, got, sizeof got, &len));
    CHECK(strcmp(got, text) == 0);

    /* The first leaves: the second keeps streaming, and the slot is free again. */
    OK(moonsec_session_close(a.s));
    CHECK(wait_client(&a, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(ev.session == ha && ev.code == MOONSEC_END_PEER_CLOSED);
    moonsec_session_release(ha);
    moonsec_telemetry t0, t1;
    memset(&t0, 0, sizeof t0);
    t0.struct_size = sizeof t0;
    t1 = t0;
    OK(moonsec_session_telemetry(b.s, &t0));
    sleep_ms(1000);
    OK(moonsec_session_telemetry(b.s, &t1));
    CHECK(t1.state == MOONSEC_STATE_STREAMING && t1.frames > t0.frames + 30);
    OK(moonsec_client_connect(c.c, ticket, 10000, &c.s));
    CHECK(wait_client(&c, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));
    OK(moonsec_session_telemetry(hb, &t1));
    printf("multi: second member got %llu frames (host side), rtt %.2f ms; third joined after the first left\n",
           (unsigned long long)t1.frames, t1.rtt_us / 1000.0);

    moonsec_client_destroy(a.c);
    moonsec_client_destroy(b.c);
    moonsec_client_destroy(c.c);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, NULL));
    moonsec_host_destroy(h);

    if (failures) {
        fprintf(stderr, "abi multi test: %d failures\n", failures);
        return 1;
    }
    printf("abi multi test: ok\n");
    return 0;
}
