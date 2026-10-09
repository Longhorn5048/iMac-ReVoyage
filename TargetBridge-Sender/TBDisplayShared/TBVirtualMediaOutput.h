#ifndef TB_VIRTUAL_MEDIA_OUTPUT_H
#define TB_VIRTUAL_MEDIA_OUTPUT_H
#include <stdint.h>
#include <stddef.h>
int tb_virtual_camera_start(void);
void tb_virtual_camera_stop(void);
int tb_virtual_camera_push_jpeg(const uint8_t *bytes, size_t size);
int tb_virtual_microphone_start(void);
void tb_virtual_microphone_stop(void);
int tb_virtual_microphone_push_pcm(const uint8_t *bytes, size_t size);
#endif
