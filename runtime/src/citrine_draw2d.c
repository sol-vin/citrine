#include <stdio.h>
#include "../include/citrine_draw2d.h"

void Citrine_DrawRectangle(float x, float y, float w, float h, uint32_t color) {
    (void)x; (void)y; (void)w; (void)h; (void)color;
#ifndef HOST_TEST_BUILD
    // Emits GS_SET_PRIM(PRIM_SPRITE) DMA packet to Graphic Synthesizer
#endif
}

void Citrine_DrawCircle(float cx, float cy, float radius, uint32_t color) {
    (void)cx; (void)cy; (void)radius; (void)color;
}

void Citrine_DrawLine(float x1, float y1, float x2, float y2, uint32_t color) {
    (void)x1; (void)y1; (void)x2; (void)y2; (void)color;
}

void Citrine_DrawTriangle(float x1, float y1, float x2, float y2, float x3, float y3, uint32_t color) {
    (void)x1; (void)y1; (void)x2; (void)y2; (void)x3; (void)y3; (void)color;
}

void Citrine_DrawQuad(float x1, float y1, float x2, float y2, float x3, float y3, float x4, float y4, uint32_t color) {
    // Quad decomposed into two triangles: (1, 2, 3) and (1, 3, 4)
    Citrine_DrawTriangle(x1, y1, x2, y2, x3, y3, color);
    Citrine_DrawTriangle(x1, y1, x3, y3, x4, y4, color);
}

void Citrine_DrawText(const char* text, float x, float y, int size, uint32_t color) {
    (void)text; (void)x; (void)y; (void)size; (void)color;
}

uint32_t Citrine_LoadTexture(const char* path) {
    (void)path;
    static uint32_t s_next_id = 1;
    return s_next_id++;
}

void Citrine_DrawTexture(uint32_t tex_id, float x, float y, uint32_t tint) {
    (void)tex_id; (void)x; (void)y; (void)tint;
}

void Citrine_DrawTextureRec(uint32_t tex_id, float sx, float sy, float sw, float sh, float dx, float dy, uint32_t tint) {
    (void)tex_id; (void)sx; (void)sy; (void)sw; (void)sh; (void)dx; (void)dy; (void)tint;
}

void Citrine_UnloadTexture(uint32_t tex_id) {
    (void)tex_id;
}
