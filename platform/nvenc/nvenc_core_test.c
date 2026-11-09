/* `zig build test-nvenc-core`: the shared NVENC core against a fake NVENC function list,
 * so its long-term-reference choices and rate changes are checked without NVIDIA
 * hardware (none is planned). Exits 0 on success. */
#include <stdio.h>
#include <string.h>

#include "nvenc_core.h"

static NV_ENC_PIC_PARAMS last_pic;
static int encodes, reconfigs, reconfig_idr, registered, unregistered;
static uint8_t payload[4] = {0, 0, 1, 0x65};

static NVENCSTATUS NVENCAPI f_open(NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS *p, void **enc) {
    (void)p;
    *enc = (void *)1;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_guid_count(void *e, uint32_t *n) {
    (void)e;
    *n = 2;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_guids(void *e, GUID *g, uint32_t size, uint32_t *n) {
    (void)e;
    (void)size;
    g[0] = NV_ENC_CODEC_H264_GUID;
    g[1] = NV_ENC_CODEC_HEVC_GUID;
    *n = 2;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_caps(void *e, GUID g, NV_ENC_CAPS_PARAM *p, int *v) {
    (void)e;
    (void)g;
    *v = p->capsToQuery == NV_ENC_CAPS_NUM_MAX_LTR_FRAMES ? 2 : 1;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_preset(void *e, GUID c, GUID p, NV_ENC_TUNING_INFO t, NV_ENC_PRESET_CONFIG *cfg) {
    (void)e;
    (void)c;
    (void)p;
    (void)t;
    (void)cfg;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_init(void *e, NV_ENC_INITIALIZE_PARAMS *p) {
    (void)e;
    return p->encodeConfig->frameIntervalP == 1 && p->encodeConfig->rcParams.rateControlMode == NV_ENC_PARAMS_RC_CBR
               ? NV_ENC_SUCCESS
               : NV_ENC_ERR_INVALID_PARAM;
}
static NVENCSTATUS NVENCAPI f_create_bs(void *e, NV_ENC_CREATE_BITSTREAM_BUFFER *b) {
    (void)e;
    b->bitstreamBuffer = (void *)2;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_destroy_bs(void *e, NV_ENC_OUTPUT_PTR b) {
    (void)e;
    (void)b;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_register(void *e, NV_ENC_REGISTER_RESOURCE *r) {
    (void)e;
    registered++;
    r->registeredResource = (void *)3;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_unregister(void *e, NV_ENC_REGISTERED_PTR r) {
    (void)e;
    (void)r;
    unregistered++;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_map(void *e, NV_ENC_MAP_INPUT_RESOURCE *m) {
    (void)e;
    m->mappedResource = (void *)4;
    m->mappedBufferFmt = NV_ENC_BUFFER_FORMAT_ARGB;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_unmap(void *e, NV_ENC_INPUT_PTR m) {
    (void)e;
    (void)m;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_encode(void *e, NV_ENC_PIC_PARAMS *p) {
    (void)e;
    last_pic = *p;
    encodes++;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_lock(void *e, NV_ENC_LOCK_BITSTREAM *l) {
    (void)e;
    l->bitstreamBufferPtr = payload;
    l->bitstreamSizeInBytes = sizeof payload;
    l->pictureType = (last_pic.encodePicFlags & NV_ENC_PIC_FLAG_FORCEIDR) ? NV_ENC_PIC_TYPE_IDR : NV_ENC_PIC_TYPE_P;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_unlock(void *e, NV_ENC_OUTPUT_PTR b) {
    (void)e;
    (void)b;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_reconfig(void *e, NV_ENC_RECONFIGURE_PARAMS *r) {
    (void)e;
    reconfigs++;
    reconfig_idr += r->forceIDR;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI f_destroy(void *e) {
    (void)e;
    return NV_ENC_SUCCESS;
}

static NVENCSTATUS NVENCAPI fake_max_version(uint32_t *v) {
    *v = (NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION;
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI old_max_version(uint32_t *v) {
    *v = (11 << 4);
    return NV_ENC_SUCCESS;
}
static NVENCSTATUS NVENCAPI fake_create(NV_ENCODE_API_FUNCTION_LIST *f) {
    f->nvEncOpenEncodeSessionEx = f_open;
    f->nvEncGetEncodeGUIDCount = f_guid_count;
    f->nvEncGetEncodeGUIDs = f_guids;
    f->nvEncGetEncodeCaps = f_caps;
    f->nvEncGetEncodePresetConfigEx = f_preset;
    f->nvEncInitializeEncoder = f_init;
    f->nvEncCreateBitstreamBuffer = f_create_bs;
    f->nvEncDestroyBitstreamBuffer = f_destroy_bs;
    f->nvEncRegisterResource = f_register;
    f->nvEncUnregisterResource = f_unregister;
    f->nvEncMapInputResource = f_map;
    f->nvEncUnmapInputResource = f_unmap;
    f->nvEncEncodePicture = f_encode;
    f->nvEncLockBitstream = f_lock;
    f->nvEncUnlockBitstream = f_unlock;
    f->nvEncReconfigureEncoder = f_reconfig;
    f->nvEncDestroyEncoder = f_destroy;
    return NV_ENC_SUCCESS;
}

static int failures;
#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        if (!(cond)) {                                                                                                 \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond);                                  \
            failures++;                                                                                                \
        }                                                                                                              \
    } while (0)

static int sink(void *ctx, const void *d, size_t n) {
    (void)d;
    *(size_t *)ctx += n;
    return 0;
}

static nvc_output frame(nvc *n, uint32_t force, const uint64_t *acked, uint32_t nacked, uint64_t bitrate) {
    NV_ENC_REGISTERED_PTR reg;
    CHECK(nvc_register(n, NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR, (void *)0x1000, 0, 1024, NV_ENC_BUFFER_FORMAT_ARGB, &reg) == NV_ENC_SUCCESS);
    nvc_params p = {.force = force, .bitrate_bps = bitrate, .acked_ltr_tokens = acked, .acked_ltr_count = nacked};
    nvc_output o;
    size_t bytes = 0;
    CHECK(nvc_encode(n, reg, 0, &p, sink, &bytes, &o) == NV_ENC_SUCCESS);
    CHECK(bytes == sizeof payload);
    return o;
}

int main(void) {
    nvc n;
    CHECK(nvc_open(&n, old_max_version, fake_create, NULL, NV_ENC_DEVICE_TYPE_CUDA) == NV_ENC_ERR_INVALID_VERSION);
    CHECK(nvc_open(&n, fake_max_version, fake_create, NULL, NV_ENC_DEVICE_TYPE_CUDA) == NV_ENC_SUCCESS);
    CHECK(n.h264 && n.hevc && n.ltr_supported);
    const nvc_config cfg = {.codec = NVC_CODEC_H264, .width = 64, .height = 64, .fps = 60, .bitrate_bps = 1000000, .slices = 2, .ltr = 1};
    CHECK(nvc_configure(&n, &cfg) == NV_ENC_SUCCESS);

    /* Frame 0: IDR, marked into slot 0 (token 1). */
    nvc_output o = frame(&n, NVC_FORCE_NONE, NULL, 0, 0);
    CHECK(o.keyframe && o.has_ltr_token && o.ltr_token == 1);
    CHECK(last_pic.codecPicParams.h264PicParams.ltrMarkFrame && last_pic.codecPicParams.h264PicParams.ltrMarkFrameIdx == 0);
    /* Frames 1-14 unmarked; frame 15 marked into slot 1 (token 16). */
    for (int i = 1; i < 15; i++) {
        o = frame(&n, NVC_FORCE_NONE, NULL, 0, 0);
        CHECK(!o.keyframe && !o.has_ltr_token);
    }
    const uint64_t ack1 = 1;
    o = frame(&n, NVC_FORCE_NONE, &ack1, 1, 0);
    CHECK(o.has_ltr_token && o.ltr_token == 16 && last_pic.codecPicParams.h264PicParams.ltrMarkFrameIdx == 1);
    /* A bitrate change reconfigures without an IDR. */
    o = frame(&n, NVC_FORCE_NONE, NULL, 0, 500000);
    CHECK(reconfigs == 1 && reconfig_idr == 0 && !o.keyframe);
    /* Refresh with only token 1 acked: predicts from slot 0, marks slot 1 (not the acked one). */
    o = frame(&n, NVC_FORCE_LTR_REFRESH, NULL, 0, 0);
    CHECK(!o.keyframe && o.ltr_refresh);
    CHECK(last_pic.codecPicParams.h264PicParams.ltrUseFrames && last_pic.codecPicParams.h264PicParams.ltrUseFrameBitmap == 1);
    CHECK(last_pic.codecPicParams.h264PicParams.ltrMarkFrame && last_pic.codecPicParams.h264PicParams.ltrMarkFrameIdx == 1);
    /* An IDR forgets the acks: a refresh right after it is an IDR too. */
    o = frame(&n, NVC_FORCE_IDR, NULL, 0, 0);
    CHECK(o.keyframe && !o.ltr_refresh);
    o = frame(&n, NVC_FORCE_LTR_REFRESH, NULL, 0, 0);
    CHECK(o.keyframe && !o.ltr_refresh);
    /* Without long-term references every refresh is an IDR and nothing is marked. */
    const nvc_config no_ltr = {.codec = NVC_CODEC_HEVC, .width = 64, .height = 64, .fps = 60, .bitrate_bps = 1000000, .slices = 1, .ltr = 0};
    CHECK(nvc_configure(&n, &no_ltr) == NV_ENC_SUCCESS);
    CHECK(unregistered >= 1); /* reconfigure drops registrations */
    frame(&n, NVC_FORCE_NONE, NULL, 0, 0);
    o = frame(&n, NVC_FORCE_LTR_REFRESH, NULL, 0, 0);
    CHECK(o.keyframe && !o.has_ltr_token && !o.ltr_refresh);
    nvc_close(&n);
    if (failures) return 1;
    printf("nvenc core: %d encodes, all checks passed\n", encodes);
    return 0;
}
