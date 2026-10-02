#ifndef CITRINE_VIDEO_H
#define CITRINE_VIDEO_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// PlayStation 2 Video (IPU MPEG-2 / PSS) Interface
uint32_t Citrine_LoadVideo(const char* path);
bool     Citrine_PlayVideo(uint32_t video_id, bool loop);
void     Citrine_DrawVideoFrame(uint32_t video_id, float x, float y, float w, float h);
bool     Citrine_VideoFinished(uint32_t video_id);
void     Citrine_PauseVideo(uint32_t video_id);
void     Citrine_StopVideo(uint32_t video_id);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_VIDEO_H
