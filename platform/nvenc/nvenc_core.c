/* The OS-independent half of the NVENC encoders (see nvenc_core.h). */
#include "nvenc_core.h"

#include <string.h>

static int guid_eq(const GUID *a, const GUID *b) { return memcmp(a, b, sizeof *a) == 0; }

static int has_guid(nvc *n, const GUID *g) {
    uint32_t count = 0, got = 0;
    if (n->fn.nvEncGetEncodeGUIDCount(n->enc, &count) != NV_ENC_SUCCESS || count == 0) return 0;
    GUID guids[16];
    if (count > 16) count = 16;
    if (n->fn.nvEncGetEncodeGUIDs(n->enc, guids, count, &got) != NV_ENC_SUCCESS) return 0;
    for (uint32_t i = 0; i < got; i++)
        if (guid_eq(&guids[i], g)) return 1;
    return 0;
}

static int cap(nvc *n, const GUID *codec, NV_ENC_CAPS which) {
    NV_ENC_CAPS_PARAM p;
    memset(&p, 0, sizeof p);
    p.version = NV_ENC_CAPS_PARAM_VER;
    p.capsToQuery = which;
    int v = 0;
    if (n->fn.nvEncGetEncodeCaps(n->enc, *codec, &p, &v) != NV_ENC_SUCCESS) return 0;
    return v;
}

static NVENCSTATUS open_session(nvc *n) {
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op;
    memset(&op, 0, sizeof op);
    op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    op.device = n->device;
    op.deviceType = n->device_type;
    op.apiVersion = NVENCAPI_VERSION;
    return n->fn.nvEncOpenEncodeSessionEx(&op, &n->enc);
}

NVENCSTATUS nvc_open(nvc *n, nvc_pfn_max_version maxver, nvc_pfn_create_instance create, void *device,
                     NV_ENC_DEVICE_TYPE type) {
    memset(n, 0, sizeof *n);
    n->device = device;
    n->device_type = type;
    uint32_t v = 0;
    if (maxver(&v) != NV_ENC_SUCCESS || v < ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION))
        return NV_ENC_ERR_INVALID_VERSION; /* driver older than the header (522.25 on Windows, 520.56.06 on Linux) */
    n->fn.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    NVENCSTATUS s = create(&n->fn);
    if (s != NV_ENC_SUCCESS) return s;
    s = open_session(n);
    if (s != NV_ENC_SUCCESS) {
        n->enc = NULL;
        return s;
    }
    n->h264 = has_guid(n, &NV_ENC_CODEC_H264_GUID);
    n->hevc = has_guid(n, &NV_ENC_CODEC_HEVC_GUID);
    if (!n->h264 && !n->hevc) return NV_ENC_ERR_UNSUPPORTED_DEVICE;
    n->ltr_supported =
        cap(n, n->h264 ? &NV_ENC_CODEC_H264_GUID : &NV_ENC_CODEC_HEVC_GUID, NV_ENC_CAPS_NUM_MAX_LTR_FRAMES) >= NVC_LTR_SLOTS;
    return NV_ENC_SUCCESS;
}

static void unregister_all(nvc *n) {
    for (int i = 0; i < NVC_MAX_REGS; i++) {
        if (n->regs[i].reg) n->fn.nvEncUnregisterResource(n->enc, n->regs[i].reg);
        memset(&n->regs[i], 0, sizeof n->regs[i]);
    }
}

