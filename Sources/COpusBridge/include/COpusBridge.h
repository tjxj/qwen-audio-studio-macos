#ifndef QWEN_OPUS_BRIDGE_H
#define QWEN_OPUS_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
typedef struct QwenOpus QwenOpus;
QwenOpus *qwen_opus_open(const unsigned char *data, size_t size, int64_t *frames, int *channels);
int qwen_opus_seek(QwenOpus *decoder, int64_t frame);
/* capacity counts float elements; return value counts stereo frames. */
int qwen_opus_read(QwenOpus *decoder, float *interleaved_stereo, int capacity);
void qwen_opus_close(QwenOpus *decoder);
#endif
