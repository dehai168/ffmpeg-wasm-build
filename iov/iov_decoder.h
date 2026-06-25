#ifndef IOV_DECODER_H
#define IOV_DECODER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void iov_decoder_configure(const char *config_json);
int iov_decoder_decode(const uint8_t *data, int size, const char *context_json);
void iov_decoder_flush(void);
void iov_decoder_close(void);

int iov_decoder_frame_count(void);
int iov_decoder_frame_is_video(int index);
double iov_decoder_frame_timestamp(int index);
int iov_decoder_frame_width(int index);
int iov_decoder_frame_height(int index);
const char *iov_decoder_frame_format(int index);
uint8_t *iov_decoder_frame_plane(int index, int plane);
int iov_decoder_frame_plane_size(int index, int plane);
int iov_decoder_frame_sample_rate(int index);
int iov_decoder_frame_channels(int index);
int iov_decoder_frame_audio_samples(int index);
uint8_t *iov_decoder_frame_audio_data(int index);
int iov_decoder_frame_audio_bytes(int index);

void *iov_wasm_malloc(int size);
void iov_wasm_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif
