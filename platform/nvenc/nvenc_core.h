/* The OS-independent half of the NVENC encoders: session setup, the low-latency
 * configuration, long-term-reference bookkeeping, resource registration and the encode
 * call. The Windows host (platform/host/windows/enc_nvenc.c: nvEncodeAPI64.dll, D3D11
 * textures) and the Linux host (platform/host/linux/enc_nvenc.c: libnvidia-encode.so.1,
 * CUDA device memory) each add loading the library, the device, input resources and
 * error mapping.
 *
 * Settings: P1 preset with the ultra-low-latency tuning, CBR with a one-frame VBV, infinite
 * GOP, no B-frames, no lookahead, `slices` slices, parameter sets on every IDR, long-term
 * references in "per picture" mode (two slots, a mark every NVC_LTR_INTERVAL frames, on
 * IDRs and on refreshes, into the slot that doesn't hold the newest acked one), bitrate
 * changes through nvEncReconfigureEncoder without an IDR. Synchronous mode. */
#ifndef NVENC_CORE_H
#define NVENC_CORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-const-variable"
#endif
#include "nvEncodeAPI.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#define NVC_LTR_SLOTS 2
#define NVC_LTR_INTERVAL 15
#define NVC_MAX_REGS 8

enum { NVC_CODEC_H264 = 1, NVC_CODEC_HEVC = 2 };
enum { NVC_FORCE_NONE = 0, NVC_FORCE_LTR_REFRESH = 1, NVC_FORCE_IDR = 2 };

typedef NVENCSTATUS(NVENCAPI *nvc_pfn_create_instance)(NV_ENCODE_API_FUNCTION_LIST *);
typedef NVENCSTATUS(NVENCAPI *nvc_pfn_max_version)(uint32_t *);

typedef struct nvc_config {
    uint32_t codec;
    uint32_t width, height, fps;
    uint64_t bitrate_bps;
    uint32_t slices;
    uint32_t ltr;
} nvc_config;

typedef struct nvc_params {
    uint32_t force;
    uint64_t bitrate_bps; /* 0 = unchanged */
    const uint64_t *acked_ltr_tokens;
    uint32_t acked_ltr_count;
} nvc_params;

typedef struct nvc_output {
    uint32_t keyframe;
    uint32_t dropped;
    uint32_t has_ltr_token;
    uint64_t ltr_token;
    uint32_t ltr_refresh;
} nvc_output;

/* Appends encoded bytes; returns 0, or nonzero when out of memory. */
typedef int (*nvc_append_fn)(void *ctx, const void *data, size_t len);

typedef struct nvc_ltr {
    uint64_t token; /* 0 = empty */
    int acked;
} nvc_ltr;

typedef struct nvc_reg {
    void *resource;
    uint32_t index;
    NV_ENC_REGISTERED_PTR reg;
    uint64_t last_use;
} nvc_reg;

typedef struct nvc {
    NV_ENCODE_API_FUNCTION_LIST fn;
    void *enc;
    void *device;
    NV_ENC_DEVICE_TYPE device_type;
    int h264, hevc, ltr_supported;
    int initialized;
    nvc_config cfg;
    NV_ENC_INITIALIZE_PARAMS init;
    NV_ENC_CONFIG config;
    NV_ENC_OUTPUT_PTR bitstream;
    nvc_reg regs[NVC_MAX_REGS];
    uint64_t frame;
    nvc_ltr ltr[NVC_LTR_SLOTS];
    uint64_t since_mark;
} nvc;

/* Fills the function list (checking the driver's API version against the header's: too
 * old is NV_ENC_ERR_INVALID_VERSION), opens a session on `device` and probes codecs and
 * long-term references. With no H.264 or HEVC: NV_ENC_ERR_UNSUPPORTED_DEVICE. */
NVENCSTATUS nvc_open(nvc *n, nvc_pfn_max_version maxver, nvc_pfn_create_instance create, void *device,
                     NV_ENC_DEVICE_TYPE type);
/* A new encoder for every configure (sizes and codecs may change). */
NVENCSTATUS nvc_configure(nvc *n, const nvc_config *cfg);
/* The registration of (resource, index), registering it on first use (least recently
 * used of NVC_MAX_REGS goes). `pitch` 0 lets NVENC take it from the resource. */
NVENCSTATUS nvc_register(nvc *n, NV_ENC_INPUT_RESOURCE_TYPE type, void *resource, uint32_t index, uint32_t pitch,
                         NV_ENC_BUFFER_FORMAT format, NV_ENC_REGISTERED_PTR *out);
/* Drops every registration of `resource` (before the caller frees it). */
void nvc_forget(nvc *n, void *resource);
/* Maps, encodes and unmaps one registered input; the access unit goes to `append`.
 * NV_ENC_ERR_NEED_MORE_INPUT is reported as out->dropped. */
NVENCSTATUS nvc_encode(nvc *n, NV_ENC_REGISTERED_PTR reg, uint64_t time_us, const nvc_params *p, nvc_append_fn append,
                       void *ctx, nvc_output *out);
void nvc_close(nvc *n);

#endif
