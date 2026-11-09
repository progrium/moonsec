/* Reconnect after a dropped connection, through the C ABI over iroh on loopback: the
 * connection under a session drops (as a network failure would, through the library's
 * test hook), the client dials the host again and goes through admission, and the host
 * hands the new connection to the same session. Neither side sees the session end; it
 * streams on and counts the reconnect. Dropped from either end, on a one-client host and
 * on a multi-user host. */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

/* Not part of the ABI: drops the session's current iroh connection. */
moonsec_status moonsec__test_drop_connection(moonsec_session *session);

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

/* Events of each kind seen while draining. */
static int host_ended = 0, client_ended = 0;

static int wait_host(moonsec_host *h, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_host_poll_event(h, &ev, 50) == 1) {
            if (ev.type == MOONSEC_EVENT_SESSION_ENDED) host_ended++;
            if (ev.type == type) {
                if (out) *out = ev;
                return 1;
            }
        }
    }
    return 0;
}

static int wait_client(moonsec_client *c, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_client_poll_event(c, &ev, 50) == 1) {
            if (ev.type == MOONSEC_EVENT_SESSION_ENDED) client_ended++;
            if (ev.type == type) {
                if (out) *out = ev;
                return 1;
            }
        }
    }
    return 0;
}

static moonsec_telemetry telemetry(moonsec_session *s) {
    moonsec_telemetry t;
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    OK(moonsec_session_telemetry(s, &t));
    return t;
}

/* Drops `victim`'s connection and checks that the client's session `cs` reconnects and
 * streams on, and that neither side's session ended. */
static void drop_and_recover(const char *what, moonsec_host *h, moonsec_client *c, moonsec_session *cs,
                             moonsec_session *hs, moonsec_session *victim) {
    moonsec_telemetry before = telemetry(cs), host_before = telemetry(hs);
    OK(moonsec__test_drop_connection(victim));
    uint64_t reconnects = 0;
    for (int i = 0; i < 100 && reconnects <= before.reconnects; i++) {
        wait_client(c, 0xffff, 50, NULL);
        wait_host(h, 0xffff, 50, NULL);
        reconnects = telemetry(cs).reconnects;
    }
    CHECK(reconnects > before.reconnects);
    moonsec_telemetry mid = telemetry(cs);
    sleep_ms(1000);
    wait_client(c, 0xffff, 100, NULL);
    wait_host(h, 0xffff, 100, NULL);
    moonsec_telemetry after = telemetry(cs);
    CHECK(after.state == MOONSEC_STATE_STREAMING && after.frames > mid.frames + 20);
    CHECK(moonsec_session_state(hs) == MOONSEC_STATE_STREAMING);
    CHECK(telemetry(hs).reconnects > host_before.reconnects); /* the same host session */
    CHECK(host_ended == 0 && client_ended == 0);
    printf("reconnect (%s): client reconnects %llu -> %llu, %llu frames in the second after\n", what,
           (unsigned long long)before.reconnects, (unsigned long long)after.reconnects,
           (unsigned long long)(after.frames - mid.frames));
}

static void run(uint32_t max_clients) {
    const char *kind = max_clients > 1 ? "multi-user host" : "one-client host";
    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = "";
    hc.name = "abi reconnect host";
    hc.flags = MOONSEC_HOST_APP_INPUT | MOONSEC_HOST_INSECURE_NO_PAIRING; /* no pairing in this test */
    hc.max_clients = max_clients;
    hc.width = 320;
    hc.height = 180;
    hc.relay_mode = MOONSEC_RELAY_DISABLED;
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = "";
    cc.name = "abi reconnect client";
    cc.flags = MOONSEC_CLIENT_INSECURE_NO_PAIRING;
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));
    if (!h || !c) exit(1);
    OK(moonsec_host_listen(h));
    char ticket[1024];
    size_t len = 0;
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));

    moonsec_session *cs = NULL;
    OK(moonsec_client_connect(c, ticket, 10000, &cs));
    if (!cs) exit(1);
    moonsec_event ev;
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_STARTED, 5000, &ev));
    moonsec_session *hs = ev.session;
    sleep_ms(500);
    host_ended = client_ended = 0;

    char what[64];
    snprintf(what, sizeof what, "%s, client drops", kind);
    drop_and_recover(what, h, c, cs, hs, cs);
    snprintf(what, sizeof what, "%s, host drops", kind);
    drop_and_recover(what, h, c, cs, hs, hs);

    /* Input still reaches the host over the new connection. */
    moonsec_input in;
    memset(&in, 0, sizeof in);
    in.kind = MOONSEC_INPUT_KEY;
    in.code = 0x04;
    in.down = 1;
    OK(moonsec_session_send_input(cs, &in));
    CHECK(wait_host(h, MOONSEC_EVENT_INPUT, 5000, &ev));

    /* A clean close still ends both sides at once. */
    OK(moonsec_session_close(cs));
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(ev.session == hs && ev.code == MOONSEC_END_PEER_CLOSED);
    moonsec_session_release(cs);
    moonsec_session_release(hs);
    moonsec_client_destroy(c);
    moonsec_host_destroy(h);
}

int main(void) {
    if (!(moonsec_features() & MOONSEC_FEATURE_IROH)) {
        fprintf(stderr, "abi reconnect test: this library has no iroh\n");
        return 1;
    }
    run(1);
    run(2);
    if (failures) {
        fprintf(stderr, "abi reconnect test: %d failures\n", failures);
        return 1;
    }
    printf("abi reconnect test: ok\n");
    return 0;
}
