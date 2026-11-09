/* Shared by the Linux encoder backends (enc.c, enc_vaapi.c, enc_sw.c, testenc.c). */
#ifndef MLH_ENC_INTERNAL_H
#define MLH_ENC_INTERNAL_H

#include "mlh_enc.h"

/* Records (and prints to stderr) the last error on this thread; returns `code`. */
int mlh_fail(int code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void mlh_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

typedef struct mlh_enc_ops {
    void (*caps)(const mlh_enc *e, mlh_enc_caps *out);
    int (*configure)(mlh_enc *e, const mlh_enc_config *cfg);
    /* Appends the access unit with mlh_enc_append; sets keyframe and LTR fields. Nothing
     * appended means dropped. */
    int (*encode)(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p, mlh_enc_output *out);
    void (*destroy)(mlh_enc *e);
} mlh_enc_ops;

struct mlh_enc {
    const mlh_enc_ops *ops;
    mlh_enc_config cfg;
    int configured;
    char describe[192];
    uint8_t *out;
    size_t out_len, out_cap;
};

int mlh_enc_append(mlh_enc *e, const void *data, size_t len);

int mlh_enc_vaapi_create(const char *device, mlh_enc **out);
int mlh_enc_sw_create(mlh_enc **out);

/* Maps a linear dma-buf for reading (dmabuf.c): BGRA or contiguous NV12. */
int mlh_dmabuf_map(const mlh_dmabuf *d, const uint8_t **data, uint32_t *stride, uint32_t *format, void **cookie);
void mlh_dmabuf_unmap(void *cookie);

/* Fills out->slice_offsets from the Annex B access unit in data/len. */
void mlh_split_slices(const uint8_t *data, size_t len, uint32_t codec, mlh_enc_output *out);

#endif
