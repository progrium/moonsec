/* The C ABI end to end over the in-process sim (moonsec_loopback), in virtual time:
 * a host and a client on the synthetic backend stream for a few seconds; the test checks
 * events, frames through the frame callback, input (keys, buttons, scroll, motion,
 * gamepads) from the client's app to the host's app, clipboard both ways, telemetry,
 * the struct_size rules, error codes, and a clean close on each side. */
#include <moonsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

typedef struct {
    int frames;
    int with_pixels;
    uint32_t last_id;
    uint32_t width, height;
} frame_counter;

static void on_frame(void *ctx, const moonsec_frame *f) {
    frame_counter *fc = (frame_counter *)ctx;
    fc->frames++;
    if (f->pixels != NULL && f->stride >= f->width * 4) fc->with_pixels++;
    fc->last_id = f->frame_id;
    fc->width = f->width;
    fc->height = f->height;
}

static int notified = 0;
static void on_notify(void *ctx) {
    (void)ctx;
    notified++;
}

/* Drains `n` events of any type into `out`; returns how many it got. */
static int drain_host(moonsec_host *h, moonsec_event *out, int cap) {
    int n = 0;
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    while (moonsec_host_poll_event(h, &ev, 0) == 1) {
        if (n < cap) out[n] = ev;
        n++;
    }
    return n;
}

static int drain_client(moonsec_client *c, moonsec_event *out, int cap) {
    int n = 0;
    moonsec_event ev;
    memset(&ev, 0, sizeof ev);
    ev.struct_size = sizeof ev;
    while (moonsec_client_poll_event(c, &ev, 0) == 1) {
        if (n < cap) out[n] = ev;
        n++;
    }
    return n;
}

static int count_type(const moonsec_event *evs, int n, uint32_t type) {
    int k = 0;
    for (int i = 0; i < n; i++)
        if (evs[i].type == type) k++;
    return k;
}

static const moonsec_event *find_type(const moonsec_event *evs, int n, uint32_t type) {
    for (int i = 0; i < n; i++)
        if (evs[i].type == type) return &evs[i];
    return NULL;
}

