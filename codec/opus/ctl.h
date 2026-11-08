/* What Zig sees of libopus: the public API plus non-variadic wrappers for the CTL calls,
   so Zig never calls a C variadic function (that ABI differs per target). */
#ifndef MOONSEC_OPUS_CTL_H
#define MOONSEC_OPUS_CTL_H

#include <opus.h>

/* opus_encoder_ctl(st, request, value) for the integer setters. Returns an OPUS_* code. */
int moonsec_opus_encoder_set(OpusEncoder *st, int request, opus_int32 value);
/* opus_encoder_ctl(st, request, &out) for the integer getters. */
int moonsec_opus_encoder_get(OpusEncoder *st, int request, opus_int32 *out);
/* opus_decoder_ctl(st, request, &out) for the integer getters. */
int moonsec_opus_decoder_get(OpusDecoder *st, int request, opus_int32 *out);
/* OPUS_GET_FINAL_RANGE: the range coder state after the last packet (for bit-exactness checks). */
int moonsec_opus_encoder_final_range(OpusEncoder *st, opus_uint32 *out);
int moonsec_opus_decoder_final_range(OpusDecoder *st, opus_uint32 *out);
int moonsec_opus_encoder_reset(OpusEncoder *st);
int moonsec_opus_decoder_reset(OpusDecoder *st);

#endif