NVENCSTATUS nvc_configure(nvc *n, const nvc_config *cfg) {
    const GUID *codec = cfg->codec == NVC_CODEC_HEVC ? &NV_ENC_CODEC_HEVC_GUID : &NV_ENC_CODEC_H264_GUID;
    if ((cfg->codec == NVC_CODEC_HEVC && !n->hevc) || (cfg->codec == NVC_CODEC_H264 && !n->h264) ||
        (cfg->codec != NVC_CODEC_H264 && cfg->codec != NVC_CODEC_HEVC))
        return NV_ENC_ERR_UNSUPPORTED_PARAM;

    if (n->initialized) {
        unregister_all(n);
        if (n->bitstream) n->fn.nvEncDestroyBitstreamBuffer(n->enc, n->bitstream);
        n->bitstream = NULL;
        n->fn.nvEncDestroyEncoder(n->enc);
        n->enc = NULL;
        n->initialized = 0;
        NVENCSTATUS s = open_session(n);
        if (s != NV_ENC_SUCCESS) {
            n->enc = NULL;
            return s;
        }
    }

    NV_ENC_PRESET_CONFIG pc;
    memset(&pc, 0, sizeof pc);
    pc.version = NV_ENC_PRESET_CONFIG_VER;
    pc.presetCfg.version = NV_ENC_CONFIG_VER;
    NVENCSTATUS s = n->fn.nvEncGetEncodePresetConfigEx(n->enc, *codec, NV_ENC_PRESET_P1_GUID,
                                                        NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc);
    if (s != NV_ENC_SUCCESS) return s;
    n->config = pc.presetCfg;
    NV_ENC_CONFIG *c = &n->config;
    c->gopLength = NVENC_INFINITE_GOPLENGTH;
    c->frameIntervalP = 1; /* no B-frames */
    c->rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
    c->rcParams.averageBitRate = (uint32_t)cfg->bitrate_bps;
    c->rcParams.maxBitRate = (uint32_t)cfg->bitrate_bps;
    c->rcParams.vbvBufferSize = (uint32_t)(cfg->bitrate_bps / cfg->fps);
    c->rcParams.vbvInitialDelay = c->rcParams.vbvBufferSize;
    c->rcParams.enableLookahead = 0;
    const int ltr = cfg->ltr && n->ltr_supported;
    const uint32_t slices = cfg->slices ? cfg->slices : 1;
    if (cfg->codec == NVC_CODEC_HEVC) {
        NV_ENC_CONFIG_HEVC *h = &c->encodeCodecConfig.hevcConfig;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1;
        h->sliceMode = 3;
        h->sliceModeData = slices;
        h->enableLTR = ltr;
        h->ltrNumFrames = ltr ? NVC_LTR_SLOTS : 0;
        h->ltrTrustMode = 0;
        h->enableIntraRefresh = 0;
    } else {
        NV_ENC_CONFIG_H264 *h = &c->encodeCodecConfig.h264Config;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1;
        h->sliceMode = 3;
        h->sliceModeData = slices;
        h->enableLTR = ltr;
        h->ltrNumFrames = ltr ? NVC_LTR_SLOTS : 0;
        h->ltrTrustMode = 0;
        h->enableIntraRefresh = 0;
    }

    memset(&n->init, 0, sizeof n->init);
    n->init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    n->init.encodeGUID = *codec;
    n->init.presetGUID = NV_ENC_PRESET_P1_GUID;
    n->init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    n->init.encodeWidth = n->init.darWidth = n->init.maxEncodeWidth = cfg->width;
    n->init.encodeHeight = n->init.darHeight = n->init.maxEncodeHeight = cfg->height;
    n->init.frameRateNum = cfg->fps;
    n->init.frameRateDen = 1;
    n->init.enablePTD = 1;
    n->init.enableEncodeAsync = 0;
    n->init.encodeConfig = &n->config;
    s = n->fn.nvEncInitializeEncoder(n->enc, &n->init);
    if (s != NV_ENC_SUCCESS) return s;
    n->initialized = 1;
    n->cfg = *cfg;

    NV_ENC_CREATE_BITSTREAM_BUFFER bb;
    memset(&bb, 0, sizeof bb);
    bb.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    s = n->fn.nvEncCreateBitstreamBuffer(n->enc, &bb);
    if (s != NV_ENC_SUCCESS) return s;
    n->bitstream = bb.bitstreamBuffer;
    n->frame = 0;
    n->since_mark = 0;
    memset(n->ltr, 0, sizeof n->ltr);
    return NV_ENC_SUCCESS;
}

