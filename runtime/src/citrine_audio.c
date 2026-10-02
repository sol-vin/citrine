#include <stdint.h>
#include "../include/citrine_audio.h"

void Citrine_InitAudio(void) {
#ifndef HOST_TEST_BUILD
    // PS2SDK audsrv / libsd initialization
    // audsrv_init();
#endif
}

uint32_t Citrine_LoadSound(const char* path) {
    (void)path;
    static uint32_t s_next_sound_id = 1;
    return s_next_sound_id++;
}

void Citrine_PlaySound(uint32_t sound_id) {
    (void)sound_id;
#ifndef HOST_TEST_BUILD
    // audsrv_play_audio(...);
#endif
}

void Citrine_StopSound(uint32_t sound_id) {
    (void)sound_id;
}

void Citrine_CloseAudio(void) {
#ifndef HOST_TEST_BUILD
    // audsrv_quit();
#endif
}