static void test_basics(void) {
    CHECK(moonsec_version() == MOONSEC_ABI_VERSION);
    CHECK((moonsec_version() >> 16) == MOONSEC_ABI_MAJOR);
    CHECK(strncmp(moonsec_version_string(), "1.0.0", 5) == 0);
    CHECK(moonsec_features() & MOONSEC_FEATURE_LOOPBACK);
    CHECK(strcmp(moonsec_status_string(MOONSEC_ERR_TIMEOUT), "MOONSEC_ERR_TIMEOUT") == 0);
    CHECK(strcmp(moonsec_status_string(12345), "MOONSEC_ERR_UNKNOWN") == 0);

    /* NULLs and bad sizes are errors, not crashes. */
    moonsec_host *h = (moonsec_host *)1;
    CHECK(moonsec_host_create(NULL, &h) == MOONSEC_ERR_INVALID);
    CHECK(h == NULL);
    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = 8; /* older than 1.0: refused */
    CHECK(moonsec_host_create(&hc, &h) == MOONSEC_ERR_INVALID);
    char err[256];
    size_t len = 0;
    OK(moonsec_last_error(err, sizeof err, &len));
    CHECK(len > 0 && strlen(err) == len);
    /* Size query: no buffer gives the length. */
    size_t need = 0;
    CHECK(moonsec_last_error(NULL, 0, &need) == MOONSEC_ERR_BUFFER_TOO_SMALL);
    CHECK(need == len);
    CHECK(moonsec_last_error(err, len, &need) == MOONSEC_ERR_BUFFER_TOO_SMALL); /* no room for the NUL */

    moonsec_host_destroy(NULL);
    moonsec_client_destroy(NULL);
    moonsec_session_release(NULL);
    CHECK(moonsec_session_state(NULL) == MOONSEC_ERR_INVALID);
    CHECK(moonsec_session_close(NULL) == MOONSEC_ERR_INVALID);
    CHECK(moonsec_loopback_advance(NULL, 1000) == MOONSEC_ERR_INVALID);
    /* A client handle is not a host handle. */
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = "";
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));
    CHECK(moonsec_host_listen((moonsec_host *)c) == MOONSEC_ERR_INVALID);
    char id[80];
    OK(moonsec_client_id(c, id, sizeof id, &len));
    CHECK(len == 64);
    moonsec_client_destroy(c);

    /* What this build does not do. */
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = "";
    hc.backend = MOONSEC_BACKEND_SYSTEM;
    CHECK(moonsec_host_create(&hc, &h) == MOONSEC_ERR_UNSUPPORTED);
    hc.backend = MOONSEC_BACKEND_SYNTHETIC;
    hc.max_clients = 2; /* multi-user hosts run over iroh only */
    if (moonsec_features() & MOONSEC_FEATURE_MULTI_USER) {
        OK(moonsec_host_create(&hc, &h));
        moonsec_host_destroy(h);
    } else
        CHECK(moonsec_host_create(&hc, &h) == MOONSEC_ERR_UNSUPPORTED);
    hc.max_clients = 0;
    hc.relay_mode = MOONSEC_RELAY_CUSTOM; /* without relay_url */
    CHECK(moonsec_host_create(&hc, &h) == MOONSEC_ERR_INVALID);
    hc.relay_mode = MOONSEC_RELAY_DISABLED;
    OK(moonsec_host_create(&hc, &h));
    if (!(moonsec_features() & MOONSEC_FEATURE_IROH)) CHECK(moonsec_host_listen(h) == MOONSEC_ERR_UNSUPPORTED);
    CHECK(moonsec_host_give_input(h, NULL) == MOONSEC_ERR_UNSUPPORTED);
    moonsec_host_destroy(h);

    /* Displays: the synthetic backend's one display, at the configured size; the count
     * alone with cap 0. */
    CHECK(moonsec_features() & MOONSEC_FEATURE_DISPLAYS);
    hc.width = 320;
    hc.height = 180;
    OK(moonsec_host_create(&hc, &h));
    size_t nd = 99;
    OK(moonsec_host_displays(h, NULL, 0, &nd));
    CHECK(nd == 1);
    moonsec_display_info di[4];
    memset(di, 0xff, sizeof di);
    OK(moonsec_host_displays(h, di, 4, &nd));
    CHECK(nd == 1 && di[0].index == 0 && di[0].width == 320 && di[0].height == 180);
    CHECK(di[0].primary == 1 && di[0].refresh_mhz == 60000 && di[0].hdr == 0 && strcmp(di[0].name, "Synthetic 1") == 0);
    CHECK(moonsec_host_displays(h, NULL, 4, &nd) == MOONSEC_ERR_INVALID);
    moonsec_host_destroy(h);
}

