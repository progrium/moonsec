/* MOONSEC_BACKEND_SYSTEM through the C ABI over iroh on loopback: a host on the OS's
 * screen capture and encoder streams to a client on the OS's decoder and presenter.
 * Input goes to the host app (MOONSEC_HOST_APP_INPUT), so no input device is needed.
 *
 * On Linux it runs under platform/host/linux/headless.sh (Weston on PipeWire, the
 * test's ScreenCast portal backend, which this program serves when MOONSEC_TEST_PORTAL
 * is set); on a desktop it uses the desktop's portal, which may ask first. */
#define _POSIX_C_SOURCE 200809L
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

#ifdef MOONSEC_TEST_PORTAL_BACKEND
#include "testportal.h"
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

static int host_inputs = 0;

static int wait_host(moonsec_host *h, uint32_t type, uint32_t ms, moonsec_event *out) {
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    for (uint32_t waited = 0; waited < ms; waited += 50) {
        while (moonsec_host_poll_event(h, &ev, 50) == 1) {
            if (ev.type == MOONSEC_EVENT_INPUT) host_inputs++;
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

/* The frame callback: count pictures, and that they came with pixels or a GPU image. */
static volatile int frames_seen = 0, frames_with_image = 0;
static volatile uint32_t frame_w = 0, frame_h = 0;

static void on_frame(void *ctx, const moonsec_frame *f) {
    (void)ctx;
    frames_seen++;
    if (f->pixels || f->gpu_texture) frames_with_image++;
    frame_w = f->width;
    frame_h = f->height;
}

static uint32_t env_u32(const char *name) {
    const char *v = getenv(name);
    return v ? (uint32_t)strtoul(v, NULL, 10) : 0;
}

int main(int argc, char **argv) {
    /* "multi": the same on a multi-user host (max_clients 2), the shared capture and
     * encode. One capture per run: headless.sh's Weston does not survive a capture after a
     * finished session, so each mode runs under its own. */
    int multi = argc > 1 && strcmp(argv[1], "multi") == 0;
    uint32_t f = moonsec_features();
    if (!(f & MOONSEC_FEATURE_SYSTEM_BACKEND) || !(f & MOONSEC_FEATURE_IROH)) {
        fprintf(stderr, "abi system test: this library has no system backend or no iroh (build with -Dabi-system=true)\n");
        return 1;
    }
#ifdef MOONSEC_TEST_PORTAL_BACKEND
    if (getenv("MOONSEC_TEST_PORTAL")) {
        uint32_t w = 0, h = 0;
        const char *size = getenv("MOONSEC_HEADLESS_SIZE");
        if (!size || sscanf(size, "%ux%u", &w, &h) != 2 || mlh_testportal_start(env_u32("MOONSEC_HEADLESS_NODE"), w, h, 7) != 0) {
            fprintf(stderr, "abi system test: cannot serve the test portal (run under platform/host/linux/headless.sh)\n");
            return 1;
        }
    }
#endif
    (void)env_u32;

    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.backend = MOONSEC_BACKEND_SYSTEM;
    hc.state_dir = ""; /* key in memory */
    hc.name = "abi system host";
    hc.flags = MOONSEC_HOST_APP_INPUT;
    hc.relay_mode = MOONSEC_RELAY_DISABLED;
    hc.fps = 30;
    hc.bitrate_bps = 4000000;
    hc.max_clients = multi ? 2 : 0;
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));

    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.backend = MOONSEC_BACKEND_SYSTEM;
    cc.state_dir = "";
    cc.name = "abi system client";
    cc.flags = MOONSEC_CLIENT_NO_OS_INPUT;
    cc.on_frame = on_frame;
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));
    if (!h || !c) return 1;

    /* System backends run in real time: not on the loopback. */
    moonsec_loopback_config lc;
    memset(&lc, 0, sizeof lc);
    lc.struct_size = sizeof lc;
    moonsec_loopback *lb = NULL;
    OK(moonsec_loopback_create(&lc, &lb));
    moonsec_session *ls = NULL;
    CHECK(moonsec_host_listen_loopback(h, lb, &ls) == MOONSEC_ERR_UNSUPPORTED);
    moonsec_loopback_destroy(lb);

    OK(moonsec_host_listen(h));
    char ticket[1024];
    size_t len = 0;
    OK(moonsec_host_ticket(h, ticket, sizeof ticket, &len));

    moonsec_session *cs = NULL;
    OK(moonsec_client_connect(c, ticket, 20000, &cs));
    if (!cs) return 1;
    moonsec_event ev;
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_STARTED, 30000, &ev));
    CHECK(ev.format.codec == MOONSEC_CODEC_H264 || ev.format.codec == MOONSEC_CODEC_HEVC || ev.format.codec == MOONSEC_CODEC_AV1);
    uint32_t w = ev.width, hgt = ev.height, codec = ev.format.codec;
    CHECK(w > 0 && hgt > 0);
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_STARTED, 10000, &ev));

    moonsec_input key;
    memset(&key, 0, sizeof key);
    key.kind = MOONSEC_INPUT_KEY;
    key.code = 0x04; /* A */
    key.down = 1;
    OK(moonsec_session_send_input(cs, &key));
    key.down = 0;
    OK(moonsec_session_send_input(cs, &key));
    sleep_ms(3000);
    wait_host(h, 0xffff, 500, NULL); /* drain */
    CHECK(host_inputs >= 2);

    moonsec_telemetry t;
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    OK(moonsec_session_telemetry(cs, &t));
    CHECK(t.state == MOONSEC_STATE_STREAMING);
    CHECK(t.frames > 20);
    CHECK(t.stages[MOONSEC_STAGE_DECODE].count > 0);
    CHECK(frames_seen > 20 && frames_with_image == frames_seen);
    CHECK(frame_w == w && frame_h == hgt);
    printf("system%s: %ux%u codec %u, client presented %llu frames (lost %llu, freezes %llu), decode p50 %.2f ms, glass-to-glass p50 %.2f ms p99 %.2f ms\n",
           multi ? " (multi-user host)" : "", w, hgt, codec, (unsigned long long)t.frames, (unsigned long long)t.frames_lost, (unsigned long long)t.freezes,
           t.stages[MOONSEC_STAGE_DECODE].p50_us / 1000.0, t.stages[MOONSEC_STAGE_TOTAL].p50_us / 1000.0,
           t.stages[MOONSEC_STAGE_TOTAL].p99_us / 1000.0);

    OK(moonsec_session_close(cs));
    CHECK(wait_client(c, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    CHECK(wait_host(h, MOONSEC_EVENT_SESSION_ENDED, 5000, &ev));
    moonsec_session_release(cs);
    moonsec_client_destroy(c);
    moonsec_host_destroy(h);

    if (failures) {
        fprintf(stderr, "abi system test: %d failures\n", failures);
        return 1;
    }
    printf("abi system test%s: ok\n", multi ? " (multi-user host)" : "");
    return 0;
}