NVENCSTATUS nvc_register(nvc *n, NV_ENC_INPUT_RESOURCE_TYPE type, void *resource, uint32_t index, uint32_t pitch,
                         NV_ENC_BUFFER_FORMAT format, NV_ENC_REGISTERED_PTR *out) {
    int victim = 0;
    for (int i = 0; i < NVC_MAX_REGS; i++) {
        if (n->regs[i].reg && n->regs[i].resource == resource && n->regs[i].index == index) {
            n->regs[i].last_use = n->frame;
            *out = n->regs[i].reg;
            return NV_ENC_SUCCESS;
        }
        if (!n->regs[i].reg || n->regs[i].last_use < n->regs[victim].last_use) victim = i;
        if (!n->regs[victim].reg) break;
    }
    if (n->regs[victim].reg) n->fn.nvEncUnregisterResource(n->enc, n->regs[victim].reg);
    memset(&n->regs[victim], 0, sizeof n->regs[victim]);
    NV_ENC_REGISTER_RESOURCE r;
    memset(&r, 0, sizeof r);
    r.version = NV_ENC_REGISTER_RESOURCE_VER;
    r.resourceType = type;
    r.width = n->cfg.width;
    r.height = n->cfg.height;
    r.pitch = pitch;
    r.subResourceIndex = index;
    r.resourceToRegister = resource;
    r.bufferFormat = format;
    r.bufferUsage = NV_ENC_INPUT_IMAGE;
    NVENCSTATUS s = n->fn.nvEncRegisterResource(n->enc, &r);
    if (s != NV_ENC_SUCCESS) return s;
    n->regs[victim].resource = resource;
    n->regs[victim].index = index;
    n->regs[victim].reg = r.registeredResource;
    n->regs[victim].last_use = n->frame;
    *out = r.registeredResource;
    return NV_ENC_SUCCESS;
}

void nvc_forget(nvc *n, void *resource) {
    for (int i = 0; i < NVC_MAX_REGS; i++)
        if (n->regs[i].reg && n->regs[i].resource == resource) {
            n->fn.nvEncUnregisterResource(n->enc, n->regs[i].reg);
            memset(&n->regs[i], 0, sizeof n->regs[i]);
        }
}

