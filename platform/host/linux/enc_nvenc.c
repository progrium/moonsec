/* NVENC on Linux (see nvenc_linux.h): libnvidia-encode.so.1 and libcuda.so.1 loaded at
 * run time, a CUDA context as the encode device, CUDA device memory as input. The NVENC
 * session itself is platform/nvenc/nvenc_core.c, shared with the Windows host.
 *
 * Input:
 *   - a linear dma-buf is imported once with cuImportExternalMemory (an OPAQUE_FD handle;
 *     the NVIDIA driver takes the dma-bufs it exported itself, which is what a PipeWire
 *     producer on the NVIDIA GPU hands out) and mapped as a device pointer, cached by
 *     inode; XRGB8888/ARGB8888 go in as NV_ENC_BUFFER_FORMAT_ARGB (B, G, R, A in memory),
 *     NV12 as NV12. Tiled dma-bufs need the EGL/GL interop path and are refused for now.
 *   - pixels in memory are copied (cuMemcpy2D) into a pitched device buffer.
 *
 * Compile-only: no NVIDIA hardware is planned, so only the not-found path has run. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "nvenc_core.h"
#include "nvenc_linux.h"

/* ---- The CUDA driver API we use (cuda.h, declared here so the build needs no SDK) ---- */

typedef int CUresult;
typedef int CUdevice;
typedef struct CUctx_st *CUcontext;
typedef unsigned long long CUdeviceptr;
typedef struct CUextMemory_st *CUexternalMemory;

#define CUDA_SUCCESS 0
#define CU_MEMORYTYPE_HOST 1
#define CU_MEMORYTYPE_DEVICE 2
#define CU_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD 1

typedef struct CUDA_EXTERNAL_MEMORY_HANDLE_DESC {
    int type;
    union {
        int fd;
        struct {
            void *handle;
            const void *name;
        } win32;
        const void *nvSciBufObject;
    } handle;
    unsigned long long size;
    unsigned int flags;
    unsigned int reserved[16];
} CUDA_EXTERNAL_MEMORY_HANDLE_DESC;

typedef struct CUDA_EXTERNAL_MEMORY_BUFFER_DESC {
    unsigned long long offset;
    unsigned long long size;
    unsigned int flags;
    unsigned int reserved[16];
} CUDA_EXTERNAL_MEMORY_BUFFER_DESC;

typedef struct CUDA_MEMCPY2D {
    size_t srcXInBytes, srcY;
    int srcMemoryType;
    const void *srcHost;
    CUdeviceptr srcDevice;
    void *srcArray;
    size_t srcPitch;
    size_t dstXInBytes, dstY;
    int dstMemoryType;
    void *dstHost;
    CUdeviceptr dstDevice;
    void *dstArray;
    size_t dstPitch;
    size_t WidthInBytes, Height;
} CUDA_MEMCPY2D;

#define CU_FUNCS(X)                                                                                                    \
    X(cuInit, (unsigned int))                                                                              \
    X(cuDeviceGet, (CUdevice *, int))                                                                      \
    X(cuCtxCreate_v2, (CUcontext *, unsigned int, CUdevice))                                              \
    X(cuCtxDestroy_v2, (CUcontext))                                                                        \
    X(cuCtxPushCurrent_v2, (CUcontext))                                                                    \
    X(cuCtxPopCurrent_v2, (CUcontext *))                                                                   \
    X(cuMemAllocPitch_v2, (CUdeviceptr *, size_t *, size_t, size_t, unsigned int))                         \
    X(cuMemFree_v2, (CUdeviceptr))                                                                         \
    X(cuMemcpy2D_v2, (const CUDA_MEMCPY2D *))                                                              \
    X(cuImportExternalMemory, (CUexternalMemory *, const CUDA_EXTERNAL_MEMORY_HANDLE_DESC *))              \
    X(cuExternalMemoryGetMappedBuffer, (CUdeviceptr *, CUexternalMemory, const CUDA_EXTERNAL_MEMORY_BUFFER_DESC *)) \
    X(cuDestroyExternalMemory, (CUexternalMemory))                                                         \
    X(cuGetErrorString, (CUresult, const char **))

