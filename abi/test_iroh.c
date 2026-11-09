/* The C ABI over iroh on loopback, wall clock, the library's own threads: a host that
 * admits only paired clients turns an unpaired client away; pairing with a wrong PIN
 * fails and with the QR ticket succeeds; the paired client connects, streams, sends
 * input and clipboard text, and closes; both devices keep their keys and lists in their
 * state directories, so a second run of each pairs nothing and still connects. */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <process.h>
#include <windows.h>
#define getpid _getpid
#else
#include <unistd.h>
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

/* Wait up to `ms` for an event of `type` (others are skipped, and counted in `seen`). */
static int seen[16];

static int wait_host(moonsec_host *h, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_host_poll_event(h, &ev, 50) == 1) {
            if (ev.type < 16) seen[ev.type]++;
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
            if (ev.type == type) {
                if (out) *out = ev;
                return 1;
            }
        }
    }
    return 0;
}

static moonsec_host *new_host(const char *dir) {
    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = dir;
    hc.name = "abi test host";
    hc.flags = MOONSEC_HOST_APP_INPUT; /* pairing required: the default */
    hc.clipboard = MOONSEC_CLIPBOARD_APP;
    hc.width = 320;
    hc.height = 180;
    hc.relay_mode = MOONSEC_RELAY_DISABLED; /* loopback only */
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));
    return h;
}

static moonsec_client *new_client(const char *dir, uint32_t flags) {
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = dir;
    cc.name = "abi test client";
    cc.flags = flags;
    cc.clipboard = MOONSEC_CLIPBOARD_APP;
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));
    return c;
}

