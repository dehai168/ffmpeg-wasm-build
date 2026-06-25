#include "iov_decoder.h"

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IOV_MAX_FRAMES 8
#define IOV_AUDIO_BUFFER_SIZE (1024 * 1024)

typedef struct IovPlaneBuffer {
    uint8_t *data;
    int size;
} IovPlaneBuffer;

typedef struct IovDecodedFrame {
    int is_video;
    double timestamp_ms;
    int width;
    int height;
    char format[16];
    IovPlaneBuffer planes[3];
    int sample_rate;
    int channels;
    int audio_samples;
    uint8_t *audio_data;
    int audio_bytes;
} IovDecodedFrame;

typedef struct IovDecoderState {
    AVCodecContext *video_ctx;
    AVCodecContext *audio_ctx;
    struct SwsContext *sws_ctx;
    struct SwrContext *swr_ctx;
    AVFrame *frame;
    AVPacket *packet;
    IovDecodedFrame frames[IOV_MAX_FRAMES];
    int frame_count;
    uint8_t *audio_buffer;
    int audio_buffer_size;
    enum AVCodecID video_codec_id;
    enum AVCodecID audio_codec_id;
} IovDecoderState;

static IovDecoderState g_state;

static void reset_output_frames(void) {
    for (int i = 0; i < g_state.frame_count; i += 1) {
        for (int p = 0; p < 3; p += 1) {
            free(g_state.frames[i].planes[p].data);
            g_state.frames[i].planes[p].data = NULL;
            g_state.frames[i].planes[p].size = 0;
        }
        free(g_state.frames[i].audio_data);
        g_state.frames[i].audio_data = NULL;
    }
    g_state.frame_count = 0;
}

static void free_codec_context(AVCodecContext **ctx) {
    if (!ctx || !*ctx) {
        return;
    }
    avcodec_free_context(ctx);
    *ctx = NULL;
}

static int context_has_token(const char *json, const char *token) {
    return json && strstr(json, token) != NULL;
}

static int context_is_keyframe(const char *json) {
    return context_has_token(json, "\"keyframe\":true") || context_has_token(json, "\"keyframe\": true");
}

static double context_timestamp_ms(const char *json) {
    const char *key = "\"timestamp\"";
    const char *pos = json ? strstr(json, key) : NULL;
    if (!pos) {
        return 0;
    }
    pos = strchr(pos, ':');
    if (!pos) {
        return 0;
    }
    return strtod(pos + 1, NULL);
}

static enum AVCodecID parse_video_codec(const char *json) {
    if (context_has_token(json, "\"h265\"") || context_has_token(json, "\"hevc\"")) {
        return AV_CODEC_ID_HEVC;
    }
    return AV_CODEC_ID_H264;
}

static int ensure_video_decoder(enum AVCodecID codec_id) {
    if (g_state.video_ctx && g_state.video_codec_id == codec_id) {
        return 0;
    }

    free_codec_context(&g_state.video_ctx);
    if (g_state.sws_ctx) {
        sws_freeContext(g_state.sws_ctx);
        g_state.sws_ctx = NULL;
    }

    const AVCodec *codec = avcodec_find_decoder(codec_id);
    if (!codec) {
        return AVERROR_DECODER_NOT_FOUND;
    }

    g_state.video_ctx = avcodec_alloc_context3(codec);
    if (!g_state.video_ctx) {
        return AVERROR(ENOMEM);
    }

    g_state.video_codec_id = codec_id;
    return 0;
}

static int ensure_audio_decoder(enum AVCodecID codec_id) {
    if (g_state.audio_ctx && g_state.audio_codec_id == codec_id) {
        return 0;
    }

    free_codec_context(&g_state.audio_ctx);
    if (g_state.swr_ctx) {
        swr_free(&g_state.swr_ctx);
        g_state.swr_ctx = NULL;
    }

    const AVCodec *codec = avcodec_find_decoder(codec_id);
    if (!codec) {
        return AVERROR_DECODER_NOT_FOUND;
    }

    g_state.audio_ctx = avcodec_alloc_context3(codec);
    if (!g_state.audio_ctx) {
        return AVERROR(ENOMEM);
    }

    g_state.audio_codec_id = codec_id;
    return 0;
}

static int copy_plane(IovPlaneBuffer *plane, const uint8_t *src, int size) {
    free(plane->data);
    plane->data = (uint8_t *)malloc(size);
    if (!plane->data) {
        plane->size = 0;
        return AVERROR(ENOMEM);
    }
    memcpy(plane->data, src, size);
    plane->size = size;
    return 0;
}

