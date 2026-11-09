/* VAAPI encoder through libva, loaded at run time (dlopen libva.so.2 and libva-drm.so.2),
 * so the host starts on machines without it. libavcodec's VAAPI encoders don't expose
 * long-term references or per-frame reference control; libva leaves both to us.
 *
 * Settings: no B-frames, no lookahead, no periodic keyframes, CBR (VBR when the driver
 * has no CBR) with the HRD buffer one frame long, `slices` slices per frame. A bitrate
 * change sends new rate-control and HRD parameters with the next frame, without an IDR.
 *
 * References: the planner in h26x.c (refs_*) keeps two long-term slots, the previous
 * frame and the current one. When the driver takes packed sequence, picture and slice
 * headers, the parameter sets and slice headers are written by h26x.c, so long-term
 * marking (H.264 MMCO 4/6, HEVC long-term RPS entries) and reference list 0 are exactly
 * what the planner chose; Force.ltr_refresh then predicts from the newest acked
 * long-term reference instead of sending an IDR. Without packed headers the driver writes
 * its own, the encoder reports ltr = 0 and every recovery is an IDR.
 *
 * Input: NV12 directly; BGRA (from memory, or a dma-buf of XRGB8888/ARGB8888 imported
 * with VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2, no copy) is converted to NV12 by VA video
 * processing (BT.709, limited range) on the GPU.
 *
 * Hardware only: Mesa has no software VAAPI encoder, so CI tests the "not available" path
 * and the headers through testenc.c; enc_check (zig build linux-enc-check) runs it on a GPU. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_enc_h264.h>
#include <va/va_enc_hevc.h>
#include <va/va_vpp.h>

#include "enc_internal.h"
#include "h26x.h"

/* ---- libva, loaded at run time ------------------------------------------------ */

#define VA_FUNCS(X)                                                                                                    \
    X(vaInitialize) X(vaTerminate) X(vaErrorStr) X(vaQueryVendorString) X(vaMaxNumProfiles) X(vaMaxNumEntrypoints)    \
    X(vaQueryConfigProfiles) X(vaQueryConfigEntrypoints) X(vaGetConfigAttributes) X(vaCreateConfig)                    \
    X(vaDestroyConfig) X(vaCreateSurfaces) X(vaDestroySurfaces) X(vaCreateContext) X(vaDestroyContext)                 \
    X(vaCreateBuffer) X(vaDestroyBuffer) X(vaMapBuffer) X(vaUnmapBuffer) X(vaBeginPicture) X(vaRenderPicture)          \
    X(vaEndPicture) X(vaSyncSurface) X(vaDeriveImage) X(vaCreateImage) X(vaDestroyImage) X(vaPutImage)

typedef struct va_lib {
    void *va, *va_drm;
#define X(name) __typeof__(&name) name;
    VA_FUNCS(X)
#undef X
    __typeof__(&vaGetDisplayDRM) vaGetDisplayDRM;
    __typeof__(&vaSetInfoCallback) vaSetInfoCallback; /* optional */
} va_lib;

