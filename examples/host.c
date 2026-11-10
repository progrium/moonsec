/* A small moonsec host on the public C API.
 *
 *   moonsec-example-host [--system] [--relay | --relay-url URL [--relay-ca PEM-FILE]] [--pair]
 *                        [--seconds N] [--state-dir DIR] [--web BASE]
 *
 * Listens over iroh, prints the ticket clients connect with, and with --pair opens a
 * pairing window and prints the QR ticket and PIN; then only paired clients get in.
 * Prints events as they come and the session's telemetry every two seconds. It streams
 * the synthetic test pattern (MOONSEC_BACKEND_SYNTHETIC), or with --system the screen,
 * through the OS's capture and encoder (MOONSEC_BACKEND_SYSTEM, in libraries built with
 * it: MOONSEC_FEATURE_SYSTEM_BACKEND).
 *
 * --relay-url uses one self-hosted relay instead of n0's (MOONSEC_RELAY_CUSTOM), such as
 * `iroh-relay --dev` on http://127.0.0.1:3340, which browsers reach too: then the tickets
 * are also printed as web client links under --web (default http://127.0.0.1:8790, what
 * `npm run local` in web/ serves; see web/README.md, "A native host in the browser"). */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    static char buf[64 * 1024];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    return buf;
}

static void web_link(const char *web, const char *what, const char *ticket, const char *relay) {
    printf("  %s: %s/client.html?ticket=%s&relay=%s\n", what, web, ticket, relay);
}

static void die(const char *what, moonsec_status st) {
    char err[512];
    size_t len = 0;
    moonsec_last_error(err, sizeof err, &len);
    fprintf(stderr, "%s: %s: %s\n", what, moonsec_status_string(st), len < sizeof err ? err : "");
    exit(1);
}

static const char *event_name(uint32_t type) {
    switch (type) {
    case MOONSEC_EVENT_SESSION_STARTED: return "session started";
    case MOONSEC_EVENT_SESSION_ENDED: return "session ended";
    case MOONSEC_EVENT_FORMAT_CHANGED: return "format changed";
    case MOONSEC_EVENT_INPUT: return "input";
    case MOONSEC_EVENT_CLIPBOARD: return "clipboard";
    case MOONSEC_EVENT_PATH_CHANGED: return "path changed";
    case MOONSEC_EVENT_PAIRED: return "paired";
    case MOONSEC_EVENT_PAIR_FAILED: return "pairing failed";
    case MOONSEC_EVENT_PAIR_CLOSED: return "pairing window closed";
    case MOONSEC_EVENT_REFUSED: return "refused an unpaired client";
    default: return "event";
    }
}