static int store_video_frame(AVFrame *src, double timestamp_ms) {
    if (g_state.frame_count >= IOV_MAX_FRAMES) {
        return 0;
    }

    AVFrame *yuv = src;
    AVFrame *converted = NULL;
    int ret = 0;

    if (src->format != AV_PIX_FMT_YUV420P) {
        converted = av_frame_alloc();
        if (!converted) {
            return AVERROR(ENOMEM);
        }
        converted->format = AV_PIX_FMT_YUV420P;
        converted->width = src->width;
        converted->height = src->height;
        ret = av_frame_get_buffer(converted, 32);
        if (ret < 0) {
            av_frame_free(&converted);
            return ret;
        }

        g_state.sws_ctx = sws_getCachedContext(
            g_state.sws_ctx,
            src->width,
            src->height,
            src->format,
            src->width,
            src->height,
            AV_PIX_FMT_YUV420P,
            SWS_BILINEAR,
            NULL,
            NULL,
            NULL);
        if (!g_state.sws_ctx) {
            av_frame_free(&converted);
            return AVERROR(ENOMEM);
        }

        sws_scale(
            g_state.sws_ctx,
            (const uint8_t *const *)src->data,
            src->linesize,
            0,
            src->height,
            converted->data,
            converted->linesize);
        yuv = converted;
    }

    IovDecodedFrame *out = &g_state.frames[g_state.frame_count++];
    memset(out, 0, sizeof(*out));
    out->is_video = 1;
    out->timestamp_ms = timestamp_ms;
    out->width = yuv->width;
    out->height = yuv->height;
    strncpy(out->format, "i420", sizeof(out->format) - 1);

    ret = copy_plane(&out->planes[0], yuv->data[0], yuv->linesize[0] * yuv->height);
    if (ret < 0) {
        av_frame_free(&converted);
        return ret;
    }
    ret = copy_plane(&out->planes[1], yuv->data[1], yuv->linesize[1] * ((yuv->height + 1) / 2));
    if (ret < 0) {
        av_frame_free(&converted);
        return ret;
    }
    ret = copy_plane(&out->planes[2], yuv->data[2], yuv->linesize[2] * ((yuv->height + 1) / 2));
    av_frame_free(&converted);
    return ret;
}

static int g_audio_out_channels = 2;

static int store_audio_frame(AVFrame *src, double timestamp_ms) {
    if (g_state.frame_count >= IOV_MAX_FRAMES) {
        return 0;
    }

    if (!g_state.swr_ctx) {
        AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_STEREO;
        g_audio_out_channels = 2;
        if (src->ch_layout.nb_channels == 1) {
            out_layout = AV_CHANNEL_LAYOUT_MONO;
            g_audio_out_channels = 1;
        }

        int ret = swr_alloc_set_opts2(
            &g_state.swr_ctx,
            &out_layout,
            AV_SAMPLE_FMT_FLT,
            src->sample_rate,
            &src->ch_layout,
            (enum AVSampleFormat)src->format,
            src->sample_rate,
            0,
            NULL);
        if (ret < 0) {
            return ret;
        }
        ret = swr_init(g_state.swr_ctx);
        if (ret < 0) {
            return ret;
        }
    }

    int out_samples = swr_get_out_samples(g_state.swr_ctx, src->nb_samples);
    if (out_samples < 0) {
        return out_samples;
    }

    int bytes = out_samples * g_audio_out_channels * (int)sizeof(float);
    if (bytes > g_state.audio_buffer_size) {
        return AVERROR(ENOMEM);
    }

    uint8_t *out_data[1] = { g_state.audio_buffer };
    int converted = swr_convert(g_state.swr_ctx, out_data, out_samples, (const uint8_t **)src->data, src->nb_samples);
    if (converted < 0) {
        return converted;
    }

    IovDecodedFrame *out = &g_state.frames[g_state.frame_count++];
    memset(out, 0, sizeof(*out));
    out->is_video = 0;
    out->timestamp_ms = timestamp_ms;
    out->sample_rate = src->sample_rate;
    out->channels = g_audio_out_channels;
    out->audio_samples = converted;
    out->audio_bytes = converted * g_audio_out_channels * (int)sizeof(float);
    out->audio_data = (uint8_t *)malloc(out->audio_bytes);
    if (!out->audio_data) {
        g_state.frame_count -= 1;
        return AVERROR(ENOMEM);
    }
    memcpy(out->audio_data, g_state.audio_buffer, out->audio_bytes);
    return 0;
}

