/* A small moonsec client on the public C API.
 *
 *   moonsec-example-client pair TICKET [PIN]       pair with a host (QR ticket, or address ticket + PIN)
 *   moonsec-example-client connect TICKET [--system] [--seconds N] [--relay] [--state-dir DIR]
 *
 * With --system the stream is decoded and shown in a window by the OS's backend
 * (MOONSEC_BACKEND_SYSTEM), and the keyboard and mouse go to the host.
 *
 * Connects to a paired host, counts the pictures the frame callback sees, sends a key
 * press every second, and prints the stream's telemetry: frames, loss, freezes, and the
 * per-stage latency (network, decode, present, glass to glass). */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void die(const char *what, moonsec_status st) {
    char err[512];
    size_t len = 0;
    moonsec_last_error(err, sizeof err, &len);
    fprintf(stderr, "%s: %s: %s\n", what, moonsec_status_string(st), len < sizeof err ? err : "");
    exit(1);
}

/* Runs on the library's present thread: keep it short, and don't call moonsec here. */
static volatile unsigned long frames_seen = 0;
static void on_frame(void *ctx, const moonsec_frame *f) {
    (void)ctx;
    (void)f; /* f->pixels (BGRA) or f->gpu_texture: draw it into your own window here */
    frames_seen++;
}

static void stage(const char *name, const moonsec_stage_stats *s) {
    if (s->count) printf("  %-8s p50 %6.2f ms  p95 %6.2f ms  p99 %6.2f ms  (%u frames)\n", name, s->p50_us / 1000.0, s->p95_us / 1000.0, s->p99_us / 1000.0, s->count);
}

int main(int argc, char **argv) {
    if (argc < 3 || (strcmp(argv[1], "pair") != 0 && strcmp(argv[1], "connect") != 0)) {
        fprintf(stderr, "usage: %s pair TICKET [PIN]\n       %s connect TICKET [--system] [--seconds N] [--relay] [--state-dir DIR]\n", argv[0], argv[0]);
        return 2;
    }
    int relay = 0, sys = 0, seconds = 10;
    const char *state_dir = NULL, *pin = NULL;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--relay") == 0) relay = 1;
        else if (strcmp(argv[i], "--system") == 0) sys = 1;
        else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], "--state-dir") == 0 && i + 1 < argc) state_dir = argv[++i];
        else pin = argv[i];
    }

    moonsec_client_config cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.struct_size = sizeof cfg;
    cfg.state_dir = state_dir;
    cfg.relay_mode = relay ? MOONSEC_RELAY_DEFAULT : MOONSEC_RELAY_DISABLED;
    cfg.backend = sys ? MOONSEC_BACKEND_SYSTEM : MOONSEC_BACKEND_SYNTHETIC;
    cfg.flags = MOONSEC_CLIENT_REQUIRE_PAIRED | (sys ? 0 : MOONSEC_CLIENT_NO_OS_INPUT);
    cfg.on_frame = on_frame;
    moonsec_client *client = NULL;
    moonsec_status st = moonsec_client_create(&cfg, &client);
    if (st != MOONSEC_OK) die("create", st);

    if (strcmp(argv[1], "pair") == 0) {
        if ((st = moonsec_client_pair(client, argv[2], pin)) != MOONSEC_OK) die("pair", st);
        printf("paired\n");
        moonsec_client_destroy(client);
        return 0;
    }

    moonsec_session *session = NULL;
    if ((st = moonsec_client_connect(client, argv[2], 30000, &session)) != MOONSEC_OK) die("connect", st);
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    time_t end = time(NULL) + seconds + 5, next_key = 0;
    int streaming = 0, ended = 0;
    while (!ended && time(NULL) < end) {
        while (moonsec_client_poll_event(client, &ev, 100) == 1) {
            if (ev.type == MOONSEC_EVENT_SESSION_STARTED) {
                printf("streaming: codec %u, %ux%u, %u-bit\n", ev.format.codec, ev.width, ev.height, ev.format.bit_depth);
                streaming = 1;
                end = time(NULL) + seconds;
            } else if (ev.type == MOONSEC_EVENT_SESSION_ENDED) {
                printf("session ended (reason %d)\n", ev.code);
                ended = 1;
            } else if (ev.type == MOONSEC_EVENT_PATH_CHANGED) {
                printf("path: %s\n", ev.code ? "relayed" : "direct");
            }
        }
        if (!sys && streaming && time(NULL) >= next_key) { /* --system: the real keyboard instead */
            moonsec_input key;
            memset(&key, 0, sizeof key);
            key.kind = MOONSEC_INPUT_KEY;
            key.code = 0x04; /* HID 'a' */
            key.down = 1;
            moonsec_session_send_input(session, &key);
            key.down = 0;
            moonsec_session_send_input(session, &key);
            next_key = time(NULL) + 1;
        }
    }

    moonsec_telemetry t;
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    if (moonsec_session_telemetry(session, &t) == MOONSEC_OK) {
        printf("presented %llu frames (callback saw %lu), lost %llu, freezes %llu, rtt %.2f ms\n", (unsigned long long)t.frames, frames_seen,
               (unsigned long long)t.frames_lost, (unsigned long long)t.freezes, t.rtt_us / 1000.0);
        stage("network", &t.stages[MOONSEC_STAGE_NETWORK]);
        stage("decode", &t.stages[MOONSEC_STAGE_DECODE]);
        stage("present", &t.stages[MOONSEC_STAGE_PRESENT]);
        stage("total", &t.stages[MOONSEC_STAGE_TOTAL]);
    }
    moonsec_session_close(session);
    moonsec_client_destroy(client); /* waits for the bye to go out */
    return streaming ? 0 : 1;
}