typedef struct cu_lib {
    void *so;
#define X(name, args) CUresult(*name) args;
    CU_FUNCS(X)
#undef X
} cu_lib;

/* ---- Errors -------------------------------------------------------------------------- */

static _Thread_local char last_error[512];

const char *mlh_nvenc_last_error(void) { return last_error; }

static int fail(int code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(last_error, sizeof last_error, fmt, ap);
    va_end(ap);
    fprintf(stderr, "host-linux: NVENC: %s\n", last_error);
    return code;
}

static int nv_code(NVENCSTATUS s) {
    switch (s) {
    case NV_ENC_SUCCESS: return MLH_NV_OK;
    case NV_ENC_ERR_NO_ENCODE_DEVICE:
    case NV_ENC_ERR_UNSUPPORTED_DEVICE:
    case NV_ENC_ERR_INVALID_ENCODERDEVICE: return MLH_NV_E_NOTFOUND;
    case NV_ENC_ERR_OUT_OF_MEMORY: return MLH_NV_E_NOMEM;
    case NV_ENC_ERR_DEVICE_NOT_EXIST: return MLH_NV_E_DEVICE_LOST;
    case NV_ENC_ERR_UNIMPLEMENTED:
    case NV_ENC_ERR_UNSUPPORTED_PARAM:
    case NV_ENC_ERR_INVALID_VERSION: return MLH_NV_E_UNSUPPORTED;
    default: return MLH_NV_E_CODEC;
    }
}

static int nv_fail(NVENCSTATUS s, const char *what) { return fail(nv_code(s), "%s: NVENCSTATUS %d", what, (int)s); }

/* ---- The encoder ----------------------------------------------------------------------- */

#define DRM_FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define DRM_XRGB8888 DRM_FOURCC('X', 'R', '2', '4')
#define DRM_ARGB8888 DRM_FOURCC('A', 'R', '2', '4')
#define DRM_NV12 DRM_FOURCC('N', 'V', '1', '2')
#define DRM_MOD_INVALID 0x00ffffffffffffffull
#define IMPORTS 4

typedef struct imported {
    CUexternalMemory mem;
    CUdeviceptr ptr;
    dev_t dev;
    ino_t ino;
    uint32_t offset, pitch, fourcc;
    uint64_t last_use;
} imported;

struct mlh_nvenc {
    void *nvenc_so;
    cu_lib cu;
    CUcontext ctx;
    nvc core;
    int opened;
    CUdeviceptr upload;
    size_t upload_pitch;
    uint32_t upload_nv12;
    imported imports[IMPORTS];
    uint64_t frame;
    uint8_t *out;
    size_t out_len, out_cap;
};

static int cu_check(mlh_nvenc *e, CUresult r, const char *what) {
    if (r == CUDA_SUCCESS) return MLH_NV_OK;
    const char *msg = NULL;
    if (e->cu.cuGetErrorString) e->cu.cuGetErrorString(r, &msg);
    return fail(MLH_NV_E_FAIL, "%s: CUDA error %d (%s)", what, r, msg ? msg : "?");
}

static int load(mlh_nvenc *e) {
    e->cu.so = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!e->cu.so) return fail(MLH_NV_E_NOTFOUND, "libcuda.so.1 not found (no NVIDIA driver)");
