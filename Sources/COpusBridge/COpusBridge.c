#include "COpusBridge.h"
#include <opusfile.h>
#include <stdlib.h>
struct QwenOpus { OggOpusFile *file; };
QwenOpus *qwen_opus_open(const unsigned char *data, size_t size, int64_t *frames, int *channels) {
    int error = 0;
    OggOpusFile *file = op_open_memory(data, size, &error);
    if (!file) return NULL;
    /* Chained links can change channel layouts. Reject for deterministic metadata. */
    if (op_link_count(file) != 1) { op_free(file); return NULL; }
    QwenOpus *decoder = malloc(sizeof(*decoder));
    if (!decoder) { op_free(file); return NULL; }
    decoder->file = file;
    *frames = op_pcm_total(file, -1);
    *channels = op_channel_count(file, -1);
    return decoder;
}
int qwen_opus_seek(QwenOpus *decoder, int64_t frame) { return op_pcm_seek(decoder->file, frame); }
int qwen_opus_read(QwenOpus *decoder, float *samples, int capacity) {
    return op_read_float_stereo(decoder->file, samples, capacity);
}
void qwen_opus_close(QwenOpus *decoder) { if (decoder) { op_free(decoder->file); free(decoder); } }
