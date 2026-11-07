#pragma once
#include <stdint.h>

typedef struct {
    int source;       // 0 synthetic, 1 SCK display, 2 SCK window
    int codec;        // 0 H.264, 1 HEVC
    int low_latency;  // 1 = kVTVideoEncoderSpecification_EnableLowLatencyRateControl
    int pixfmt;       // 0 NV12 (420v), 1 BGRA
    int scene;        // 0 motion, 1 noise
    int width, height, fps, seconds, bitrate_kbps;
    int show_window;  // animated content window
} probe_config;

typedef struct {
    double capture_ms;  // SCK display time -> sample handler (0 for synthetic)
    double encode_ms;   // VTCompressionSessionEncodeFrame -> output callback
    double total_ms;    // display time (or frame creation) -> encoded output
    uint32_t bytes;
    uint8_t keyframe;
    uint8_t done;
    uint8_t ltr_token;  // frame carries an LTR ack token
    uint8_t refresh;    // frame was encoded with ForceLTRRefresh
    uint8_t lost;       // simulated lost or dropped-by-client frame
} probe_sample;

// Returns 0 on success; info receives a human readable description of the session.
int probe_run(const probe_config *cfg, probe_sample *out, int max, int *count, char *info, int infolen);