int main(int argc, char **argv) {
    int relay = 0, pair = 0, sys = 0, seconds = 60;
    const char *state_dir = NULL; /* the per-user default */
    const char *relay_url = NULL, *relay_ca = NULL, *web = "http://127.0.0.1:8790";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--relay") == 0) relay = 1;
        else if (strcmp(argv[i], "--system") == 0) sys = 1;
        else if (strcmp(argv[i], "--pair") == 0) pair = 1;
        else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], "--state-dir") == 0 && i + 1 < argc) state_dir = argv[++i];
        else if (strcmp(argv[i], "--relay-url") == 0 && i + 1 < argc) relay_url = argv[++i];
        else if (strcmp(argv[i], "--relay-ca") == 0 && i + 1 < argc) relay_ca = read_file(argv[++i]);
        else if (strcmp(argv[i], "--web") == 0 && i + 1 < argc) web = argv[++i];
        else {
            fprintf(stderr, "usage: %s [--system] [--relay | --relay-url URL [--relay-ca PEM-FILE]] [--pair] [--seconds N] [--state-dir DIR] [--web BASE]\n", argv[0]);
            return 2;
        }
    }
    printf("moonsec %s\n", moonsec_version_string());

    moonsec_host_config cfg;
    memset(&cfg, 0, sizeof cfg); /* zero is the default for every field */
    cfg.struct_size = sizeof cfg;
    cfg.backend = sys ? MOONSEC_BACKEND_SYSTEM : MOONSEC_BACKEND_SYNTHETIC;
    cfg.state_dir = state_dir;
    cfg.relay_mode = relay_url ? MOONSEC_RELAY_CUSTOM : relay ? MOONSEC_RELAY_DEFAULT : MOONSEC_RELAY_DISABLED;
    cfg.relay_url = relay_url;
    cfg.relay_ca_pem = relay_ca;
    cfg.flags = MOONSEC_HOST_RATE_CONTROL | MOONSEC_HOST_LOSS_POLICY;
    moonsec_host *host = NULL;
    moonsec_status st = moonsec_host_create(&cfg, &host);
    if (st != MOONSEC_OK) die("create", st);
    if ((st = moonsec_host_listen(host)) != MOONSEC_OK) die("listen", st);

    char id[80], ticket[1024];
    size_t len = 0;
    moonsec_host_id(host, id, sizeof id, &len);
    if ((st = moonsec_host_ticket(host, ticket, sizeof ticket, &len)) != MOONSEC_OK) die("ticket", st);
    printf("host %.16s...\nconnect with:\n  moonsec-example-client connect %s\n", id, ticket);
    if (relay_url) web_link(web, "in a browser (once paired)", ticket, relay_url);
    if (pair) {
        moonsec_pair_config pc = {sizeof pc, 120, 1, MOONSEC_PAIR_QR_AND_PIN};
        moonsec_pair_info pi;
        memset(&pi, 0, sizeof pi);
        pi.struct_size = sizeof pi;
        if ((st = moonsec_host_pair_begin(host, &pc, &pi)) != MOONSEC_OK) die("pair", st);
        printf("pair within %u s:\n  moonsec-example-client pair %s\nor with the PIN %s:\n  moonsec-example-client pair %s %s\n",
               pi.seconds, pi.qr_ticket, pi.pin, pi.addr_ticket, pi.pin);
        if (relay_url) web_link(web, "in a browser (pairs, then connects)", pi.qr_ticket, relay_url);
    }
    fflush(stdout);

    moonsec_session *session = NULL;
    time_t end = time(NULL) + seconds, next_report = time(NULL) + 2;
    while (time(NULL) < end) {
        moonsec_event ev;
        memset(&ev, 0, sizeof ev);
        ev.struct_size = sizeof ev;
        while (moonsec_host_poll_event(host, &ev, 100) == 1) {
            printf("%s", event_name(ev.type));
            if (ev.type == MOONSEC_EVENT_SESSION_STARTED) {
                session = ev.session;
                printf(": codec %u, %ux%u", ev.format.codec, ev.width, ev.height);
            } else if (ev.type == MOONSEC_EVENT_SESSION_ENDED) {
                printf(" (reason %d)", ev.code);
                moonsec_session_release(ev.session);
                if (ev.session == session) session = NULL;
            } else if (ev.type == MOONSEC_EVENT_PAIRED) {
                printf(": %s (%.16s...)", ev.peer_name, ev.peer_id);
            } else if (ev.type == MOONSEC_EVENT_INPUT) {
                printf(": kind %u code %u down %d", ev.input.kind, ev.input.code, ev.input.down);
            }
            printf("\n");
        }
        if (session && time(NULL) >= next_report) {
            moonsec_telemetry t;
            memset(&t, 0, sizeof t);
            t.struct_size = sizeof t;
            if (moonsec_session_telemetry(session, &t) == MOONSEC_OK)
                printf("  sent %llu frames at %llu kbit/s, rtt %.1f ms, encode p50 %.2f ms%s\n",
                       (unsigned long long)t.frames, (unsigned long long)(t.bitrate_bps / 1000), t.rtt_us / 1000.0,
                       t.stages[MOONSEC_STAGE_ENCODE].p50_us / 1000.0, (t.flags & MOONSEC_TELEMETRY_RELAYED) ? ", relayed" : "");
            next_report = time(NULL) + 2;
        }
        fflush(stdout);
    }
    moonsec_host_destroy(host); /* tells the client goodbye */
    return 0;
}