int main(void) {
    if (!(moonsec_features() & MOONSEC_FEATURE_IROH)) {
        fprintf(stderr, "abi iroh test: this library has no iroh transport\n");
        return 1;
    }
    char host_dir[512], client_dir[512];
    const char *tmp = getenv("TMPDIR");
#ifdef _WIN32
    if (!tmp) tmp = getenv("TEMP");
#endif
    if (!tmp) tmp = "/tmp";
    snprintf(host_dir, sizeof host_dir, "%s/moonsec-abi-host-%d-%ld", tmp, (int)getpid(), (long)time(NULL));
    snprintf(client_dir, sizeof client_dir, "%s/moonsec-abi-client-%d-%ld", tmp, (int)getpid(), (long)time(NULL));

    moonsec_host *h = new_host(host_dir);
    /* Insecure on the client side only, so it dials the unpaired host and the host's
     * refusal is what gets tested. */
    moonsec_client *c = new_client(client_dir, MOONSEC_CLIENT_INSECURE_NO_PAIRING);
    if (!h || !c) return 1;
    char host_id[80], client_id[80];
    size_t len = 0;
    OK(moonsec_host_id(h, host_id, sizeof host_id, &len));
    OK(moonsec_client_id(c, client_id, sizeof client_id, &len));
    CHECK(moonsec_host_ticket(h, host_id, sizeof host_id, &len) == MOONSEC_ERR_STATE); /* not listening */
    OK(moonsec_host_id(h, host_id, sizeof host_id, &len));

    OK(moonsec_host_listen(h));
    CHECK(moonsec_host_listen(h) == MOONSEC_ERR_STATE);
    char ticket[1024];
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));
    CHECK(strncmp(ticket, "MOONSEC", 7) == 0);

    /* Not paired yet: the host turns the client away. */
    moonsec_session *cs = NULL;
    CHECK(moonsec_client_connect(c, ticket, 10000, &cs) == MOONSEC_ERR_REFUSED);
    CHECK(cs == NULL);
    moonsec_event ev;
    CHECK(wait_host(h, MOONSEC_EVENT_REFUSED, 5000, &ev));
    CHECK(strcmp(ev.peer_id, client_id) == 0);

    /* Pairing: a wrong PIN fails, the QR ticket pairs. */
    moonsec_pair_config pc;
    memset(&pc, 0, sizeof pc);
    pc.struct_size = sizeof pc;
    pc.seconds = 60;
    moonsec_pair_info pi;
    memset(&pi, 0, sizeof pi);
    pi.struct_size = sizeof pi;
    OK(moonsec_host_pair_begin(h, &pc, &pi));
    CHECK(strlen(pi.pin) == 6);
    CHECK(strncmp(pi.qr_ticket, "MOONSEC", 7) == 0 && strncmp(pi.addr_ticket, "MOONSEC", 7) == 0);
    char wrong[8];
    strcpy(wrong, pi.pin);
    wrong[0] = wrong[0] == '0' ? '1' : '0';
    CHECK(moonsec_client_pair(c, pi.addr_ticket, wrong) == MOONSEC_ERR_REFUSED);
    CHECK(wait_host(h, MOONSEC_EVENT_PAIR_FAILED, 5000, &ev));
    CHECK(ev.code == MOONSEC_PAIR_FAIL_BAD_PROOF);
    CHECK(moonsec_client_pair(c, pi.addr_ticket, NULL) == MOONSEC_ERR_INVALID); /* no secret, no PIN */
    OK(moonsec_client_pair(c, pi.qr_ticket, NULL));
    CHECK(wait_host(h, MOONSEC_EVENT_PAIRED, 5000, &ev));
    CHECK(strcmp(ev.peer_id, client_id) == 0);
    CHECK(strcmp(ev.peer_name, "abi test client") == 0);
    CHECK(wait_host(h, MOONSEC_EVENT_PAIR_CLOSED, 5000, &ev)); /* one pairing used it up */
    CHECK(ev.code == 1);
    OK(moonsec_host_pair_end(h));

    /* Permissions: only for paired clients, only known bits. */
    CHECK(moonsec_host_set_permissions(h, client_id, MOONSEC_PERM_INPUT) == MOONSEC_OK);
    CHECK(moonsec_host_set_permissions(h, client_id, 0x80) == MOONSEC_ERR_INVALID);
    CHECK(moonsec_host_set_permissions(h, "not an id", MOONSEC_PERM_ALL) == MOONSEC_ERR_INVALID);
    CHECK(moonsec_host_set_permissions(h, host_id, MOONSEC_PERM_ALL) == MOONSEC_ERR_REFUSED);
    CHECK(moonsec_host_set_permissions(h, client_id, MOONSEC_PERM_ALL) == MOONSEC_OK);

    /* Paired: connect and stream. */
    OK(moonsec_client_connect(c, ticket, 10000, &cs));
    CHECK(cs != NULL);
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));
    CHECK(ev.session == cs && ev.width == 320 && ev.format.codec == MOONSEC_CODEC_PASSTHROUGH);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_STARTED, 5000, &ev));
    moonsec_session *hs = ev.session;
    CHECK(hs != NULL);
    moonsec_input key;
    memset(&key, 0, sizeof key);
    key.kind = MOONSEC_INPUT_KEY;
    key.code = 0x2c; /* space */
    key.down = 1;
    OK(moonsec_session_send_input(cs, &key));
    key.down = 0;
    OK(moonsec_session_send_input(cs, &key));
    const char *text = "over iroh";
    OK(moonsec_session_clipboard_set(cs, text, strlen(text)));
    CHECK(wait_host(h, MOONSEC_EVENT_CLIPBOARD, 5000, &ev));
    char got[64];
    OK(moonsec_session_clipboard_get(hs, got, sizeof got, &len));
    CHECK(strcmp(got, text) == 0);
    sleep_ms(1500);
    CHECK(seen[MOONSEC_EVENT_INPUT] >= 2);

    moonsec_telemetry t;
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    OK(moonsec_session_telemetry(cs, &t));
    CHECK(t.state == MOONSEC_STATE_STREAMING);
    CHECK(t.frames > 60);
    CHECK(t.rtt_us > 0);
    CHECK(t.stages[MOONSEC_STAGE_TOTAL].count > 0);
    printf("iroh: client presented %llu frames (lost %llu, freezes %llu), rtt %.2f ms, glass-to-glass p50 %.2f ms p99 %.2f ms\n",
           (unsigned long long)t.frames, (unsigned long long)t.frames_lost, (unsigned long long)t.freezes, t.rtt_us / 1000.0,
           t.stages[MOONSEC_STAGE_TOTAL].p50_us / 1000.0, t.stages[MOONSEC_STAGE_TOTAL].p99_us / 1000.0);

    OK(moonsec_session_close(cs));
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(ev.code == MOONSEC_END_CLOSED);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(ev.code == MOONSEC_END_PEER_CLOSED);
    moonsec_session_release(cs);
    moonsec_client_destroy(c);
    moonsec_host_destroy(h);

    /* Both state directories kept the keys and the pairing: same IDs, connects at once. */
    h = new_host(host_dir);
    c = new_client(client_dir, 0);
    char id2[80];
    OK(moonsec_host_id(h, id2, sizeof id2, &len));
    CHECK(strcmp(id2, host_id) == 0);
    OK(moonsec_client_id(c, id2, sizeof id2, &len));
    CHECK(strcmp(id2, client_id) == 0);
    OK(moonsec_host_listen(h));
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));
    OK(moonsec_client_connect(c, ticket, 10000, &cs));
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_STARTED, 10000, NULL));
    /* Destroying the client closes its session; the host hears the bye. */
    moonsec_client_destroy(c);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(ev.code == MOONSEC_END_PEER_CLOSED);
    moonsec_host_destroy(h);

    /* A client refuses a host it never paired with. */
    char other_dir[600];
    snprintf(other_dir, sizeof other_dir, "%s-other", host_dir);
    h = new_host(other_dir);
    c = new_client(client_dir, 0);
    OK(moonsec_host_listen(h));
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));
    CHECK(moonsec_client_connect(c, ticket, 10000, &cs) == MOONSEC_ERR_REFUSED);
    moonsec_client_destroy(c);
    moonsec_host_destroy(h);

    if (failures) {
        fprintf(stderr, "abi iroh test: %d failures (state in %s and %s)\n", failures, host_dir, client_dir);
        return 1;
    }
    printf("abi iroh test: ok\n");
    return 0;
}
