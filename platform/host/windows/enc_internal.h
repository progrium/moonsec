/* Shared by the encoder backends (enc.c, enc_mf.c, enc_nvenc.c). */
#ifndef ENC_INTERNAL_H
#define ENC_INTERNAL_H

#include "msw_internal.h"
#include "host_win.h"

typedef struct msw_enc_ops {
    void (*caps)(const msw_enc *e, msw_enc_caps *out);
    HRESULT (*configure)(msw_enc *e, const msw_enc_config *cfg);
    HRESULT (*encode)(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                      msw_enc_output *out);
    void (*destroy)(msw_enc *e);
} msw_enc_ops;

struct msw_enc {
    const msw_enc_ops *ops;
    msw_d3d *d;
    msw_enc_config cfg;
    int configured;
    /* Output buffer the backends append the access unit to. */
    uint8_t *out;
    size_t out_len, out_cap;
};

HRESULT msw_enc_mf_create(msw_d3d *d, msw_enc **out);
HRESULT msw_enc_nvenc_create(msw_d3d *d, msw_enc **out);

/* Appends to e->out. */
HRESULT msw_enc_append(msw_enc *e, const void *data, size_t len);

#endif