static int va_load(va_lib *l) {
    memset(l, 0, sizeof *l);
    l->va = dlopen("libva.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!l->va) return mlh_fail(MLH_E_NOTFOUND, "VAAPI: libva.so.2 not found (%s)", dlerror());
    l->va_drm = dlopen("libva-drm.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!l->va_drm) return mlh_fail(MLH_E_NOTFOUND, "VAAPI: libva-drm.so.2 not found (%s)", dlerror());
#define X(name)                                                                                                        \
    l->name = (__typeof__(&name))dlsym(l->va, #name);                                                                  \
    if (!l->name) return mlh_fail(MLH_E_NOTFOUND, "VAAPI: libva has no %s", #name);
    VA_FUNCS(X)
#undef X
    l->vaGetDisplayDRM = (__typeof__(&vaGetDisplayDRM))dlsym(l->va_drm, "vaGetDisplayDRM");
    if (!l->vaGetDisplayDRM) return mlh_fail(MLH_E_NOTFOUND, "VAAPI: libva-drm has no vaGetDisplayDRM");
    l->vaSetInfoCallback = (__typeof__(&vaSetInfoCallback))dlsym(l->va, "vaSetInfoCallback");
    return MLH_OK;
}

static void va_unload(va_lib *l) {
    if (l->va_drm) dlclose(l->va_drm);
    if (l->va) dlclose(l->va);
    memset(l, 0, sizeof *l);
}

/* ---- The encoder ------------------------------------------------------------------ */

#define DRM_FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define DRM_XRGB8888 DRM_FOURCC('X', 'R', '2', '4')
#define DRM_ARGB8888 DRM_FOURCC('A', 'R', '2', '4')
#define DRM_NV12 DRM_FOURCC('N', 'V', '1', '2')
#define DRM_MOD_INVALID 0x00ffffffffffffffull

#define IMPORT_CACHE 8
#define MAX_BUFFERS (16 + 3 * MLH_MAX_SLICES)

typedef struct codec_probe {
    int present;
    VAProfile profile;
    VAEntrypoint entrypoint;
    uint32_t rc;         /* VA_RC_CBR or VA_RC_VBR */
    uint32_t packed;     /* VA_ENC_PACKED_HEADER_* the driver takes */
    uint32_t max_slices;
    int ltr;             /* packed sequence, picture and slice headers: we own the references */
    uint32_t hevc_features, hevc_blocks;
    int have_features, have_blocks;
} codec_probe;

typedef struct imported {
    VASurfaceID surface;
    dev_t dev;
    ino_t ino;
    uint32_t offset, pitch, fourcc, width, height;
    uint64_t modifier;
    uint64_t last_use;
} imported;

typedef struct va_enc {
    mlh_enc base;
    va_lib lib;
    int fd;
    VADisplay dpy;
    char vendor[96];
    char node[64];
    codec_probe h264, hevc;
    int vpp;

    /* Session (configure). */
    const codec_probe *probe;
    VAConfigID config, vpp_config;
    VAContextID ctx, vpp_ctx;
    VASurfaceID recon[REFS_DPB];
    VASurfaceID input_nv12, input_bgra;
    VABufferID coded;
    int session;
    uint32_t aligned_w, aligned_h;
    uint32_t ctb; /* HEVC CTB size, or 16 for H.264 macroblocks */
    int ltr;
    refs_state refs;
    uint16_t idr_id;
    h264_params h264p;
    hevc_params hevcp;
    uint64_t bitrate;
    int rate_dirty;
    imported cache[IMPORT_CACHE];
    uint64_t frame;

    VABufferID bufs[MAX_BUFFERS];
    int nbufs;
} va_enc;

static int va_err(va_enc *v, VAStatus s, const char *what) {
    const char *msg = v->lib.vaErrorStr ? v->lib.vaErrorStr(s) : "?";
    int code = MLH_E_FAIL;
    switch (s) {
    case VA_STATUS_ERROR_ALLOCATION_FAILED: code = MLH_E_NOMEM; break;
    case VA_STATUS_ERROR_UNSUPPORTED_PROFILE:
    case VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT:
    case VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT:
    case VA_STATUS_ERROR_UNSUPPORTED_BUFFERTYPE:
    case VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED:
    case VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE:
    case VA_STATUS_ERROR_ATTR_NOT_SUPPORTED:
    case VA_STATUS_ERROR_INVALID_IMAGE_FORMAT: code = MLH_E_UNSUPPORTED; break;
    case VA_STATUS_ERROR_HW_BUSY:
    case VA_STATUS_ERROR_DECODING_ERROR:
    case VA_STATUS_ERROR_ENCODING_ERROR: code = MLH_E_CODEC; break;
    default: break;
    }
    return mlh_fail(code, "VAAPI %s: %s (0x%x)", what, msg, (unsigned)s);
}

#define VA_TRY(v, call, what)                                                                                          \
    do {                                                                                                               \
        VAStatus s_ = (call);                                                                                          \
        if (s_ != VA_STATUS_SUCCESS) return va_err((v), s_, (what));                                                   \
    } while (0)

static void info_quiet(void *ctx, const char *msg) {
    (void)ctx;
    (void)msg;
}

/* ---- Probing --------------------------------------------------------------------- */

static int has_entrypoint(va_enc *v, VAProfile profile, VAEntrypoint want) {
    int n = v->lib.vaMaxNumEntrypoints(v->dpy);
    if (n <= 0) return 0;
    VAEntrypoint *eps = calloc((size_t)n, sizeof *eps);
    if (!eps) return 0;
    int got = 0, found = 0;
    if (v->lib.vaQueryConfigEntrypoints(v->dpy, profile, eps, &got) == VA_STATUS_SUCCESS)
        for (int i = 0; i < got; i++)
            if (eps[i] == want) found = 1;
    free(eps);
    return found;
}

static int has_profile(va_enc *v, VAProfile want) {
    int n = v->lib.vaMaxNumProfiles(v->dpy);
    if (n <= 0) return 0;
    VAProfile *ps = calloc((size_t)n, sizeof *ps);
    if (!ps) return 0;
    int got = 0, found = 0;
    if (v->lib.vaQueryConfigProfiles(v->dpy, ps, &got) == VA_STATUS_SUCCESS)
        for (int i = 0; i < got; i++)
            if (ps[i] == want) found = 1;
    free(ps);
    return found;
}

static void probe_codec(va_enc *v, const VAProfile *profiles, int nprofiles, codec_probe *out) {
    memset(out, 0, sizeof *out);
    /* Full-featured VME first (more drivers take packed headers there), low-power second. */
    const VAEntrypoint eps[] = {VAEntrypointEncSlice, VAEntrypointEncSliceLP};
    for (int i = 0; i < nprofiles; i++) {
        if (!has_profile(v, profiles[i])) continue;
        for (int j = 0; j < 2; j++) {
            if (!has_entrypoint(v, profiles[i], eps[j])) continue;
            VAConfigAttrib a[7] = {
                {.type = VAConfigAttribRTFormat},         {.type = VAConfigAttribRateControl},
                {.type = VAConfigAttribEncPackedHeaders}, {.type = VAConfigAttribEncMaxSlices},
                {.type = VAConfigAttribEncMaxRefFrames},  {.type = VAConfigAttribEncHEVCFeatures},
                {.type = VAConfigAttribEncHEVCBlockSizes},
            };
            if (v->lib.vaGetConfigAttributes(v->dpy, profiles[i], eps[j], a, 7) != VA_STATUS_SUCCESS) continue;
            if (a[0].value == VA_ATTRIB_NOT_SUPPORTED || !(a[0].value & VA_RT_FORMAT_YUV420)) continue;
            uint32_t rc = 0;
            if (a[1].value != VA_ATTRIB_NOT_SUPPORTED) {
                if (a[1].value & VA_RC_CBR)
                    rc = VA_RC_CBR;
                else if (a[1].value & VA_RC_VBR)
                    rc = VA_RC_VBR;
            }
            if (!rc) continue;
            out->present = 1;
            out->profile = profiles[i];
            out->entrypoint = eps[j];
            out->rc = rc;
            out->packed = a[2].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : a[2].value;
            out->max_slices = a[3].value == VA_ATTRIB_NOT_SUPPORTED || a[3].value == 0 ? 1 : a[3].value;
            if (out->max_slices > MLH_MAX_SLICES) out->max_slices = MLH_MAX_SLICES;
            const uint32_t l0 = a[4].value == VA_ATTRIB_NOT_SUPPORTED ? 1 : (a[4].value & 0xFFFF);
            const uint32_t need = VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE;
            out->ltr = (out->packed & need) == need && l0 >= 1;
            out->have_features = a[5].value != VA_ATTRIB_NOT_SUPPORTED;
            out->hevc_features = a[5].value;
            out->have_blocks = a[6].value != VA_ATTRIB_NOT_SUPPORTED;
            out->hevc_blocks = a[6].value;
            return;
        }
    }
}

static int open_device(va_enc *v, const char *path) {
    v->fd = open(path, O_RDWR | O_CLOEXEC);
    if (v->fd < 0) return MLH_E_NOTFOUND;
    v->dpy = v->lib.vaGetDisplayDRM(v->fd);
    if (!v->dpy) goto fail;
    if (v->lib.vaSetInfoCallback) v->lib.vaSetInfoCallback(v->dpy, info_quiet, NULL);
    int major = 0, minor = 0;
    if (v->lib.vaInitialize(v->dpy, &major, &minor) != VA_STATUS_SUCCESS) goto fail;
    const VAProfile h264[] = {VAProfileH264High, VAProfileH264Main, VAProfileH264ConstrainedBaseline};
    const VAProfile hevc[] = {VAProfileHEVCMain};
    probe_codec(v, h264, 3, &v->h264);
    probe_codec(v, hevc, 1, &v->hevc);
    if (!v->h264.present && !v->hevc.present) {
        v->lib.vaTerminate(v->dpy);
        goto fail;
    }
    v->vpp = has_entrypoint(v, VAProfileNone, VAEntrypointVideoProc);
    const char *vendor = v->lib.vaQueryVendorString(v->dpy);
    snprintf(v->vendor, sizeof v->vendor, "%s", vendor ? vendor : "unknown driver");
    snprintf(v->node, sizeof v->node, "%s", path);
    return MLH_OK;
fail:
    v->dpy = NULL;
    close(v->fd);
    v->fd = -1;
    return MLH_E_NOTFOUND;
}

/* ---- Session ------------------------------------------------------------------- */

static void free_frame_buffers(va_enc *v) {
    for (int i = 0; i < v->nbufs; i++) v->lib.vaDestroyBuffer(v->dpy, v->bufs[i]);
    v->nbufs = 0;
}

static void clear_cache(va_enc *v) {
    for (int i = 0; i < IMPORT_CACHE; i++)
        if (v->cache[i].surface != VA_INVALID_SURFACE && v->cache[i].surface != 0)
            v->lib.vaDestroySurfaces(v->dpy, &v->cache[i].surface, 1);
    memset(v->cache, 0, sizeof v->cache);
}

static void close_session(va_enc *v) {
    if (!v->session) return;
    free_frame_buffers(v);
    clear_cache(v);
    if (v->coded != VA_INVALID_ID) v->lib.vaDestroyBuffer(v->dpy, v->coded);
    if (v->vpp_ctx != VA_INVALID_ID) v->lib.vaDestroyContext(v->dpy, v->vpp_ctx);
    if (v->vpp_config != VA_INVALID_ID) v->lib.vaDestroyConfig(v->dpy, v->vpp_config);
    if (v->ctx != VA_INVALID_ID) v->lib.vaDestroyContext(v->dpy, v->ctx);
    if (v->config != VA_INVALID_ID) v->lib.vaDestroyConfig(v->dpy, v->config);
    for (int i = 0; i < REFS_DPB; i++)
        if (v->recon[i] != VA_INVALID_SURFACE) v->lib.vaDestroySurfaces(v->dpy, &v->recon[i], 1);
    if (v->input_nv12 != VA_INVALID_SURFACE) v->lib.vaDestroySurfaces(v->dpy, &v->input_nv12, 1);
    if (v->input_bgra != VA_INVALID_SURFACE) v->lib.vaDestroySurfaces(v->dpy, &v->input_bgra, 1);
    v->session = 0;
}

static void reset_ids(va_enc *v) {
    v->config = v->vpp_config = VA_INVALID_ID;
    v->ctx = v->vpp_ctx = VA_INVALID_ID;
    v->coded = VA_INVALID_ID;
    v->input_nv12 = v->input_bgra = VA_INVALID_SURFACE;
    for (int i = 0; i < REFS_DPB; i++) v->recon[i] = VA_INVALID_SURFACE;
}

static const codec_probe *probe_for(const va_enc *v, uint32_t codec) {
    if (codec == MLH_CODEC_H264 && v->h264.present) return &v->h264;
    if (codec == MLH_CODEC_HEVC && v->hevc.present) return &v->hevc;
    return NULL;
}

static void va_caps(const mlh_enc *e, mlh_enc_caps *out) {
    const va_enc *v = (const va_enc *)e;
    out->h264 = (uint32_t)v->h264.present;
    out->hevc = (uint32_t)v->hevc.present;
    /* Long-term references for the configured codec, else for the first one we have. */
    const codec_probe *p = v->session ? v->probe : (v->h264.present ? &v->h264 : &v->hevc);
    out->ltr = (uint32_t)p->ltr;
    out->max_slices = p->max_slices;
    out->gpu_input = 1;
    out->cpu_input = 1;
    out->nv12_input = 1;
}

static uint32_t align_up(uint32_t v, uint32_t a) { return (v + a - 1) / a * a; }

static void hevc_block_params(const codec_probe *p, hevc_params *h) {
    h->log2_ctb = 5;
    h->log2_min_cb = 3;
    h->log2_min_tb = 2;
    h->log2_max_tb = 5;
    h->max_transform_hierarchy_depth = 3;
    if (p->have_blocks) {
        VAConfigAttribValEncHEVCBlockSizes b = {.value = p->hevc_blocks};
        h->log2_ctb = (uint8_t)(b.bits.log2_max_coding_tree_block_size_minus3 + 3);
        h->log2_min_cb = (uint8_t)(b.bits.log2_min_luma_coding_block_size_minus3 + 3);
        h->log2_min_tb = (uint8_t)(b.bits.log2_min_luma_transform_block_size_minus2 + 2);
        h->log2_max_tb = (uint8_t)(b.bits.log2_max_luma_transform_block_size_minus2 + 2);
        uint8_t inter = (uint8_t)b.bits.max_max_transform_hierarchy_depth_inter;
        uint8_t intra = (uint8_t)b.bits.max_max_transform_hierarchy_depth_intra;
        h->max_transform_hierarchy_depth = inter < intra ? inter : intra;
    }
    /* Features: turn on what the driver requires (2), leave off the rest. */
    h->cu_qp_delta = p->rc != VA_RC_CQP; /* drivers' rate control adjusts QP per CU */
    if (p->have_features) {
        VAConfigAttribValEncHEVCFeatures f = {.value = p->hevc_features};
        h->amp = f.bits.amp == 2;
        h->sao = f.bits.sao == 2;
        h->temporal_mvp = f.bits.temporal_mvp == 2;
        h->strong_intra_smoothing = f.bits.strong_intra_smoothing == 2;
        h->sign_data_hiding = f.bits.sign_data_hiding == 2;
        h->transform_skip = f.bits.transform_skip == 2;
        if (f.bits.cu_qp_delta == 0) h->cu_qp_delta = 0;
    }
}

static int va_configure(mlh_enc *e, const mlh_enc_config *cfg) {
    va_enc *v = (va_enc *)e;
    const codec_probe *p = probe_for(v, cfg->codec);
    if (!p) return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: %s has no encoder for codec %u", v->vendor, cfg->codec);
    if (cfg->slices > p->max_slices)
        return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: %u slices, driver takes %u", cfg->slices, p->max_slices);
    close_session(v);
    reset_ids(v);
    v->session = 1;
    v->probe = p;
    v->ltr = cfg->ltr && p->ltr;
    const int hevc = cfg->codec == MLH_CODEC_HEVC;

    if (hevc) {
        memset(&v->hevcp, 0, sizeof v->hevcp);
        hevc_block_params(p, &v->hevcp);
        v->ctb = 1u << v->hevcp.log2_ctb;
        v->hevcp.width = cfg->width;
        v->hevcp.height = cfg->height;
        v->hevcp.level_idc = 153; /* 5.1: up to 4096x2176 at 60 */
        v->hevcp.max_dec_pic_buffering = REFS_DPB;
        v->hevcp.init_qp = 26;
        v->hevcp.loop_filter_across_slices = 1;
        v->hevcp.fps = cfg->fps;
        v->aligned_w = align_up(cfg->width, 1u << v->hevcp.log2_min_cb);
        v->aligned_h = align_up(cfg->height, 1u << v->hevcp.log2_min_cb);
    } else {
        v->ctb = 16;
        v->h264p = (h264_params){
            .width = cfg->width,
            .height = cfg->height,
            .profile_idc = p->profile == VAProfileH264High ? 100 : p->profile == VAProfileH264Main ? 77 : 66,
            .level_idc = 51,
            .cabac = p->profile != VAProfileH264ConstrainedBaseline,
            .transform_8x8 = p->profile == VAProfileH264High,
            .max_num_ref_frames = v->ltr ? REFS_SLOTS + 1 : 1,
            .pic_init_qp = 26,
            .fps = cfg->fps,
        };
        v->aligned_w = align_up(cfg->width, 16);
        v->aligned_h = align_up(cfg->height, 16);
    }

    VAConfigAttrib attrs[3] = {
        {.type = VAConfigAttribRTFormat, .value = VA_RT_FORMAT_YUV420},
        {.type = VAConfigAttribRateControl, .value = p->rc},
        {.type = VAConfigAttribEncPackedHeaders,
         .value = v->ltr ? (VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE)
                         : VA_ENC_PACKED_HEADER_NONE},
    };
    const int nattrs = p->packed ? 3 : 2;
    VA_TRY(v, v->lib.vaCreateConfig(v->dpy, p->profile, p->entrypoint, attrs, nattrs, &v->config), "create config");
    VA_TRY(v, v->lib.vaCreateSurfaces(v->dpy, VA_RT_FORMAT_YUV420, v->aligned_w, v->aligned_h, v->recon, REFS_DPB, NULL, 0),
           "create reference surfaces");
    VA_TRY(v, v->lib.vaCreateSurfaces(v->dpy, VA_RT_FORMAT_YUV420, v->aligned_w, v->aligned_h, &v->input_nv12, 1, NULL, 0),
           "create input surface");
    VA_TRY(v, v->lib.vaCreateContext(v->dpy, v->config, (int)v->aligned_w, (int)v->aligned_h, VA_PROGRESSIVE, v->recon,
                                     REFS_DPB, &v->ctx),
           "create context");
    const unsigned coded_size = v->aligned_w * v->aligned_h * 3 / 2 + 64 * 1024;
    VA_TRY(v, v->lib.vaCreateBuffer(v->dpy, v->ctx, VAEncCodedBufferType, coded_size, 1, NULL, &v->coded),
           "create coded buffer");
    if (v->vpp) {
        VASurfaceAttrib fmt = {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                               .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_BGRX}};
        VA_TRY(v, v->lib.vaCreateSurfaces(v->dpy, VA_RT_FORMAT_RGB32, cfg->width, cfg->height, &v->input_bgra, 1, &fmt, 1),
               "create BGRA surface");
        VA_TRY(v, v->lib.vaCreateConfig(v->dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &v->vpp_config),
               "create VPP config");
        VA_TRY(v, v->lib.vaCreateContext(v->dpy, v->vpp_config, (int)v->aligned_w, (int)v->aligned_h, VA_PROGRESSIVE,
                                         &v->input_nv12, 1, &v->vpp_ctx),
               "create VPP context");
    }
    refs_reset(&v->refs, v->ltr);
    v->idr_id = 0;
    v->bitrate = cfg->bitrate_bps;
    v->rate_dirty = 1;
    v->frame = 0;
    snprintf(v->base.describe, sizeof v->base.describe, "VAAPI %s (%s, %s%s%s)", v->vendor, v->node,
             hevc ? "HEVC" : "H.264", p->entrypoint == VAEntrypointEncSliceLP ? " low-power" : "",
             v->ltr ? ", long-term references" : ", IDR recovery");
    return MLH_OK;
}

/* ---- Input ----------------------------------------------------------------------- */

static int import_dmabuf(va_enc *v, const mlh_dmabuf *d, VASurfaceID *out) {
    struct stat st;
    if (fstat(d->fd[0], &st) != 0) return mlh_fail(MLH_E_FAIL, "VAAPI: dma-buf fd %d: bad descriptor", d->fd[0]);
    int victim = 0;
    for (int i = 0; i < IMPORT_CACHE; i++) {
        imported *c = &v->cache[i];
        if (c->surface && c->dev == st.st_dev && c->ino == st.st_ino && c->offset == d->offset[0] &&
            c->pitch == d->pitch[0] && c->fourcc == d->fourcc && c->modifier == d->modifier && c->width == d->width &&
            c->height == d->height) {
            c->last_use = v->frame;
            *out = c->surface;
            return MLH_OK;
        }
        if (!c->surface || c->last_use < v->cache[victim].last_use) victim = i;
        if (!v->cache[victim].surface) break;
    }
    VADRMPRIMESurfaceDescriptor desc;
    memset(&desc, 0, sizeof desc);
    uint32_t rt;
    if (d->fourcc == DRM_XRGB8888 || d->fourcc == DRM_ARGB8888) {
        desc.fourcc = d->fourcc == DRM_XRGB8888 ? VA_FOURCC_BGRX : VA_FOURCC_BGRA;
        rt = VA_RT_FORMAT_RGB32;
    } else if (d->fourcc == DRM_NV12) {
        desc.fourcc = VA_FOURCC_NV12;
        rt = VA_RT_FORMAT_YUV420;
    } else {
        return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: dma-buf format 0x%08x", d->fourcc);
    }
    desc.width = d->width;
    desc.height = d->height;
    /* One object per distinct fd. */
    uint32_t obj_of[4];
    for (uint32_t pl = 0; pl < d->num_planes && pl < 4; pl++) {
        uint32_t o = 0;
        while (o < desc.num_objects && desc.objects[o].fd != d->fd[pl]) o++;
        if (o == desc.num_objects) {
            off_t size = lseek(d->fd[pl], 0, SEEK_END);
            desc.objects[o].fd = d->fd[pl];
            desc.objects[o].size = size > 0 ? (uint32_t)size : 0;
            desc.objects[o].drm_format_modifier = d->modifier == DRM_MOD_INVALID ? 0 : d->modifier;
            desc.num_objects++;
        }
        obj_of[pl] = o;
    }
    desc.num_layers = 1;
    desc.layers[0].drm_format = d->fourcc;
    desc.layers[0].num_planes = d->num_planes;
    for (uint32_t pl = 0; pl < d->num_planes && pl < 4; pl++) {
        desc.layers[0].object_index[pl] = obj_of[pl];
        desc.layers[0].offset[pl] = d->offset[pl];
        desc.layers[0].pitch[pl] = d->pitch[pl];
    }
    VASurfaceAttrib attrs[2] = {
        {.type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2}},
        {.type = VASurfaceAttribExternalBufferDescriptor, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypePointer, .value.p = &desc}},
    };
    VASurfaceID s;
    VA_TRY(v, v->lib.vaCreateSurfaces(v->dpy, rt, d->width, d->height, &s, 1, attrs, 2), "import dma-buf");
    imported *c = &v->cache[victim];
    if (c->surface) v->lib.vaDestroySurfaces(v->dpy, &c->surface, 1);
    *c = (imported){.surface = s, .dev = st.st_dev, .ino = st.st_ino, .offset = d->offset[0], .pitch = d->pitch[0],
                    .fourcc = d->fourcc, .modifier = d->modifier, .width = d->width, .height = d->height,
                    .last_use = v->frame};
    *out = s;
    return MLH_OK;
}

/* Copies pixels into a surface through vaDeriveImage (or vaCreateImage + vaPutImage). */
static int upload(va_enc *v, VASurfaceID surface, const uint8_t *data, uint32_t stride, uint32_t format, uint32_t w,
                  uint32_t h) {
    VAImage img;
    int derived = v->lib.vaDeriveImage(v->dpy, surface, &img) == VA_STATUS_SUCCESS;
    if (!derived) {
        VAImageFormat f = {0};
        if (format == MLH_FMT_BGRA) {
            f.fourcc = VA_FOURCC_BGRX;
            f.byte_order = VA_LSB_FIRST;
            f.bits_per_pixel = 32;
            f.depth = 24;
            f.red_mask = 0xff0000;
            f.green_mask = 0xff00;
            f.blue_mask = 0xff;
        } else {
            f.fourcc = VA_FOURCC_NV12;
            f.byte_order = VA_LSB_FIRST;
            f.bits_per_pixel = 12;
        }
        VA_TRY(v, v->lib.vaCreateImage(v->dpy, &f, (int)w, (int)h, &img), "create image");
    }
    void *map = NULL;
    VAStatus s = v->lib.vaMapBuffer(v->dpy, img.buf, &map);
    if (s != VA_STATUS_SUCCESS) {
        v->lib.vaDestroyImage(v->dpy, img.image_id);
        return va_err(v, s, "map image");
    }
    uint8_t *dst = map;
    const uint32_t row = format == MLH_FMT_BGRA ? w * 4 : w;
    for (uint32_t r = 0; r < h; r++) memcpy(dst + img.offsets[0] + (size_t)r * img.pitches[0], data + (size_t)r * stride, row);
    if (format == MLH_FMT_NV12) {
        const uint8_t *uv = data + (size_t)h * stride;
        for (uint32_t r = 0; r < h / 2; r++)
            memcpy(dst + img.offsets[1] + (size_t)r * img.pitches[1], uv + (size_t)r * stride, w);
    }
    v->lib.vaUnmapBuffer(v->dpy, img.buf);
    if (!derived) {
        s = v->lib.vaPutImage(v->dpy, surface, img.image_id, 0, 0, w, h, 0, 0, w, h);
        v->lib.vaDestroyImage(v->dpy, img.image_id);
        if (s != VA_STATUS_SUCCESS) return va_err(v, s, "put image");
    } else {
        v->lib.vaDestroyImage(v->dpy, img.image_id);
    }
    return MLH_OK;
}

/* RGB surface to the NV12 input surface (BT.709, limited range). */
static int convert(va_enc *v, VASurfaceID rgb, uint32_t w, uint32_t h) {
    if (!v->vpp) return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: %s has no video processing; give it NV12", v->vendor);
    VAProcPipelineParameterBuffer pp;
    memset(&pp, 0, sizeof pp);
    VARectangle src = {0, 0, (uint16_t)w, (uint16_t)h}, dst = {0, 0, (uint16_t)w, (uint16_t)h};
    pp.surface = rgb;
    pp.surface_region = &src;
    pp.surface_color_standard = VAProcColorStandardSRGB;
    pp.output_region = &dst;
    pp.output_background_color = 0xff000000;
    pp.output_color_standard = VAProcColorStandardBT709;
    pp.input_color_properties.color_range = VA_SOURCE_RANGE_FULL;
    pp.output_color_properties.color_range = VA_SOURCE_RANGE_REDUCED;
    VABufferID buf;
    VA_TRY(v, v->lib.vaCreateBuffer(v->dpy, v->vpp_ctx, VAProcPipelineParameterBufferType, sizeof pp, 1, &pp, &buf),
           "VPP parameters");
    VAStatus s = v->lib.vaBeginPicture(v->dpy, v->vpp_ctx, v->input_nv12);
    if (s == VA_STATUS_SUCCESS) s = v->lib.vaRenderPicture(v->dpy, v->vpp_ctx, &buf, 1);
    if (s == VA_STATUS_SUCCESS) s = v->lib.vaEndPicture(v->dpy, v->vpp_ctx);
    v->lib.vaDestroyBuffer(v->dpy, buf);
    if (s != VA_STATUS_SUCCESS) return va_err(v, s, "VPP");
    return MLH_OK;
}

static int prepare_input(va_enc *v, const mlh_enc_input *in, VASurfaceID *out) {
    const uint32_t w = v->base.cfg.width, h = v->base.cfg.height;
    if (in->dmabuf) {
        if (in->dmabuf->width != w || in->dmabuf->height != h)
            return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: frame %ux%u, configured %ux%u", in->dmabuf->width, in->dmabuf->height, w, h);
        VASurfaceID s;
        int rc = import_dmabuf(v, in->dmabuf, &s);
        if (rc) return rc;
        if (in->dmabuf->fourcc == DRM_NV12 && w == v->aligned_w && h == v->aligned_h) {
            *out = s;
            return MLH_OK;
        }
        if (in->dmabuf->fourcc == DRM_NV12)
            return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: NV12 dma-buf must be %ux%u", v->aligned_w, v->aligned_h);
        rc = convert(v, s, w, h);
        if (rc) return rc;
        *out = v->input_nv12;
        return MLH_OK;
    }
    if (in->width != w || in->height != h)
        return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: frame %ux%u, configured %ux%u", in->width, in->height, w, h);
    if (in->format == MLH_FMT_NV12) {
        int rc = upload(v, v->input_nv12, in->data, in->stride, MLH_FMT_NV12, w, h);
        if (rc) return rc;
    } else if (in->format == MLH_FMT_BGRA) {
        if (!v->vpp) return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: %s has no video processing; give it NV12", v->vendor);
        int rc = upload(v, v->input_bgra, in->data, in->stride, MLH_FMT_BGRA, w, h);
        if (rc) return rc;
        rc = convert(v, v->input_bgra, w, h);
        if (rc) return rc;
    } else {
        return mlh_fail(MLH_E_UNSUPPORTED, "VAAPI: pixel format %u", in->format);
    }
    *out = v->input_nv12;
    return MLH_OK;
}

/* ---- Parameter buffers ----------------------------------------------------------- */

static int add_buffer(va_enc *v, VABufferType type, unsigned size, const void *data) {
    if (v->nbufs >= MAX_BUFFERS) return mlh_fail(MLH_E_FAIL, "VAAPI: too many buffers");
    VA_TRY(v, v->lib.vaCreateBuffer(v->dpy, v->ctx, type, size, 1, (void *)data, &v->bufs[v->nbufs]), "create buffer");
    v->nbufs++;
    return MLH_OK;
}

static int add_packed(va_enc *v, uint32_t type, const uint8_t *data, size_t bits, int escaped) {
    VAEncPackedHeaderParameterBuffer ph = {.type = type, .bit_length = (uint32_t)bits, .has_emulation_bytes = (uint8_t)escaped};
    int rc = add_buffer(v, VAEncPackedHeaderParameterBufferType, sizeof ph, &ph);
    if (!rc) rc = add_buffer(v, VAEncPackedHeaderDataBufferType, (unsigned)((bits + 7) / 8), data);
    return rc;
}

static int add_misc(va_enc *v, VAEncMiscParameterType type, const void *payload, size_t size) {
    uint8_t buf[sizeof(VAEncMiscParameterBuffer) + 128];
    if (size > 128) return mlh_fail(MLH_E_FAIL, "VAAPI: misc parameter too large");
    memset(buf, 0, sizeof buf);
    VAEncMiscParameterBuffer *m = (VAEncMiscParameterBuffer *)buf;
    m->type = type;
    memcpy(m->data, payload, size);
    return add_buffer(v, VAEncMiscParameterBufferType, (unsigned)(sizeof *m + size), buf);
}

static int add_rate_control(va_enc *v) {
    const uint32_t fps = v->base.cfg.fps;
    const uint64_t bps = v->bitrate;
    VAEncMiscParameterRateControl rc;
    memset(&rc, 0, sizeof rc);
    rc.bits_per_second = (uint32_t)(bps > UINT32_MAX ? UINT32_MAX : bps);
    rc.target_percentage = 100;
    rc.window_size = 1000 / fps ? 1000 / fps : 1; /* ms: one frame */
    VAEncMiscParameterHRD hrd;
    memset(&hrd, 0, sizeof hrd);
    hrd.buffer_size = (uint32_t)(bps / fps); /* one frame */
    hrd.initial_buffer_fullness = hrd.buffer_size;
    VAEncMiscParameterFrameRate fr;
    memset(&fr, 0, sizeof fr);
    fr.framerate = fps | (1u << 16);
    int r = add_misc(v, VAEncMiscParameterTypeRateControl, &rc, sizeof rc);
    if (!r) r = add_misc(v, VAEncMiscParameterTypeHRD, &hrd, sizeof hrd);
    if (!r) r = add_misc(v, VAEncMiscParameterTypeFrameRate, &fr, sizeof fr);
    return r;
}

static uint32_t num_slices(const va_enc *v) {
    const uint32_t s = v->base.cfg.slices ? v->base.cfg.slices : 1;
    const uint32_t rows = (v->aligned_h + v->ctb - 1) / v->ctb;
    return s < rows ? s : rows;
}

/* Slice i covers rows [i * rows / n, (i + 1) * rows / n) of CTBs (macroblocks). */
static void slice_span(const va_enc *v, uint32_t i, uint32_t *first, uint32_t *count) {
    const uint32_t cols = (v->aligned_w + v->ctb - 1) / v->ctb, rows = (v->aligned_h + v->ctb - 1) / v->ctb;
    const uint32_t n = num_slices(v);
    const uint32_t r0 = i * rows / n, r1 = (i + 1) * rows / n;
    *first = r0 * cols;
    *count = (r1 - r0) * cols;
}

static VAPictureH264 h264_pic(const va_enc *v, const refs_pic *p) {
    VAPictureH264 r;
    memset(&r, 0, sizeof r);
    r.picture_id = v->recon[p->surface];
    r.frame_idx = p->lt_slot >= 0 ? (uint32_t)p->lt_slot : (p->count & ((1u << H264_LOG2_MAX_FRAME_NUM) - 1));
    r.flags = p->lt_slot >= 0 ? VA_PICTURE_H264_LONG_TERM_REFERENCE : VA_PICTURE_H264_SHORT_TERM_REFERENCE;
    r.TopFieldOrderCnt = r.BottomFieldOrderCnt = (int32_t)(2 * p->count);
    return r;
}

static void h264_invalid(VAPictureH264 *p) {
    memset(p, 0, sizeof *p);
    p->picture_id = VA_INVALID_SURFACE;
    p->flags = VA_PICTURE_H264_INVALID;
}

static int h264_buffers(va_enc *v, const refs_plan *plan) {
    const h264_params *hp = &v->h264p;
    const int packed = v->ltr;
    int rc;
    if (plan->idr) {
        VAEncSequenceParameterBufferH264 sp;
        memset(&sp, 0, sizeof sp);
        sp.level_idc = hp->level_idc;
        sp.intra_period = 0;
        sp.intra_idr_period = 0;
        sp.ip_period = 1;
        sp.bits_per_second = (uint32_t)v->bitrate;
        sp.max_num_ref_frames = hp->max_num_ref_frames;
        sp.picture_width_in_mbs = (uint16_t)(v->aligned_w / 16);
        sp.picture_height_in_mbs = (uint16_t)(v->aligned_h / 16);
        sp.seq_fields.bits.chroma_format_idc = 1;
        sp.seq_fields.bits.frame_mbs_only_flag = 1;
        sp.seq_fields.bits.direct_8x8_inference_flag = 1;
        sp.seq_fields.bits.log2_max_frame_num_minus4 = H264_LOG2_MAX_FRAME_NUM - 4;
        sp.seq_fields.bits.pic_order_cnt_type = 2;
        sp.seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = 12;
        const uint32_t crop_r = v->aligned_w - v->base.cfg.width, crop_b = v->aligned_h - v->base.cfg.height;
        if (crop_r || crop_b) {
            sp.frame_cropping_flag = 1;
            sp.frame_crop_right_offset = crop_r / 2;
            sp.frame_crop_bottom_offset = crop_b / 2;
        }
        sp.vui_parameters_present_flag = 1;
        sp.vui_fields.bits.timing_info_present_flag = 1;
        sp.vui_fields.bits.bitstream_restriction_flag = 1;
        sp.vui_fields.bits.log2_max_mv_length_horizontal = 15;
        sp.vui_fields.bits.log2_max_mv_length_vertical = 15;
        sp.num_units_in_tick = 1;
        sp.time_scale = 2 * v->base.cfg.fps;
        if ((rc = add_buffer(v, VAEncSequenceParameterBufferType, sizeof sp, &sp))) return rc;
    }
    if (plan->idr || v->rate_dirty) {
        if ((rc = add_rate_control(v))) return rc;
        v->rate_dirty = 0;
    }

    VAEncPictureParameterBufferH264 pp;
    memset(&pp, 0, sizeof pp);
    refs_pic cur = {.used = 1, .count = plan->count, .lt_slot = -1, .surface = (uint32_t)plan->cur};
    pp.CurrPic = h264_pic(v, &cur);
    pp.CurrPic.flags = 0;
    int nref = 0;
    for (int i = 0; i < 16; i++) h264_invalid(&pp.ReferenceFrames[i]);
    if (!plan->idr)
        for (int d = 0; d < REFS_DPB; d++)
            if (v->refs.dpb[d].used) pp.ReferenceFrames[nref++] = h264_pic(v, &v->refs.dpb[d]);
    pp.coded_buf = v->coded;
    pp.frame_num = (uint16_t)(plan->count & ((1u << H264_LOG2_MAX_FRAME_NUM) - 1));
    pp.pic_init_qp = (uint8_t)hp->pic_init_qp;
    pp.num_ref_idx_l0_active_minus1 = 0;
    pp.pic_fields.bits.idr_pic_flag = (uint32_t)plan->idr;
    pp.pic_fields.bits.reference_pic_flag = 1;
    pp.pic_fields.bits.entropy_coding_mode_flag = hp->cabac;
    pp.pic_fields.bits.transform_8x8_mode_flag = hp->transform_8x8;
    pp.pic_fields.bits.deblocking_filter_control_present_flag = 1;
    if ((rc = add_buffer(v, VAEncPictureParameterBufferType, sizeof pp, &pp))) return rc;

    if (packed && plan->idr) {
        uint8_t nal[512];
        size_t n = h264_write_sps(nal, sizeof nal, hp);
        if (!n) return mlh_fail(MLH_E_FAIL, "VAAPI: SPS");
        if ((rc = add_packed(v, VAEncPackedHeaderSequence, nal, n * 8, 1))) return rc;
        n = h264_write_pps(nal, sizeof nal, hp);
        if (!n) return mlh_fail(MLH_E_FAIL, "VAAPI: PPS");
        if ((rc = add_packed(v, VAEncPackedHeaderPicture, nal, n * 8, 1))) return rc;
    }

    h264_slice hs;
    h264_slice_from_plan(&hs, &v->refs, plan, v->idr_id);
    const uint32_t n = num_slices(v);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t first, count;
        slice_span(v, i, &first, &count);
        if (packed) {
            uint8_t hdr[256];
            h26x_bw w;
            h26x_bw_init(&w, hdr, sizeof hdr);
            hs.first_mb = first;
            const size_t bits = h264_write_slice_header(&w, hp, &hs);
            if (!bits) return mlh_fail(MLH_E_FAIL, "VAAPI: slice header");
            if ((rc = add_packed(v, VAEncPackedHeaderSlice, hdr, bits, 0))) return rc;
        }
        VAEncSliceParameterBufferH264 sl;
        memset(&sl, 0, sizeof sl);
        sl.macroblock_address = first;
        sl.num_macroblocks = count;
        sl.macroblock_info = VA_INVALID_ID;
        sl.slice_type = plan->idr ? 2 : 0;
        sl.idr_pic_id = v->idr_id;
        sl.num_ref_idx_active_override_flag = 1;
        sl.num_ref_idx_l0_active_minus1 = 0;
        for (int k = 0; k < 32; k++) {
            h264_invalid(&sl.RefPicList0[k]);
            h264_invalid(&sl.RefPicList1[k]);
        }
        if (!plan->idr) sl.RefPicList0[0] = h264_pic(v, &v->refs.dpb[plan->ref]);
        sl.slice_qp_delta = 0;
        sl.disable_deblocking_filter_idc = 0;
        if ((rc = add_buffer(v, VAEncSliceParameterBufferType, sizeof sl, &sl))) return rc;
    }
    return MLH_OK;
}

