#ifndef CITRINE_CORE_H
#define CITRINE_CORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int   width;
    int   height;
    bool  is_open;
    int   target_fps;
    float fps;
    float delta_time;
    uint32_t frame_count;
    bool  debug_overlay;
} CitrineContext;

extern CitrineContext g_citrine_ctx;

void  Citrine_InitWindow(int width, int height, const char* title);
void  Citrine_CloseWindow(void);
bool  Citrine_WindowOpen(void);
void  Citrine_SetTargetFPS(int fps);
float Citrine_GetFPS(void);
float Citrine_GetDeltaTime(void);

void  Citrine_BeginDrawing(void);
void  Citrine_EndDrawing(void);
void  Citrine_ClearBackground(uint32_t color);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_CORE_H
