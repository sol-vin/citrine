#include <stdio.h>
#include <stdbool.h>
#include "../include/citrine_core.h"
#include "../include/citrine_hud.h"

CitrineContext g_citrine_ctx = {
    .width = 640,
    .height = 448,
    .is_open = true,
    .target_fps = 60,
    .fps = 60.0f,
    .delta_time = 0.016667f,
    .frame_count = 0,
    .debug_overlay = false
};

void Citrine_InitWindow(int width, int height, const char* title) {
    g_citrine_ctx.width = width;
    g_citrine_ctx.height = height;
    g_citrine_ctx.is_open = true;
    (void)title;

#ifndef HOST_TEST_BUILD
    // PS2SDK GS & Video initialization
    // Sets up NTSC 640x448 or PAL 640x512 double buffering
#endif
    Citrine_HUD_Init();
}

void Citrine_CloseWindow(void) {
    g_citrine_ctx.is_open = false;
}

bool Citrine_WindowOpen(void) {
    return g_citrine_ctx.is_open;
}

void Citrine_SetTargetFPS(int fps) {
    g_citrine_ctx.target_fps = fps;
}

float Citrine_GetFPS(void) {
    return g_citrine_ctx.fps;
}

float Citrine_GetDeltaTime(void) {
    return g_citrine_ctx.delta_time;
}

void Citrine_BeginDrawing(void) {
    g_citrine_ctx.frame_count++;
}

void Citrine_EndDrawing(void) {
    // Draw performance HUD overlay if enabled
    if (Citrine_HUD_IsVisible()) {
        Citrine_HUD_Draw();
    }

#ifndef HOST_TEST_BUILD
    // PS2 GS Double-buffer flip & VSync wait
    // graph_wait_vsync();
#endif
}

void Citrine_ClearBackground(uint32_t color) {
    (void)color;
    // Clears the GS framebuffer
}