static VAPictureHEVC hevc_pic(const va_enc *v, const refs_pic *p, uint32_t flags) {
    VAPictureHEVC r;
    memset(&r, 0, sizeof r);
    r.picture_id = v->recon[p->surface];
    r.pic_order_cnt = (int32_t)p->count;
    r.flags = flags | (p->lt_slot >= 0 ? VA_PICTURE_HEVC_LONG_TERM_REFERENCE : 0);
    return r;
}

static void hevc_invalid(VAPictureHEVC *p) {
    memset(p, 0, sizeof *p);
    p->picture_id = VA_INVALID_SURFACE;
    p->flags = VA_PICTURE_HEVC_INVALID;
}

static int hevc_buffers(va_enc *v, const refs_plan *plan) {
    const hevc_params *hp = &v->hevcp;
    const int packed = v->ltr;
    int rc;
    if (plan->idr) {
        VAEncSequenceParameterBufferHEVC sp;
        memset(&sp, 0, sizeof sp);
        sp.general_profile_idc = 1;
        sp.general_level_idc = hp->level_idc;
        sp.general_tier_flag = 0;
        sp.intra_period = 0;
        sp.intra_idr_period = 0;
        sp.ip_period = 1;
        sp.bits_per_second = (uint32_t)v->bitrate;
        sp.pic_width_in_luma_samples = (uint16_t)v->aligned_w;
        sp.pic_height_in_luma_samples = (uint16_t)v->aligned_h;
        sp.seq_fields.bits.chroma_format_idc = 1;
        sp.seq_fields.bits.amp_enabled_flag = hp->amp;
        sp.seq_fields.bits.sample_adaptive_offset_enabled_flag = hp->sao;
        sp.seq_fields.bits.sps_temporal_mvp_enabled_flag = hp->temporal_mvp;
        sp.seq_fields.bits.strong_intra_smoothing_enabled_flag = hp->strong_intra_smoothing;
        sp.seq_fields.bits.low_delay_seq = 1;
        sp.log2_min_luma_coding_block_size_minus3 = (uint8_t)(hp->log2_min_cb - 3);
        sp.log2_diff_max_min_luma_coding_block_size = (uint8_t)(hp->log2_ctb - hp->log2_min_cb);
        sp.log2_min_transform_block_size_minus2 = (uint8_t)(hp->log2_min_tb - 2);
        sp.log2_diff_max_min_transform_block_size = (uint8_t)(hp->log2_max_tb - hp->log2_min_tb);
        sp.max_transform_hierarchy_depth_inter = hp->max_transform_hierarchy_depth;
        sp.max_transform_hierarchy_depth_intra = hp->max_transform_hierarchy_depth;
        sp.vui_parameters_present_flag = 1;
        sp.vui_fields.bits.vui_timing_info_present_flag = 1;
        sp.vui_fields.bits.bitstream_restriction_flag = 1;
        sp.vui_fields.bits.motion_vectors_over_pic_boundaries_flag = 1;
        sp.vui_fields.bits.restricted_ref_pic_lists_flag = 1;
        sp.vui_fields.bits.log2_max_mv_length_horizontal = 15;
        sp.vui_fields.bits.log2_max_mv_length_vertical = 15;
        sp.vui_num_units_in_tick = 1;
        sp.vui_time_scale = v->base.cfg.fps;
        if ((rc = add_buffer(v, VAEncSequenceParameterBufferType, sizeof sp, &sp))) return rc;
    }
    if (plan->idr || v->rate_dirty) {
        if ((rc = add_rate_control(v))) return rc;
        v->rate_dirty = 0;
    }

    hevc_slice hs;
    hevc_slice_from_plan(&hs, &v->refs, plan);
    hs.sao_luma = hs.sao_chroma = hp->sao;

    VAEncPictureParameterBufferHEVC pp;
    memset(&pp, 0, sizeof pp);
    refs_pic cur = {.used = 1, .count = plan->count, .lt_slot = -1, .surface = (uint32_t)plan->cur};
    pp.decoded_curr_pic = hevc_pic(v, &cur, 0);
    for (int i = 0; i < 15; i++) hevc_invalid(&pp.reference_frames[i]);
    int nref = 0;
    if (!plan->idr)
        for (int d = 0; d < REFS_DPB; d++) {
            const refs_pic *e = &v->refs.dpb[d];
            if (!e->used) continue;
            if (e->lt_slot < 0 && d != plan->ref) continue; /* left out of the RPS */
            uint32_t flags = 0;
            if (d == plan->ref) flags = e->lt_slot >= 0 ? VA_PICTURE_HEVC_RPS_LT_CURR : VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
            pp.reference_frames[nref++] = hevc_pic(v, e, flags);
        }
    pp.coded_buf = v->coded;
    pp.collocated_ref_pic_index = 0xFF;
    pp.pic_init_qp = (uint8_t)hp->init_qp;
    pp.nal_unit_type = plan->idr ? 19 : 1;
    pp.pic_fields.bits.idr_pic_flag = (uint32_t)plan->idr;
    pp.pic_fields.bits.coding_type = plan->idr ? 1 : 2;
    pp.pic_fields.bits.reference_pic_flag = 1;
    pp.pic_fields.bits.sign_data_hiding_enabled_flag = hp->sign_data_hiding;
    pp.pic_fields.bits.transform_skip_enabled_flag = hp->transform_skip;
    pp.pic_fields.bits.cu_qp_delta_enabled_flag = hp->cu_qp_delta;
    pp.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = hp->loop_filter_across_slices;
    if ((rc = add_buffer(v, VAEncPictureParameterBufferType, sizeof pp, &pp))) return rc;

    if (packed && plan->idr) {
        uint8_t nal[512];
        size_t n = hevc_write_vps(nal, sizeof nal, hp);
        if (!n) return mlh_fail(MLH_E_FAIL, "VAAPI: VPS");
        if ((rc = add_packed(v, VAEncPackedHeaderSequence, nal, n * 8, 1))) return rc;
        n = hevc_write_sps(nal, sizeof nal, hp);
        if (!n) return mlh_fail(MLH_E_FAIL, "VAAPI: SPS");
        if ((rc = add_packed(v, VAEncPackedHeaderSequence, nal, n * 8, 1))) return rc;
        n = hevc_write_pps(nal, sizeof nal, hp);
        if (!n) return mlh_fail(MLH_E_FAIL, "VAAPI: PPS");
        if ((rc = add_packed(v, VAEncPackedHeaderPicture, nal, n * 8, 1))) return rc;
    }

    const uint32_t ns = num_slices(v);
    for (uint32_t i = 0; i < ns; i++) {
        uint32_t first, count;
        slice_span(v, i, &first, &count);
        if (packed) {
            uint8_t hdr[256];
            h26x_bw w;
            h26x_bw_init(&w, hdr, sizeof hdr);
            hs.address = first;
            const size_t bits = hevc_write_slice_header(&w, hp, &hs);
            if (!bits) return mlh_fail(MLH_E_FAIL, "VAAPI: slice header");
            if ((rc = add_packed(v, VAEncPackedHeaderSlice, hdr, bits, 0))) return rc;
        }
        VAEncSliceParameterBufferHEVC sl;
        memset(&sl, 0, sizeof sl);
        sl.slice_segment_address = first;
        sl.num_ctu_in_slice = count;
        sl.slice_type = plan->idr ? 2 : 1;
        sl.num_ref_idx_l0_active_minus1 = 0;
        for (int k = 0; k < 15; k++) {
            hevc_invalid(&sl.ref_pic_list0[k]);
            hevc_invalid(&sl.ref_pic_list1[k]);
        }
        if (!plan->idr) {
            const refs_pic *r = &v->refs.dpb[plan->ref];
            sl.ref_pic_list0[0] = hevc_pic(v, r, r->lt_slot >= 0 ? VA_PICTURE_HEVC_RPS_LT_CURR : VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE);
        }
        sl.max_num_merge_cand = hs.max_merge_cand;
        sl.slice_fields.bits.last_slice_of_pic_flag = i + 1 == ns;
        sl.slice_fields.bits.slice_sao_luma_flag = hs.sao_luma;
        sl.slice_fields.bits.slice_sao_chroma_flag = hs.sao_chroma;
        sl.slice_fields.bits.num_ref_idx_active_override_flag = !plan->idr;
        sl.slice_fields.bits.slice_loop_filter_across_slices_enabled_flag = hp->loop_filter_across_slices;
        if ((rc = add_buffer(v, VAEncSliceParameterBufferType, sizeof sl, &sl))) return rc;
    }
    return MLH_OK;
}

