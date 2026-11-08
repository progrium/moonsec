/* Encoder dispatch: one msw_enc API over the NVENC, AMF, oneVPL and Media Foundation backends. */
#include "enc_internal.h"

#include <string.h>

msw_hr msw_enc_create(msw_d3d *d, msw_enc_kind kind, msw_enc **out) {
    *out = NULL;
    switch (kind) {
    case MSW_ENC_NVENC: return msw_enc_nvenc_create(d, out);
    case MSW_ENC_MF_SOFTWARE: return msw_enc_mf_create(d, out);
    case MSW_ENC_AMF: return msw_enc_amf_create(d, out);
    case MSW_ENC_VPL: return msw_enc_vpl_create(d, out);
    default: return E_INVALIDARG;
    }
}

void msw_enc_caps_get(const msw_enc *e, msw_enc_caps *out) {
    memset(out, 0, sizeof *out);
    e->ops->caps(e, out);
}

msw_hr msw_enc_configure(msw_enc *e, const msw_enc_config *cfg) {
    if (cfg->width == 0 || cfg->height == 0 || cfg->fps == 0 || cfg->bitrate_bps == 0) return E_INVALIDARG;
    HRESULT hr = e->ops->configure(e, cfg);
    if (SUCCEEDED(hr)) {
        e->cfg = *cfg;
        e->configured = 1;
    }
    return hr;
}

msw_hr msw_enc_encode(msw_enc *e, void *texture, uint32_t index, uint64_t time_us, const msw_enc_params *p,
                      msw_enc_output *out) {
    memset(out, 0, sizeof *out);
    if (!e->configured) return E_UNEXPECTED;
    e->out_len = 0;
    HRESULT hr = e->ops->encode(e, (ID3D11Texture2D *)texture, index, time_us, p, out);
    if (SUCCEEDED(hr)) {
        out->data = e->out;
        out->len = e->out_len;
        if (out->len == 0) out->dropped = 1;
    }
    return hr;
}

void msw_enc_destroy(msw_enc *e) {
    if (!e) return;
    uint8_t *buf = e->out;
    e->ops->destroy(e); /* frees the backend struct, which embeds *e */
    free(buf);
}

HRESULT msw_enc_append(msw_enc *e, const void *data, size_t len) {
    if (e->out_len + len > e->out_cap) {
        size_t cap = e->out_cap ? e->out_cap : 256 * 1024;
        while (cap < e->out_len + len) cap *= 2;
        uint8_t *n = (uint8_t *)realloc(e->out, cap);
        if (!n) return E_OUTOFMEMORY;
        e->out = n;
        e->out_cap = cap;
    }
    memcpy(e->out + e->out_len, data, len);
    e->out_len += len;
    return S_OK;
}

int msw_annexb_has_idr(const uint8_t *p, size_t len, uint32_t codec) {
    for (size_t i = 0; i + 3 < len; i++) {
        if (p[i] != 0 || p[i + 1] != 0 || p[i + 2] != 1) continue;
        const uint8_t h = p[i + 3];
        if (codec == MSW_CODEC_HEVC) {
            const uint8_t t = (h >> 1) & 0x3f;
            if (t == 19 || t == 20) return 1; /* IDR_W_RADL, IDR_N_LP */
        } else if ((h & 0x1f) == 5) {
            return 1;
        }
        i += 2;
    }
    return 0;
}
