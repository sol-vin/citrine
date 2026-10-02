#ifndef CITRINE_HUD_H
#define CITRINE_HUD_H

#include "citrine_vm.h"

#ifdef __cplusplus
extern "C" {
#endif

void Citrine_HUD_Init(void);
void Citrine_HUD_Update(float ee_cpu_ms, float gs_gpu_ms, uint32_t active_regs, size_t arena_used_bytes);
void Citrine_HUD_Draw(void);
void Citrine_HUD_SetVisible(bool visible);
bool Citrine_HUD_IsVisible(void);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_HUD_H
