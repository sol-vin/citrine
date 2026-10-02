#include <stdio.h>
#include <stdbool.h>
#include "../include/citrine_hud.h"
#include "../include/citrine_draw2d.h"
#include "../include/citrine_core.h"

static bool     s_hud_visible = false;
static float    s_ee_cpu_ms = 0.0f;
static float    s_gs_gpu_ms = 0.0f;
static uint32_t s_active_regs = 0;
static size_t   s_arena_used = 0;

void Citrine_HUD_Init(void) {
    s_hud_visible = false;
}

void Citrine_HUD_Update(float ee_cpu_ms, float gs_gpu_ms, uint32_t active_regs, size_t arena_used_bytes) {
    s_ee_cpu_ms = ee_cpu_ms;
    s_gs_gpu_ms = gs_gpu_ms;
    s_active_regs = active_regs;
    s_arena_used = arena_used_bytes;
}

void Citrine_HUD_SetVisible(bool visible) {
    s_hud_visible = visible;
}

bool Citrine_HUD_IsVisible(void) {
    return s_hud_visible;
}

void Citrine_HUD_Draw(void) {
    if (!s_hud_visible) return;

    // Background panel for HUD
    Citrine_DrawRectangle(10.0f, 10.0f, 620.0f, 60.0f, 0xCC000000); // 80% black

    // Text metrics
    char buf[128];
    snprintf(buf, sizeof(buf), "CITRINE PS2 PROFILER | %.1f FPS (%.1f ms) | EE CPU: %.1f ms | GS GPU: %.1f ms",
             Citrine_GetFPS(), Citrine_GetDeltaTime() * 1000.0f, s_ee_cpu_ms, s_gs_gpu_ms);
    Citrine_DrawText(buf, 20.0f, 18.0f, 12, 0xFFFFFFFF);

    snprintf(buf, sizeof(buf), "SPRAM Regs: %u / 1024 | Frame Arena: %zu KB / 512 KB | VRAM: 4MB eDRAM",
             s_active_regs, s_arena_used / 1024);
    Citrine_DrawText(buf, 20.0f, 38.0f, 12, 0xFF00FF00); // Green
}