/* ---- Encode ------------------------------------------------------------------------ */

static int va_encode(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p, mlh_enc_output *out) {
    va_enc *v = (va_enc *)e;
    (void)time_us;
    VASurfaceID src;
    int rc = prepare_input(v, in, &src);
    if (rc) return rc;
    if (p->bitrate_bps && p->bitrate_bps != v->bitrate) {
        v->bitrate = p->bitrate_bps;
        v->rate_dirty = 1;
    }
    refs_ack(&v->refs, p->acked_ltr_tokens, p->acked_ltr_count);
    refs_plan plan;
    refs_plan_frame(&v->refs, (int)p->force, &plan);

    free_frame_buffers(v);
    rc = e->cfg.codec == MLH_CODEC_HEVC ? hevc_buffers(v, &plan) : h264_buffers(v, &plan);
    if (rc) {
        free_frame_buffers(v);
        return rc;
    }
    VAStatus s = v->lib.vaBeginPicture(v->dpy, v->ctx, src);
    if (s == VA_STATUS_SUCCESS) s = v->lib.vaRenderPicture(v->dpy, v->ctx, v->bufs, v->nbufs);
    if (s == VA_STATUS_SUCCESS) s = v->lib.vaEndPicture(v->dpy, v->ctx);
    free_frame_buffers(v);
    if (s != VA_STATUS_SUCCESS) return va_err(v, s, "encode");
    VA_TRY(v, v->lib.vaSyncSurface(v->dpy, src), "sync");

    VACodedBufferSegment *seg = NULL;
    VA_TRY(v, v->lib.vaMapBuffer(v->dpy, v->coded, (void **)&seg), "map coded buffer");
    for (; seg && rc == MLH_OK; seg = (VACodedBufferSegment *)seg->next)
        if (seg->size) rc = mlh_enc_append(e, seg->buf, seg->size);
    v->lib.vaUnmapBuffer(v->dpy, v->coded);
    if (rc) return rc;
    v->frame++;
    if (e->out_len == 0) return MLH_OK; /* the driver skipped the frame: a drop, nothing committed */

    if (plan.idr) v->idr_id++;
    const uint64_t token = refs_commit(&v->refs, &plan);
    out->keyframe = (uint32_t)plan.idr;
    out->has_ltr_token = token != 0;
    out->ltr_token = token;
    out->ltr_refresh = (uint32_t)plan.refresh;
    return MLH_OK;
}

