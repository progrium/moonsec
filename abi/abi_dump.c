/* The ABI dump: every struct's size and field offsets, every constant, every function.
 * `abi-dump --check abi/abi-v1.txt` fails when the build's ABI differs from the frozen
 * one (the dump is for 64-bit targets); `abi-dump --write FILE` regenerates it. Taking
 * each function's address also checks that the library exports it.
 *
 * Keep it complete: abi/header_test.zig fails when the header has a struct, field,
 * constant or function this file does not list. */
#include <moonsec.h>

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char out[1 << 16];
static size_t used = 0;

static void put(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#include <stdarg.h>
static void put(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(out + used, sizeof out - used, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof out - used) {
        fprintf(stderr, "abi-dump: buffer full\n");
        exit(2);
    }
    used += (size_t)n;
}

#define S(T) put("struct %s size %zu align %zu\n", #T, sizeof(T), _Alignof(T))
#define F(T, f) put("  %s.%s offset %zu size %zu\n", #T, #f, offsetof(T, f), sizeof(((T *)0)->f))
#define K(name) put("const %s %lld\n", #name, (long long)(name))
/* The address goes through a volatile so the linker must resolve every function. */
static void (*volatile sink)(void);
#define FN(name) (sink = (void (*)(void))(void *)&name, put("fn %s\n", #name))

static void dump(void) {
    S(moonsec_video_format);
    F(moonsec_video_format, codec);
    F(moonsec_video_format, chroma);
    F(moonsec_video_format, bit_depth);
    F(moonsec_video_format, color);
    S(moonsec_input);
    F(moonsec_input, kind);
    F(moonsec_input, code);
    F(moonsec_input, down);
    F(moonsec_input, x);
    F(moonsec_input, y);
    F(moonsec_input, pad_buttons);
    F(moonsec_input, pad_lx);
    F(moonsec_input, pad_ly);
    F(moonsec_input, pad_rx);
    F(moonsec_input, pad_ry);
    F(moonsec_input, pad_lt);
    F(moonsec_input, pad_rt);
    F(moonsec_input, reserved);
    F(moonsec_input, time_us);
    S(moonsec_host_config);
    F(moonsec_host_config, struct_size);
    F(moonsec_host_config, backend);
    F(moonsec_host_config, state_dir);
    F(moonsec_host_config, name);
    F(moonsec_host_config, flags);
    F(moonsec_host_config, codec);
    F(moonsec_host_config, fps);
    F(moonsec_host_config, display);
    F(moonsec_host_config, width);
    F(moonsec_host_config, height);
    F(moonsec_host_config, bitrate_bps);
    F(moonsec_host_config, clipboard);
    F(moonsec_host_config, max_clients);
    F(moonsec_host_config, relay_mode);
    F(moonsec_host_config, reserved0);
    F(moonsec_host_config, relay_url);
    F(moonsec_host_config, relay_ca_pem);
    F(moonsec_host_config, bind_addr);
    F(moonsec_host_config, notify);
    F(moonsec_host_config, notify_ctx);
    S(moonsec_pair_config);
    F(moonsec_pair_config, struct_size);
    F(moonsec_pair_config, seconds);
    F(moonsec_pair_config, pairings);
    F(moonsec_pair_config, method);
    S(moonsec_pair_info);
    F(moonsec_pair_info, struct_size);
    F(moonsec_pair_info, seconds);
    F(moonsec_pair_info, qr_ticket);
    F(moonsec_pair_info, addr_ticket);
    F(moonsec_pair_info, pin);
    S(moonsec_display_info);
    F(moonsec_display_info, index);
    F(moonsec_display_info, width);
    F(moonsec_display_info, height);
    F(moonsec_display_info, refresh_mhz);
    F(moonsec_display_info, primary);
    F(moonsec_display_info, hdr);
    F(moonsec_display_info, name);
    S(moonsec_frame);
    F(moonsec_frame, struct_size);
    F(moonsec_frame, frame_id);
    F(moonsec_frame, width);
    F(moonsec_frame, height);
    F(moonsec_frame, format);
    F(moonsec_frame, pixels);
    F(moonsec_frame, stride);
    F(moonsec_frame, reserved);
    F(moonsec_frame, gpu_texture);
    F(moonsec_frame, presented_us);
    S(moonsec_client_config);
    F(moonsec_client_config, struct_size);
    F(moonsec_client_config, backend);
    F(moonsec_client_config, state_dir);
    F(moonsec_client_config, name);
    F(moonsec_client_config, flags);
    F(moonsec_client_config, codecs);
    F(moonsec_client_config, max_width);
    F(moonsec_client_config, max_height);
    F(moonsec_client_config, clipboard);
    F(moonsec_client_config, relay_mode);
    F(moonsec_client_config, relay_url);
    F(moonsec_client_config, relay_ca_pem);
    F(moonsec_client_config, bind_addr);
    F(moonsec_client_config, notify);
    F(moonsec_client_config, notify_ctx);
    F(moonsec_client_config, on_frame);
    F(moonsec_client_config, frame_ctx);
    S(moonsec_stage_stats);
    F(moonsec_stage_stats, count);
    F(moonsec_stage_stats, reserved);
    F(moonsec_stage_stats, min_us);
    F(moonsec_stage_stats, mean_us);
    F(moonsec_stage_stats, p50_us);
    F(moonsec_stage_stats, p95_us);
    F(moonsec_stage_stats, p99_us);
    F(moonsec_stage_stats, max_us);
    S(moonsec_telemetry);
    F(moonsec_telemetry, struct_size);
    F(moonsec_telemetry, state);
    F(moonsec_telemetry, end_reason);
    F(moonsec_telemetry, flags);
    F(moonsec_telemetry, format);
    F(moonsec_telemetry, width);
    F(moonsec_telemetry, height);
    F(moonsec_telemetry, fps);
    F(moonsec_telemetry, stage_count);
    F(moonsec_telemetry, bitrate_bps);
    F(moonsec_telemetry, pacing_bps);
    F(moonsec_telemetry, rtt_us);
    F(moonsec_telemetry, frames);
    F(moonsec_telemetry, frames_lost);
    F(moonsec_telemetry, keyframes);
    F(moonsec_telemetry, refreshes);
    F(moonsec_telemetry, freezes);
    F(moonsec_telemetry, longest_gap_us);
    F(moonsec_telemetry, retransmits);
    F(moonsec_telemetry, parity_shards);
    F(moonsec_telemetry, input_events);
    F(moonsec_telemetry, path_changes);
    F(moonsec_telemetry, reconnects);
    F(moonsec_telemetry, stages);
    S(moonsec_event);
    F(moonsec_event, struct_size);
    F(moonsec_event, type);
    F(moonsec_event, session);
    F(moonsec_event, time_us);
    F(moonsec_event, code);
    F(moonsec_event, width);
    F(moonsec_event, height);
    F(moonsec_event, reserved);
    F(moonsec_event, format);
    F(moonsec_event, input);
    F(moonsec_event, peer_id);
    F(moonsec_event, peer_name);
    S(moonsec_loopback_config);
    F(moonsec_loopback_config, struct_size);
    F(moonsec_loopback_config, profile);
    F(moonsec_loopback_config, seed);

    K(MOONSEC_ABI_MAJOR);
    K(MOONSEC_ABI_MINOR);
    K(MOONSEC_ABI_PATCH);
    K(MOONSEC_ABI_VERSION);
    K(MOONSEC_FEATURE_LOOPBACK);
    K(MOONSEC_FEATURE_IROH);
    K(MOONSEC_FEATURE_SYSTEM_BACKEND);
    K(MOONSEC_FEATURE_MULTI_USER);
    K(MOONSEC_FEATURE_DISPLAYS);
    K(MOONSEC_OK);
    K(MOONSEC_ERR_INVALID);
    K(MOONSEC_ERR_UNSUPPORTED);
    K(MOONSEC_ERR_NO_MEMORY);
    K(MOONSEC_ERR_STATE);
    K(MOONSEC_ERR_BUFFER_TOO_SMALL);
    K(MOONSEC_ERR_TIMEOUT);
    K(MOONSEC_ERR_TRANSPORT);
    K(MOONSEC_ERR_REFUSED);
    K(MOONSEC_ERR_BACKEND);
    K(MOONSEC_ERR_IO);
    K(MOONSEC_ERR_INTERNAL);
    K(MOONSEC_BACKEND_SYNTHETIC);
    K(MOONSEC_BACKEND_SYSTEM);
    K(MOONSEC_CODEC_H264);
    K(MOONSEC_CODEC_HEVC);
    K(MOONSEC_CODEC_AV1);
    K(MOONSEC_CODEC_PASSTHROUGH);
    K(MOONSEC_CODECS_H264);
    K(MOONSEC_CODECS_HEVC);
    K(MOONSEC_CODECS_AV1);
    K(MOONSEC_CODECS_PASSTHROUGH);
    K(MOONSEC_CHROMA_420);
    K(MOONSEC_CHROMA_444);
    K(MOONSEC_COLOR_SDR_BT709);
    K(MOONSEC_COLOR_HDR10);
    K(MOONSEC_RELAY_DISABLED);
    K(MOONSEC_RELAY_DEFAULT);
    K(MOONSEC_RELAY_CUSTOM);
    K(MOONSEC_CLIPBOARD_OFF);
    K(MOONSEC_CLIPBOARD_SYSTEM);
    K(MOONSEC_CLIPBOARD_APP);
    K(MOONSEC_INPUT_KEY);
    K(MOONSEC_INPUT_BUTTON);
    K(MOONSEC_INPUT_SCROLL);
    K(MOONSEC_INPUT_MOVE_REL);
    K(MOONSEC_INPUT_MOVE_ABS);
    K(MOONSEC_INPUT_GAMEPAD);
    K(MOONSEC_HOST_YUV444);
    K(MOONSEC_HOST_TEN_BIT);
    K(MOONSEC_HOST_NO_HDR);
    K(MOONSEC_HOST_RATE_CONTROL);
    K(MOONSEC_HOST_LOSS_POLICY);
    K(MOONSEC_HOST_NO_AUDIO);
    K(MOONSEC_HOST_APP_INPUT);
    K(MOONSEC_HOST_REQUIRE_PAIRED);
    K(MOONSEC_HOST_INSECURE_NO_PAIRING);
    K(MOONSEC_PERM_INPUT);
    K(MOONSEC_PERM_CLIPBOARD);
    K(MOONSEC_PERM_ALL);
    K(MOONSEC_PAIR_QR_AND_PIN);
    K(MOONSEC_PAIR_QR_ONLY);
    K(MOONSEC_PAIR_PIN_ONLY);
    K(MOONSEC_CLIENT_NO_AUDIO);
    K(MOONSEC_CLIENT_NO_OS_INPUT);
    K(MOONSEC_CLIENT_FULLSCREEN);
    K(MOONSEC_CLIENT_REQUIRE_PAIRED);
    K(MOONSEC_CLIENT_INSECURE_NO_PAIRING);
    K(MOONSEC_STATE_CONNECTING);
    K(MOONSEC_STATE_STREAMING);
    K(MOONSEC_STATE_ENDED);
    K(MOONSEC_END_NONE);
    K(MOONSEC_END_CLOSED);
    K(MOONSEC_END_PEER_CLOSED);
    K(MOONSEC_END_TIMEOUT);
    K(MOONSEC_END_TRANSPORT);
    K(MOONSEC_END_FAILED);
    K(MOONSEC_STAGE_CAPTURE);
    K(MOONSEC_STAGE_ENCODE);
    K(MOONSEC_STAGE_NETWORK);
    K(MOONSEC_STAGE_DECODE);
    K(MOONSEC_STAGE_PRESENT);
    K(MOONSEC_STAGE_TOTAL);
    K(MOONSEC_STAGE_INPUT);
    K(MOONSEC_STAGE_MAX);
    K(MOONSEC_TELEMETRY_RELAYED);
    K(MOONSEC_TELEMETRY_CLOCK_SYNCED);
    K(MOONSEC_TELEMETRY_STALLED);
    K(MOONSEC_EVENT_SESSION_STARTED);
    K(MOONSEC_EVENT_SESSION_ENDED);
    K(MOONSEC_EVENT_FORMAT_CHANGED);
    K(MOONSEC_EVENT_INPUT);
    K(MOONSEC_EVENT_CLIPBOARD);
    K(MOONSEC_EVENT_PATH_CHANGED);
    K(MOONSEC_EVENT_PAIRED);
    K(MOONSEC_EVENT_PAIR_FAILED);
    K(MOONSEC_EVENT_PAIR_CLOSED);
    K(MOONSEC_EVENT_INPUT_OWNER);
    K(MOONSEC_EVENT_REFUSED);
    K(MOONSEC_PAIR_FAIL_BAD_PROOF);
    K(MOONSEC_PAIR_FAIL_EXPIRED);
    K(MOONSEC_PAIR_FAIL_OTHER);
    K(MOONSEC_PROFILE_CLEAN);
    K(MOONSEC_PROFILE_LAN);
    K(MOONSEC_PROFILE_WAN);

    FN(moonsec_version);
    FN(moonsec_version_string);
    FN(moonsec_features);
    FN(moonsec_status_string);
    FN(moonsec_last_error);
    FN(moonsec_host_create);
    FN(moonsec_host_destroy);
    FN(moonsec_host_id);
    FN(moonsec_host_listen);
    FN(moonsec_host_ticket);
    FN(moonsec_host_pair_begin);
    FN(moonsec_host_pair_end);
    FN(moonsec_host_set_permissions);
    FN(moonsec_host_listen_loopback);
    FN(moonsec_host_give_input);
    FN(moonsec_host_displays);
    FN(moonsec_client_create);
    FN(moonsec_client_destroy);
    FN(moonsec_client_id);
    FN(moonsec_client_connect);
    FN(moonsec_client_pair);
    FN(moonsec_client_connect_loopback);
    FN(moonsec_session_state);
    FN(moonsec_session_close);
    FN(moonsec_session_release);
    FN(moonsec_session_send_input);
    FN(moonsec_session_request_input);
    FN(moonsec_session_clipboard_set);
    FN(moonsec_session_clipboard_get);
    FN(moonsec_session_format);
    FN(moonsec_session_telemetry);
    FN(moonsec_host_poll_event);
    FN(moonsec_client_poll_event);
    FN(moonsec_loopback_create);
    FN(moonsec_loopback_destroy);
    FN(moonsec_loopback_advance);
    FN(moonsec_loopback_now);

}

static char *readAll(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    static char buf[1 << 16];
    *len = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[*len] = 0;
    return buf;
}

int main(int argc, char **argv) {
    if (sizeof(void *) != 8) {
        printf("abi-dump: the frozen dump is for 64-bit targets; skipped\n");
        return 0;
    }
    dump();
    if (argc == 3 && strcmp(argv[1], "--write") == 0) {
        FILE *f = fopen(argv[2], "wb");
        if (!f || fwrite(out, 1, used, f) != used) {
            fprintf(stderr, "abi-dump: cannot write %s\n", argv[2]);
            return 1;
        }
        fclose(f);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--check") == 0) {
        size_t len = 0;
        const char *want = readAll(argv[2], &len);
        if (!want) {
            fprintf(stderr, "abi-dump: cannot read %s\n", argv[2]);
            return 1;
        }
        if (len == used && memcmp(want, out, used) == 0) {
            printf("abi-dump: matches %s\n", argv[2]);
            return 0;
        }
        /* Show the first line that differs. */
        size_t i = 0, line = 1, start = 0;
        while (i < len && i < used && want[i] == out[i]) {
            if (out[i] == '\n') line++, start = i + 1;
            i++;
        }
        const char *a = want + start, *b = out + start;
        fprintf(stderr, "abi-dump: the ABI differs from %s at line %zu\n  frozen: %.*s\n  build:  %.*s\n",
                argv[2], line, (int)strcspn(a, "\n"), a, (int)strcspn(b, "\n"), b);
        fprintf(stderr, "A 1.x change may only add at the end; if this change is meant, regenerate with\n  zig build abi-dump -- --write abi/abi-v1.txt\n");
        return 1;
    }
    fwrite(out, 1, used, stdout);
    return 0;
}
