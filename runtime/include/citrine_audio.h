#ifndef CITRINE_AUDIO_H
#define CITRINE_AUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void     Citrine_InitAudio(void);
uint32_t Citrine_LoadSound(const char* path);
void     Citrine_PlaySound(uint32_t sound_id);
void     Citrine_StopSound(uint32_t sound_id);
void     Citrine_CloseAudio(void);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_AUDIO_H