static void va_destroy(mlh_enc *e) {
    va_enc *v = (va_enc *)e;
    if (v->dpy) {
        close_session(v);
        v->lib.vaTerminate(v->dpy);
    }
    if (v->fd >= 0) close(v->fd);
    va_unload(&v->lib);
    free(v);
}

static const mlh_enc_ops va_ops = {va_caps, va_configure, va_encode, va_destroy};

int mlh_enc_vaapi_create(const char *device, mlh_enc **out) {
    va_enc *v = calloc(1, sizeof *v);
    if (!v) return MLH_E_NOMEM;
    v->base.ops = &va_ops;
    v->fd = -1;
    reset_ids(v);
    int rc = va_load(&v->lib);
    if (rc) goto fail;
    rc = MLH_E_NOTFOUND;
    if (device) {
        rc = open_device(v, device);
        if (rc) mlh_fail(rc, "VAAPI: %s: cannot open or has no H.264/HEVC encode entrypoint", device);
    } else {
        for (int i = 128; i < 136 && rc; i++) {
            char path[32];
            snprintf(path, sizeof path, "/dev/dri/renderD%d", i);
            rc = open_device(v, path);
        }
        if (rc) mlh_fail(rc, "VAAPI: no render node with an H.264/HEVC encode entrypoint");
    }
    if (rc) goto fail;
    snprintf(v->base.describe, sizeof v->base.describe, "VAAPI %s (%s)", v->vendor, v->node);
    *out = &v->base;
    return MLH_OK;
fail:
    va_destroy(&v->base);
    return rc;
}
