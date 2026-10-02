#ifndef CITRINE_PANIC_H
#define CITRINE_PANIC_H

#include "citrine_vm.h"

#ifdef __cplusplus
extern "C" {
#endif

void Citrine_Panic_Trigger(CitrineVM* vm, const char* title, const char* message, const char* file, int line);
void Citrine_Panic_RenderLoop(void);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_PANIC_H