#define X(name, args)                                                                                                  \
    e->cu.name = (CUresult(*) args)dlsym(e->cu.so, #name);                                                                         \
    if (!e->cu.name) return fail(MLH_NV_E_NOTFOUND, "libcuda has no %s", #name);
    CU_FUNCS(X)
#undef X
    e->nvenc_so = dlopen("libnvidia-encode.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!e->nvenc_so) return fail(MLH_NV_E_NOTFOUND, "libnvidia-encode.so.1 not found");
    return MLH_NV_OK;
}

static void drop_import(mlh_nvenc *e, imported *im) {
    if (!im->mem) return;
    nvc_forget(&e->core, (void *)(uintptr_t)im->ptr);
    e->cu.cuDestroyExternalMemory(im->mem);
    memset(im, 0, sizeof *im);
}

static void release_inputs(mlh_nvenc *e) {
    for (int i = 0; i < IMPORTS; i++) drop_import(e, &e->imports[i]);
    if (e->upload) {
        nvc_forget(&e->core, (void *)(uintptr_t)e->upload);
        e->cu.cuMemFree_v2(e->upload);
        e->upload = 0;
    }
}

void mlh_nvenc_destroy(mlh_nvenc *e) {
    if (!e) return;
    if (e->ctx) {
        e->cu.cuCtxPushCurrent_v2(e->ctx);
        release_inputs(e);
        if (e->opened) nvc_close(&e->core);
        CUcontext dummy;
        e->cu.cuCtxPopCurrent_v2(&dummy);
        e->cu.cuCtxDestroy_v2(e->ctx);
    }
    if (e->nvenc_so) dlclose(e->nvenc_so);
    if (e->cu.so) dlclose(e->cu.so);
    free(e->out);
    free(e);
}

int mlh_nvenc_create(int ordinal, mlh_nvenc **out) {
    *out = NULL;
    last_error[0] = 0;
    mlh_nvenc *e = calloc(1, sizeof *e);
    if (!e) return MLH_NV_E_NOMEM;
    int rc = load(e);
    if (rc) goto fail;
    if (e->cu.cuInit(0) != CUDA_SUCCESS) {
        rc = fail(MLH_NV_E_NOTFOUND, "cuInit failed (no usable NVIDIA GPU)");
        goto fail;
    }
    CUdevice dev;
    if (e->cu.cuDeviceGet(&dev, ordinal) != CUDA_SUCCESS) {
        rc = fail(MLH_NV_E_NOTFOUND, "no CUDA device %d", ordinal);
        goto fail;
    }
    if ((rc = cu_check(e, e->cu.cuCtxCreate_v2(&e->ctx, 0, dev), "cuCtxCreate"))) goto fail;
    CUcontext dummy;
    e->cu.cuCtxPopCurrent_v2(&dummy); /* pushed around each call instead */
    nvc_pfn_max_version maxver = (nvc_pfn_max_version)dlsym(e->nvenc_so, "NvEncodeAPIGetMaxSupportedVersion");
    nvc_pfn_create_instance create = (nvc_pfn_create_instance)dlsym(e->nvenc_so, "NvEncodeAPICreateInstance");
    if (!maxver || !create) {
        rc = fail(MLH_NV_E_NOTFOUND, "libnvidia-encode has no NvEncodeAPICreateInstance");
        goto fail;
    }
    e->cu.cuCtxPushCurrent_v2(e->ctx);
    NVENCSTATUS s = nvc_open(&e->core, maxver, create, e->ctx, NV_ENC_DEVICE_TYPE_CUDA);
    e->cu.cuCtxPopCurrent_v2(&dummy);
    e->opened = e->core.enc != NULL;
    if (s != NV_ENC_SUCCESS) {
        rc = nv_fail(s, "open session");
        goto fail;
    }
    *out = e;
    return MLH_NV_OK;
fail:
    mlh_nvenc_destroy(e);
    return rc;
}

void mlh_nvenc_caps_get(const mlh_nvenc *e, mlh_nvenc_caps *out) {
    memset(out, 0, sizeof *out);
    out->h264 = (uint32_t)e->core.h264;
    out->hevc = (uint32_t)e->core.hevc;
    out->ltr = (uint32_t)e->core.ltr_supported;
    out->max_slices = 4;
}

int mlh_nvenc_configure(mlh_nvenc *e, const mlh_nvenc_config *cfg) {
    if (cfg->codec != MLH_NV_CODEC_H264 && cfg->codec != MLH_NV_CODEC_HEVC) return fail(MLH_NV_E_UNSUPPORTED, "codec %u", cfg->codec);
    const nvc_config c = {
        .codec = cfg->codec == MLH_NV_CODEC_HEVC ? NVC_CODEC_HEVC : NVC_CODEC_H264,
        .width = cfg->width,
        .height = cfg->height,
        .fps = cfg->fps,
        .bitrate_bps = cfg->bitrate_bps,
        .slices = cfg->slices,
        .ltr = cfg->ltr,
    };
    e->cu.cuCtxPushCurrent_v2(e->ctx);
    release_inputs(e);
    NVENCSTATUS s = nvc_configure(&e->core, &c);
    CUcontext dummy;
    e->cu.cuCtxPopCurrent_v2(&dummy);
    return s == NV_ENC_SUCCESS ? MLH_NV_OK : nv_fail(s, "configure");
}

static int import_dmabuf(mlh_nvenc *e, const mlh_nvenc_input *in, CUdeviceptr *ptr) {
    if (in->modifier != 0 && in->modifier != DRM_MOD_INVALID)
        return fail(MLH_NV_E_UNSUPPORTED, "dma-buf modifier 0x%llx is not linear", (unsigned long long)in->modifier);
    struct stat st;
    if (fstat(in->fd, &st) != 0) return fail(MLH_NV_E_FAIL, "dma-buf fd %d", in->fd);
    int victim = 0;
    for (int i = 0; i < IMPORTS; i++) {
        imported *im = &e->imports[i];
        if (im->mem && im->dev == st.st_dev && im->ino == st.st_ino && im->offset == in->offset &&
            im->pitch == in->pitch && im->fourcc == in->fourcc) {
            im->last_use = e->frame;
            *ptr = im->ptr;
            return MLH_NV_OK;
        }
        if (!im->mem || im->last_use < e->imports[victim].last_use) victim = i;
        if (!e->imports[victim].mem) break;
    }
    drop_import(e, &e->imports[victim]);
    off_t size = lseek(in->fd, 0, SEEK_END);
    if (size <= 0) return fail(MLH_NV_E_UNSUPPORTED, "dma-buf fd %d has no size", in->fd);
    const int fd = dup(in->fd); /* CUDA owns the descriptor it imports */
    if (fd < 0) return fail(MLH_NV_E_FAIL, "dup dma-buf fd");
    CUDA_EXTERNAL_MEMORY_HANDLE_DESC hd;
    memset(&hd, 0, sizeof hd);
    hd.type = CU_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD;
    hd.handle.fd = fd;
    hd.size = (unsigned long long)size;
    imported *im = &e->imports[victim];
    if (e->cu.cuImportExternalMemory(&im->mem, &hd) != CUDA_SUCCESS) {
        close(fd);
        im->mem = NULL;
        return fail(MLH_NV_E_UNSUPPORTED, "cuImportExternalMemory refused the dma-buf (not exported by the NVIDIA driver?)");
    }
    CUDA_EXTERNAL_MEMORY_BUFFER_DESC bd;
    memset(&bd, 0, sizeof bd);
    bd.offset = 0;
    bd.size = (unsigned long long)size;
    int rc = cu_check(e, e->cu.cuExternalMemoryGetMappedBuffer(&im->ptr, im->mem, &bd), "map dma-buf");
    if (rc) {
        e->cu.cuDestroyExternalMemory(im->mem);
        memset(im, 0, sizeof *im);
        return rc;
    }
    im->dev = st.st_dev;
    im->ino = st.st_ino;
    im->offset = in->offset;
    im->pitch = in->pitch;
    im->fourcc = in->fourcc;
    im->last_use = e->frame;
    *ptr = im->ptr;
    return MLH_NV_OK;
}

static int upload(mlh_nvenc *e, const mlh_nvenc_input *in, CUdeviceptr *ptr, size_t *pitch) {
    const size_t row = in->nv12 ? in->width : (size_t)in->width * 4;
    const size_t rows = in->nv12 ? (size_t)in->height * 3 / 2 : in->height;
    if (e->upload && e->upload_nv12 != in->nv12) {
        nvc_forget(&e->core, (void *)(uintptr_t)e->upload);
        e->cu.cuMemFree_v2(e->upload);
        e->upload = 0;
    }
    if (!e->upload) {
        int rc = cu_check(e, e->cu.cuMemAllocPitch_v2(&e->upload, &e->upload_pitch, row, rows, 16), "allocate input");
        if (rc) return rc;
        e->upload_nv12 = in->nv12;
    }
    CUDA_MEMCPY2D cp;
    memset(&cp, 0, sizeof cp);
    cp.srcMemoryType = CU_MEMORYTYPE_HOST;
    cp.srcHost = in->data;
    cp.srcPitch = in->stride;
    cp.dstMemoryType = CU_MEMORYTYPE_DEVICE;
    cp.dstDevice = e->upload;
    cp.dstPitch = e->upload_pitch;
    cp.WidthInBytes = row;
    cp.Height = rows;
    int rc = cu_check(e, e->cu.cuMemcpy2D_v2(&cp), "upload");
    if (rc) return rc;
    *ptr = e->upload;
    *pitch = e->upload_pitch;
    return MLH_NV_OK;
}

static int append(void *ctx, const void *data, size_t len) {
    mlh_nvenc *e = ctx;
    if (e->out_len + len > e->out_cap) {
        size_t cap = e->out_cap ? e->out_cap : 256 * 1024;
        while (cap < e->out_len + len) cap *= 2;
        uint8_t *n = realloc(e->out, cap);
        if (!n) return 1;
        e->out = n;
        e->out_cap = cap;
    }
    memcpy(e->out + e->out_len, data, len);
    e->out_len += len;
    return 0;
}

int mlh_nvenc_encode(mlh_nvenc *e, const mlh_nvenc_input *in, uint64_t time_us, const mlh_nvenc_params *p,
                     mlh_nvenc_output *out) {
    memset(out, 0, sizeof *out);
    if (!e->core.initialized) return fail(MLH_NV_E_FAIL, "encode before configure");
    if (in->width != e->core.cfg.width || in->height != e->core.cfg.height)
        return fail(MLH_NV_E_UNSUPPORTED, "frame %ux%u, configured %ux%u", in->width, in->height, e->core.cfg.width, e->core.cfg.height);
    e->cu.cuCtxPushCurrent_v2(e->ctx);
    int rc;
    CUdeviceptr ptr = 0;
    size_t pitch = 0;
    NV_ENC_BUFFER_FORMAT fmt;
    if (in->fd >= 0) {
        if (in->fourcc == DRM_XRGB8888 || in->fourcc == DRM_ARGB8888)
            fmt = NV_ENC_BUFFER_FORMAT_ARGB;
        else if (in->fourcc == DRM_NV12)
            fmt = NV_ENC_BUFFER_FORMAT_NV12;
        else {
            rc = fail(MLH_NV_E_UNSUPPORTED, "dma-buf format 0x%08x", in->fourcc);
            goto done;
        }
        rc = import_dmabuf(e, in, &ptr);
        ptr += in->offset;
        pitch = in->pitch;
    } else {
        fmt = in->nv12 ? NV_ENC_BUFFER_FORMAT_NV12 : NV_ENC_BUFFER_FORMAT_ARGB;
        rc = upload(e, in, &ptr, &pitch);
    }
    if (rc) goto done;
    NV_ENC_REGISTERED_PTR reg;
    NVENCSTATUS s = nvc_register(&e->core, NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR, (void *)(uintptr_t)ptr, 0,
                                 (uint32_t)pitch, fmt, &reg);
    if (s != NV_ENC_SUCCESS) {
        rc = nv_fail(s, "register input");
        goto done;
    }
    const nvc_params np = {
        .force = p->force,
        .bitrate_bps = p->bitrate_bps,
        .acked_ltr_tokens = p->acked_ltr_tokens,
        .acked_ltr_count = p->acked_ltr_count,
    };
    nvc_output o;
    e->out_len = 0;
    s = nvc_encode(&e->core, reg, time_us, &np, append, e, &o);
    if (s != NV_ENC_SUCCESS) {
        rc = nv_fail(s, "encode");
        goto done;
    }
    e->frame++;
    out->data = e->out;
    out->len = e->out_len;
    out->dropped = o.dropped || e->out_len == 0;
    if (!out->dropped) {
        out->keyframe = o.keyframe;
        out->has_ltr_token = o.has_ltr_token;
        out->ltr_token = o.ltr_token;
        out->ltr_refresh = o.ltr_refresh;
    }
done:;
    CUcontext dummy;
    e->cu.cuCtxPopCurrent_v2(&dummy);
    return rc;
}