NVENCSTATUS nvc_encode(nvc *n, NV_ENC_REGISTERED_PTR reg, uint64_t time_us, const nvc_params *p, nvc_append_fn append,
                       void *ctx, nvc_output *out) {
    memset(out, 0, sizeof *out);
    NVENCSTATUS s;
    const int hevc = n->cfg.codec == NVC_CODEC_HEVC;
    const int ltr = n->cfg.ltr && n->ltr_supported;

    if (p->bitrate_bps && p->bitrate_bps != n->config.rcParams.averageBitRate) {
        n->config.rcParams.averageBitRate = (uint32_t)p->bitrate_bps;
        n->config.rcParams.maxBitRate = (uint32_t)p->bitrate_bps;
        n->config.rcParams.vbvBufferSize = (uint32_t)(p->bitrate_bps / n->cfg.fps);
        n->config.rcParams.vbvInitialDelay = n->config.rcParams.vbvBufferSize;
        NV_ENC_RECONFIGURE_PARAMS rp;
        memset(&rp, 0, sizeof rp);
        rp.version = NV_ENC_RECONFIGURE_PARAMS_VER;
        rp.reInitEncodeParams = n->init;
        rp.reInitEncodeParams.encodeConfig = &n->config;
        rp.resetEncoder = 0;
        rp.forceIDR = 0;
        s = n->fn.nvEncReconfigureEncoder(n->enc, &rp);
        if (s != NV_ENC_SUCCESS) return s;
    }
    for (uint32_t i = 0; i < p->acked_ltr_count; i++)
        for (int k = 0; k < NVC_LTR_SLOTS; k++)
            if (n->ltr[k].token && n->ltr[k].token == p->acked_ltr_tokens[i]) n->ltr[k].acked = 1;

    NV_ENC_MAP_INPUT_RESOURCE map;
    memset(&map, 0, sizeof map);
    map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
    map.registeredResource = reg;
    s = n->fn.nvEncMapInputResource(n->enc, &map);
    if (s != NV_ENC_SUCCESS) return s;

    NV_ENC_PIC_PARAMS pp;
    memset(&pp, 0, sizeof pp);
    pp.version = NV_ENC_PIC_PARAMS_VER;
    pp.inputWidth = n->cfg.width;
    pp.inputHeight = n->cfg.height;
    pp.inputBuffer = map.mappedResource;
    pp.bufferFmt = map.mappedBufferFmt;
    pp.outputBitstream = n->bitstream;
    pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
    pp.inputTimeStamp = time_us;
    pp.frameIdx = (uint32_t)n->frame;

    uint32_t force = p->force;
    int use_slot = -1;
    if (force == NVC_FORCE_LTR_REFRESH) {
        uint64_t best = 0;
        for (int k = 0; k < NVC_LTR_SLOTS; k++)
            if (n->ltr[k].acked && n->ltr[k].token > best) {
                best = n->ltr[k].token;
                use_slot = k;
            }
        if (!ltr || use_slot < 0) force = NVC_FORCE_IDR;
    }
    const int idr = force == NVC_FORCE_IDR || n->frame == 0;
    if (idr) {
        pp.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
        memset(n->ltr, 0, sizeof n->ltr); /* an IDR empties the DPB */
        use_slot = -1;
    }
    /* Mark this frame a long-term reference on IDRs, refreshes and every NVC_LTR_INTERVAL
     * frames, into the slot that is not the newest acked one. */
    int mark_slot = -1;
    if (ltr && (idr || use_slot >= 0 || n->since_mark + 1 >= NVC_LTR_INTERVAL)) {
        int keep = -1;
        uint64_t best = 0;
        for (int k = 0; k < NVC_LTR_SLOTS; k++)
            if (n->ltr[k].acked && n->ltr[k].token > best) {
                best = n->ltr[k].token;
                keep = k;
            }
        mark_slot = 0;
        for (int k = 0; k < NVC_LTR_SLOTS; k++) {
            if (k == keep) continue;
            if (mark_slot == keep || n->ltr[k].token < n->ltr[mark_slot].token) mark_slot = k;
        }
        if (mark_slot == keep) mark_slot = -1;
    }
    if (hevc) {
        NV_ENC_PIC_PARAMS_HEVC *h = &pp.codecPicParams.hevcPicParams;
        if (mark_slot >= 0) {
            h->ltrMarkFrame = 1;
            h->ltrMarkFrameIdx = (uint32_t)mark_slot;
        }
        if (use_slot >= 0) {
            h->ltrUseFrames = 1;
            h->ltrUseFrameBitmap = 1u << use_slot;
        }
    } else {
        NV_ENC_PIC_PARAMS_H264 *h = &pp.codecPicParams.h264PicParams;
        if (mark_slot >= 0) {
            h->ltrMarkFrame = 1;
            h->ltrMarkFrameIdx = (uint32_t)mark_slot;
        }
        if (use_slot >= 0) {
            h->ltrUseFrames = 1;
            h->ltrUseFrameBitmap = 1u << use_slot;
        }
    }

    NVENCSTATUS st = n->fn.nvEncEncodePicture(n->enc, &pp);
    if (st == NV_ENC_SUCCESS) {
        NV_ENC_LOCK_BITSTREAM lb;
        memset(&lb, 0, sizeof lb);
        lb.version = NV_ENC_LOCK_BITSTREAM_VER;
        lb.outputBitstream = n->bitstream;
        s = n->fn.nvEncLockBitstream(n->enc, &lb);
        if (s == NV_ENC_SUCCESS) {
            if (append(ctx, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes)) s = NV_ENC_ERR_OUT_OF_MEMORY;
            out->keyframe = lb.pictureType == NV_ENC_PIC_TYPE_IDR;
            n->fn.nvEncUnlockBitstream(n->enc, n->bitstream);
        }
    } else if (st == NV_ENC_ERR_NEED_MORE_INPUT) {
        s = NV_ENC_SUCCESS; /* buffered: reported as a drop */
        out->dropped = 1;
    } else {
        s = st;
    }
    n->fn.nvEncUnmapInputResource(n->enc, map.mappedResource);
    if (s != NV_ENC_SUCCESS) return s;

    n->frame++;
    n->since_mark++;
    if (mark_slot >= 0) {
        n->ltr[mark_slot].token = n->frame; /* frame number, from 1 */
        n->ltr[mark_slot].acked = 0;
        n->since_mark = 0;
        out->has_ltr_token = 1;
        out->ltr_token = n->frame;
    }
    out->ltr_refresh = use_slot >= 0;
    return NV_ENC_SUCCESS;
}

void nvc_close(nvc *n) {
    if (n->enc) {
        unregister_all(n);
        if (n->bitstream) n->fn.nvEncDestroyBitstreamBuffer(n->enc, n->bitstream);
        n->fn.nvEncDestroyEncoder(n->enc);
    }
    n->enc = NULL;
    n->bitstream = NULL;
    n->initialized = 0;
}
