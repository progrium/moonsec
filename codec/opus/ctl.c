#include "ctl.h"

int moonsec_opus_encoder_set(OpusEncoder *st, int request, opus_int32 value) {
    return opus_encoder_ctl(st, request, value);
}

int moonsec_opus_encoder_get(OpusEncoder *st, int request, opus_int32 *out) {
    return opus_encoder_ctl(st, request, out);
}

int moonsec_opus_decoder_get(OpusDecoder *st, int request, opus_int32 *out) {
    return opus_decoder_ctl(st, request, out);
}

int moonsec_opus_encoder_final_range(OpusEncoder *st, opus_uint32 *out) {
    return opus_encoder_ctl(st, OPUS_GET_FINAL_RANGE_REQUEST, out);
}

int moonsec_opus_decoder_final_range(OpusDecoder *st, opus_uint32 *out) {
    return opus_decoder_ctl(st, OPUS_GET_FINAL_RANGE_REQUEST, out);
}

int moonsec_opus_encoder_reset(OpusEncoder *st) {
    return opus_encoder_ctl(st, OPUS_RESET_STATE);
}

int moonsec_opus_decoder_reset(OpusDecoder *st) {
    return opus_decoder_ctl(st, OPUS_RESET_STATE);
}