static int drain_decoder(AVCodecContext *ctx, int is_video, double timestamp_ms) {
    int ret = 0;
    while (ret >= 0) {
        ret = avcodec_receive_frame(ctx, g_state.frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return ret;
        }

        if (is_video) {
            ret = store_video_frame(g_state.frame, timestamp_ms);
        } else {
            ret = store_audio_frame(g_state.frame, timestamp_ms);
        }
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

static int send_video_packet(const uint8_t *data, int size, double timestamp_ms, int keyframe) {
    if (!g_state.video_ctx) {
        return 0;
    }

    av_packet_unref(g_state.packet);
    if (av_new_packet(g_state.packet, size) < 0) {
        return AVERROR(ENOMEM);
    }
    memcpy(g_state.packet->data, data, size);
    g_state.packet->size = size;
    g_state.packet->pts = (int64_t)timestamp_ms;
    g_state.packet->dts = (int64_t)timestamp_ms;
    if (keyframe) {
        g_state.packet->flags |= AV_PKT_FLAG_KEY;
    }

    int ret = avcodec_send_packet(g_state.video_ctx, g_state.packet);
    if (ret < 0) {
        return ret;
    }
    return drain_decoder(g_state.video_ctx, 1, timestamp_ms);
}

static int send_audio_packet(const uint8_t *data, int size, double timestamp_ms) {
    if (!g_state.audio_ctx) {
        return 0;
    }

    av_packet_unref(g_state.packet);
    if (av_new_packet(g_state.packet, size) < 0) {
        return AVERROR(ENOMEM);
    }
    memcpy(g_state.packet->data, data, size);
    g_state.packet->size = size;
    g_state.packet->pts = (int64_t)timestamp_ms;
    g_state.packet->dts = (int64_t)timestamp_ms;

    int ret = avcodec_send_packet(g_state.audio_ctx, g_state.packet);
    if (ret < 0) {
        return ret;
    }
    return drain_decoder(g_state.audio_ctx, 0, timestamp_ms);
}

static int decode_h264_hevc_video(const uint8_t *payload, int len, const char *context_json) {
    if (len < 2) {
        return 0;
    }

    enum AVCodecID codec_id = parse_video_codec(context_json);
    int ret = ensure_video_decoder(codec_id);
    if (ret < 0) {
        return ret;
    }

    int packet_type = payload[1];
    double timestamp_ms = context_timestamp_ms(context_json);
    int keyframe = context_is_keyframe(context_json);

    if (packet_type == 0) {
        if (len <= 5) {
            return 0;
        }
        const uint8_t *extradata = payload + 5;
        int extradata_size = len - 5;
        if (g_state.video_ctx && avcodec_is_open(g_state.video_ctx)) {
            avcodec_close(g_state.video_ctx);
        }
        av_freep(&g_state.video_ctx->extradata);
        g_state.video_ctx->extradata = (uint8_t *)av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!g_state.video_ctx->extradata) {
            return AVERROR(ENOMEM);
        }
        memcpy(g_state.video_ctx->extradata, extradata, extradata_size);
        g_state.video_ctx->extradata_size = extradata_size;
        return avcodec_open2(g_state.video_ctx, g_state.video_ctx->codec, NULL);
    }

    if (packet_type != 1 || len <= 5) {
        return 0;
    }

    if (!avcodec_is_open(g_state.video_ctx)) {
        int open_ret = avcodec_open2(g_state.video_ctx, g_state.video_ctx->codec, NULL);
        if (open_ret < 0) {
            return open_ret;
        }
    }

    return send_video_packet(payload + 5, len - 5, timestamp_ms, keyframe);
}

static enum AVCodecID parse_audio_codec(const uint8_t *payload, int len) {
    if (len < 1) {
        return AV_CODEC_ID_NONE;
    }
    int sound_format = payload[0] >> 4;
    if (sound_format == 10) {
        return AV_CODEC_ID_AAC;
    }
    if (sound_format == 2) {
        return AV_CODEC_ID_MP3;
    }
    if (sound_format == 13) {
        return AV_CODEC_ID_OPUS;
    }
    return AV_CODEC_ID_NONE;
}

static int decode_flv_audio(const uint8_t *payload, int len, const char *context_json) {
    if (len < 2) {
        return 0;
    }

    enum AVCodecID codec_id = parse_audio_codec(payload, len);
    if (codec_id == AV_CODEC_ID_NONE) {
        return 0;
    }

    int ret = ensure_audio_decoder(codec_id);
    if (ret < 0) {
        return ret;
    }

    double timestamp_ms = context_timestamp_ms(context_json);
    int sound_format = payload[0] >> 4;

    if (sound_format == 10) {
        int aac_packet_type = payload[1];
        if (aac_packet_type == 0) {
            if (len <= 2) {
                return 0;
            }
            const uint8_t *asc = payload + 2;
            int asc_size = len - 2;
            free_codec_context(&g_state.audio_ctx);
            ret = ensure_audio_decoder(codec_id);
            if (ret < 0) {
                return ret;
            }
            g_state.audio_ctx->extradata = (uint8_t *)av_mallocz(asc_size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!g_state.audio_ctx->extradata) {
                return AVERROR(ENOMEM);
            }
            memcpy(g_state.audio_ctx->extradata, asc, asc_size);
            g_state.audio_ctx->extradata_size = asc_size;
            return avcodec_open2(g_state.audio_ctx, g_state.audio_ctx->codec, NULL);
        }

        if (aac_packet_type != 1 || len <= 2) {
            return 0;
        }
        if (!avcodec_is_open(g_state.audio_ctx)) {
            int open_ret = avcodec_open2(g_state.audio_ctx, g_state.audio_ctx->codec, NULL);
            if (open_ret < 0) {
                return open_ret;
            }
        }
        return send_audio_packet(payload + 2, len - 2, timestamp_ms);
    }

    if (len <= 1) {
        return 0;
    }
    if (!avcodec_is_open(g_state.audio_ctx)) {
        int open_ret = avcodec_open2(g_state.audio_ctx, g_state.audio_ctx->codec, NULL);
        if (open_ret < 0) {
            return open_ret;
        }
    }
    return send_audio_packet(payload + 1, len - 1, timestamp_ms);
}

void iov_decoder_configure(const char *config_json) {
    (void)config_json;
    iov_decoder_close();
}

int iov_decoder_decode(const uint8_t *data, int size, const char *context_json) {
    if (!data || size <= 0) {
        return 0;
    }

    if (!g_state.packet) {
        g_state.packet = av_packet_alloc();
        g_state.frame = av_frame_alloc();
        g_state.audio_buffer = (uint8_t *)malloc(IOV_AUDIO_BUFFER_SIZE);
        g_state.audio_buffer_size = IOV_AUDIO_BUFFER_SIZE;
    }

    reset_output_frames();

    if (context_has_token(context_json, "\"audio\"")) {
        return decode_flv_audio(data, size, context_json);
    }

    if (context_has_token(context_json, "\"video\"")) {
        return decode_h264_hevc_video(data, size, context_json);
    }

    return 0;
}

void iov_decoder_flush(void) {
    if (g_state.video_ctx && avcodec_is_open(g_state.video_ctx)) {
        avcodec_send_packet(g_state.video_ctx, NULL);
        drain_decoder(g_state.video_ctx, 1, 0);
    }
    if (g_state.audio_ctx && avcodec_is_open(g_state.audio_ctx)) {
        avcodec_send_packet(g_state.audio_ctx, NULL);
        drain_decoder(g_state.audio_ctx, 0, 0);
    }
}

void iov_decoder_close(void) {
    reset_output_frames();
    free_codec_context(&g_state.video_ctx);
    free_codec_context(&g_state.audio_ctx);
    if (g_state.sws_ctx) {
        sws_freeContext(g_state.sws_ctx);
        g_state.sws_ctx = NULL;
    }
    if (g_state.swr_ctx) {
        swr_free(&g_state.swr_ctx);
        g_state.swr_ctx = NULL;
    }
    if (g_state.packet) {
        av_packet_free(&g_state.packet);
    }
    if (g_state.frame) {
        av_frame_free(&g_state.frame);
    }
    free(g_state.audio_buffer);
    g_state.audio_buffer = NULL;
    g_state.audio_buffer_size = 0;
    g_state.video_codec_id = AV_CODEC_ID_NONE;
    g_state.audio_codec_id = AV_CODEC_ID_NONE;
}

int iov_decoder_frame_count(void) {
    return g_state.frame_count;
}

int iov_decoder_frame_is_video(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].is_video;
}

double iov_decoder_frame_timestamp(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].timestamp_ms;
}

int iov_decoder_frame_width(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].width;
}

int iov_decoder_frame_height(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].height;
}

const char *iov_decoder_frame_format(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return "i420";
    }
    return g_state.frames[index].format;
}

uint8_t *iov_decoder_frame_plane(int index, int plane) {
    if (index < 0 || index >= g_state.frame_count || plane < 0 || plane > 2) {
        return NULL;
    }
    return g_state.frames[index].planes[plane].data;
}

int iov_decoder_frame_plane_size(int index, int plane) {
    if (index < 0 || index >= g_state.frame_count || plane < 0 || plane > 2) {
        return 0;
    }
    return g_state.frames[index].planes[plane].size;
}

int iov_decoder_frame_sample_rate(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].sample_rate;
}

int iov_decoder_frame_channels(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].channels;
}

int iov_decoder_frame_audio_samples(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].audio_samples;
}

uint8_t *iov_decoder_frame_audio_data(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return NULL;
    }
    return g_state.frames[index].audio_data;
}

int iov_decoder_frame_audio_bytes(int index) {
    if (index < 0 || index >= g_state.frame_count) {
        return 0;
    }
    return g_state.frames[index].audio_bytes;
}