static void test_stream(uint32_t profile) {
    moonsec_loopback_config lc;
    memset(&lc, 0, sizeof lc);
    lc.struct_size = sizeof lc;
    lc.profile = profile;
    lc.seed = 7;
    moonsec_loopback *lb = NULL;
    OK(moonsec_loopback_create(&lc, &lb));

    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = ""; /* a fresh key in memory */
    hc.name = "test host";
    hc.flags = MOONSEC_HOST_APP_INPUT;
    hc.clipboard = MOONSEC_CLIPBOARD_APP;
    hc.width = 320;
    hc.height = 180;
    hc.notify = on_notify;
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));

    frame_counter fc;
    memset(&fc, 0, sizeof fc);
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = "";
    cc.clipboard = MOONSEC_CLIPBOARD_APP;
    cc.on_frame = on_frame;
    cc.frame_ctx = &fc;
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));

    moonsec_session *hs = NULL, *cs = NULL;
    OK(moonsec_host_listen_loopback(h, lb, &hs));
    CHECK(hs != NULL);
    CHECK(moonsec_host_listen_loopback(h, lb, NULL) == MOONSEC_ERR_STATE);
    OK(moonsec_client_connect_loopback(c, lb, &cs));
    CHECK(cs != NULL);
    CHECK(moonsec_session_state(hs) == MOONSEC_STATE_CONNECTING);
    /* Not streaming yet: no input, no format. */
    moonsec_input key;
    memset(&key, 0, sizeof key);
    key.kind = MOONSEC_INPUT_KEY;
    key.code = 4;
    key.down = 1;
    CHECK(moonsec_session_send_input(cs, &key) == MOONSEC_ERR_STATE);
    moonsec_video_format vf;
    CHECK(moonsec_session_format(cs, &vf, NULL, NULL) == MOONSEC_ERR_STATE);

    OK(moonsec_loopback_advance(lb, 2000000));
    CHECK(moonsec_loopback_now(lb) == 2000000);
    CHECK(moonsec_session_state(hs) == MOONSEC_STATE_STREAMING);
    CHECK(moonsec_session_state(cs) == MOONSEC_STATE_STREAMING);
    {
        /* While streaming, the list the session got from its capture. */
        moonsec_display_info d;
        size_t nd = 0;
        OK(moonsec_host_displays(h, &d, 1, &nd));
        CHECK(nd == 1 && d.width == 320 && d.primary == 1);
    }
    CHECK(notified > 0);

    moonsec_event hev[256], cev[256];
    int nh = drain_host(h, hev, 256);
    int nc = drain_client(c, cev, 256);
    CHECK(count_type(hev, nh, MOONSEC_EVENT_SESSION_STARTED) == 1);
    CHECK(count_type(cev, nc, MOONSEC_EVENT_SESSION_STARTED) == 1);
    const moonsec_event *st = find_type(cev, nc, MOONSEC_EVENT_SESSION_STARTED);
    if (st) {
        CHECK(st->session == cs);
        CHECK(st->format.codec == MOONSEC_CODEC_PASSTHROUGH);
        CHECK(st->width == 320 && st->height == 180);
        CHECK(st->struct_size == sizeof(moonsec_event));
    }
    uint32_t w = 0, hgt = 0;
    OK(moonsec_session_format(cs, &vf, &w, &hgt));
    CHECK(vf.codec == MOONSEC_CODEC_PASSTHROUGH && vf.bit_depth == 8 && w == 320 && hgt == 180);

    /* Frames reached the app with pixels. */
    CHECK(fc.frames > 60);
    CHECK(fc.with_pixels == fc.frames);
    CHECK(fc.width == 320 && fc.height == 180);

    /* Input: the client app sends, the host app receives (MOONSEC_HOST_APP_INPUT). */
    moonsec_input in[6];
    memset(in, 0, sizeof in);
    in[0].kind = MOONSEC_INPUT_KEY, in[0].code = 4, in[0].down = 1;     /* 'a' down */
    in[1].kind = MOONSEC_INPUT_KEY, in[1].code = 4, in[1].down = 0;     /* 'a' up */
    in[2].kind = MOONSEC_INPUT_BUTTON, in[2].code = 1, in[2].down = 1;  /* left button */
    in[3].kind = MOONSEC_INPUT_SCROLL, in[3].y = -120;
    in[4].kind = MOONSEC_INPUT_MOVE_ABS, in[4].x = 32768, in[4].y = 100;
    in[5].kind = MOONSEC_INPUT_GAMEPAD, in[5].code = 1, in[5].down = 1;
    in[5].pad_buttons = 0x1000, in[5].pad_lx = -12000, in[5].pad_rt = 255;
    for (int i = 0; i < 6; i++) OK(moonsec_session_send_input(cs, &in[i]));
    moonsec_input bad = in[0];
    bad.kind = 99;
    CHECK(moonsec_session_send_input(cs, &bad) == MOONSEC_ERR_INVALID);
    CHECK(moonsec_session_send_input(hs, &in[0]) == MOONSEC_ERR_STATE); /* input goes client to host */

    /* Clipboard both ways. */
    const char *from_client = "copied in the client app \xe2\x9c\x93";
    OK(moonsec_session_clipboard_set(cs, from_client, strlen(from_client)));
    CHECK(moonsec_session_clipboard_set(cs, "\xff\xfe", 2) == MOONSEC_ERR_INVALID);
    OK(moonsec_loopback_advance(lb, 500000));
    nh = drain_host(h, hev, 256);
    int keys_down = 0, keys_up = 0, buttons = 0, scrolls = 0, abs_moves = 0, pads = 0;
    for (int i = 0; i < nh; i++) {
        if (hev[i].type != MOONSEC_EVENT_INPUT) continue;
        CHECK(hev[i].session == hs);
        const moonsec_input *x = &hev[i].input;
        if (x->kind == MOONSEC_INPUT_KEY && x->code == 4) x->down ? keys_down++ : keys_up++;
        if (x->kind == MOONSEC_INPUT_BUTTON && x->code == 1 && x->down) buttons++;
        if (x->kind == MOONSEC_INPUT_SCROLL && x->y == -120) scrolls++;
        if (x->kind == MOONSEC_INPUT_MOVE_ABS && x->x == 32768 && x->y == 100) abs_moves++;
        if (x->kind == MOONSEC_INPUT_GAMEPAD && x->code == 1 && x->down && x->pad_buttons == 0x1000 && x->pad_lx == -12000 && x->pad_rt == 255) pads++;
    }
    CHECK(keys_down == 1 && keys_up == 1);
    CHECK(buttons == 1);
    CHECK(scrolls == 1);
    CHECK(abs_moves == 1);
    CHECK(pads >= 1);
    CHECK(count_type(hev, nh, MOONSEC_EVENT_CLIPBOARD) == 1);
    char text[256];
    size_t len = 0;
    OK(moonsec_session_clipboard_get(hs, text, sizeof text, &len));
    CHECK(len == strlen(from_client) && strcmp(text, from_client) == 0);
    CHECK(moonsec_session_clipboard_get(hs, text, 4, &len) == MOONSEC_ERR_BUFFER_TOO_SMALL);

    const char *from_host = "copied on the host";
    OK(moonsec_session_clipboard_set(hs, from_host, strlen(from_host)));
    OK(moonsec_loopback_advance(lb, 500000));
    nc = drain_client(c, cev, 256);
    CHECK(count_type(cev, nc, MOONSEC_EVENT_CLIPBOARD) == 1);
    OK(moonsec_session_clipboard_get(cs, text, sizeof text, &len));
    CHECK(strcmp(text, from_host) == 0);

    /* Telemetry, full size. */
    moonsec_telemetry t;
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    OK(moonsec_session_telemetry(cs, &t));
    CHECK(t.struct_size == sizeof t);
    CHECK(t.state == MOONSEC_STATE_STREAMING);
    CHECK(t.stage_count == 7);
    CHECK(t.frames > 100);
    CHECK(t.width == 320 && t.fps == 60);
    CHECK(t.bitrate_bps > 0);
    CHECK(t.flags & MOONSEC_TELEMETRY_CLOCK_SYNCED);
    CHECK(t.stages[MOONSEC_STAGE_DECODE].count > 0);
    CHECK(t.stages[MOONSEC_STAGE_TOTAL].count > 0);
    CHECK(t.stages[MOONSEC_STAGE_TOTAL].p50_us > 0 && t.stages[MOONSEC_STAGE_TOTAL].p50_us < 200000);
    CHECK(t.stages[MOONSEC_STAGE_TOTAL].min_us <= t.stages[MOONSEC_STAGE_TOTAL].max_us);
    CHECK(t.input_events >= 6);
    moonsec_telemetry ht;
    memset(&ht, 0, sizeof ht);
    ht.struct_size = sizeof ht;
    OK(moonsec_session_telemetry(hs, &ht));
    CHECK(ht.frames > 100);
    CHECK(ht.keyframes >= 1);
    CHECK(ht.stages[MOONSEC_STAGE_ENCODE].count > 0);
    CHECK(ht.input_events >= 6);
    if (profile == MOONSEC_PROFILE_CLEAN) CHECK(t.frames_lost == 0 && t.freezes == 0);

    /* An older caller's smaller struct: only its bytes are written. */
    unsigned char raw[sizeof(moonsec_telemetry) + 16];
    memset(raw, 0xAB, sizeof raw);
    moonsec_telemetry *small = (moonsec_telemetry *)raw;
    small->struct_size = (uint32_t)offsetof(moonsec_telemetry, stages);
    OK(moonsec_session_telemetry(cs, small));
    CHECK(small->struct_size == offsetof(moonsec_telemetry, stages));
    CHECK(small->frames > 100);
    CHECK(raw[offsetof(moonsec_telemetry, stages)] == 0xAB);
    CHECK(raw[sizeof(moonsec_telemetry) - 1] == 0xAB);
    small->struct_size = 4;
    CHECK(moonsec_session_telemetry(cs, small) == MOONSEC_ERR_INVALID);

    /* The client closes: both ends see the session end. */
    OK(moonsec_session_close(cs));
    OK(moonsec_loopback_advance(lb, 500000));
    CHECK(moonsec_session_state(cs) == MOONSEC_STATE_ENDED);
    CHECK(moonsec_session_state(hs) == MOONSEC_STATE_ENDED);
    nh = drain_host(h, hev, 256);
    nc = drain_client(c, cev, 256);
    const moonsec_event *he = find_type(hev, nh, MOONSEC_EVENT_SESSION_ENDED);
    const moonsec_event *ce = find_type(cev, nc, MOONSEC_EVENT_SESSION_ENDED);
    CHECK(he != NULL && he->code == MOONSEC_END_PEER_CLOSED);
    CHECK(ce != NULL && ce->code == MOONSEC_END_CLOSED);
    CHECK(moonsec_session_send_input(cs, &in[0]) == MOONSEC_ERR_STATE);
    memset(&t, 0, sizeof t);
    t.struct_size = sizeof t;
    OK(moonsec_session_telemetry(cs, &t)); /* still readable after the end */
    CHECK(t.state == MOONSEC_STATE_ENDED && t.end_reason == MOONSEC_END_CLOSED);

    printf("profile %u: client presented %llu frames (lost %llu, freezes %llu), glass-to-glass p50 %.2f ms p99 %.2f ms; host sent %llu, input %llu\n",
           profile, (unsigned long long)t.frames, (unsigned long long)t.frames_lost, (unsigned long long)t.freezes,
           t.stages[MOONSEC_STAGE_TOTAL].p50_us / 1000.0, t.stages[MOONSEC_STAGE_TOTAL].p99_us / 1000.0,
           (unsigned long long)ht.frames, (unsigned long long)ht.input_events);

    /* Another session on the same loopback after releasing the old ones. */
    moonsec_session_release(cs);
    moonsec_session_release(hs);
    OK(moonsec_host_listen_loopback(h, lb, &hs));
    OK(moonsec_client_connect_loopback(c, lb, &cs));
    OK(moonsec_loopback_advance(lb, 1000000));
    CHECK(moonsec_session_state(cs) == MOONSEC_STATE_STREAMING);
    /* Destroying the host ends the client's session (the host says bye). */
    moonsec_host_destroy(h);
    OK(moonsec_loopback_advance(lb, 500000));
    CHECK(moonsec_session_state(cs) == MOONSEC_STATE_ENDED);
    nc = drain_client(c, cev, 256);
    ce = find_type(cev, nc, MOONSEC_EVENT_SESSION_ENDED);
    CHECK(ce != NULL && ce->code == MOONSEC_END_PEER_CLOSED);
    moonsec_client_destroy(c);
    moonsec_loopback_destroy(lb);
}

/* A client that offers only H.264 cannot decode the synthetic host's passthrough: the
 * host turns it away and both sessions end as failed or timed out, never streaming. */
static void test_no_common_codec(void) {
    moonsec_loopback_config lc = {sizeof lc, MOONSEC_PROFILE_CLEAN, 1};
    moonsec_loopback *lb = NULL;
    OK(moonsec_loopback_create(&lc, &lb));
    moonsec_host_config hc;
    memset(&hc, 0, sizeof hc);
    hc.struct_size = sizeof hc;
    hc.state_dir = "";
    moonsec_host *h = NULL;
    OK(moonsec_host_create(&hc, &h));
    moonsec_client_config cc;
    memset(&cc, 0, sizeof cc);
    cc.struct_size = sizeof cc;
    cc.state_dir = "";
    cc.codecs = MOONSEC_CODECS_H264;
    moonsec_client *c = NULL;
    OK(moonsec_client_create(&cc, &c));
    moonsec_session *cs = NULL;
    OK(moonsec_host_listen_loopback(h, lb, NULL));
    OK(moonsec_client_connect_loopback(c, lb, &cs));
    OK(moonsec_loopback_advance(lb, 12000000));
    CHECK(moonsec_session_state(cs) == MOONSEC_STATE_ENDED);
    moonsec_event cev[64];
    int nc = drain_client(c, cev, 64);
    CHECK(count_type(cev, nc, MOONSEC_EVENT_SESSION_STARTED) == 0);
    const moonsec_event *ce = find_type(cev, nc, MOONSEC_EVENT_SESSION_ENDED);
    CHECK(ce != NULL && ce->code != MOONSEC_END_CLOSED);
    moonsec_client_destroy(c);
    moonsec_host_destroy(h);
    moonsec_loopback_destroy(lb);
}

int main(void) {
    test_basics();
    test_stream(MOONSEC_PROFILE_CLEAN);
    test_stream(MOONSEC_PROFILE_LAN);
    test_stream(MOONSEC_PROFILE_WAN);
    test_no_common_codec();
    if (failures) {
        fprintf(stderr, "abi loopback test: %d failures\n", failures);
        return 1;
    }
    printf("abi loopback test: ok\n");
    return 0;
}
