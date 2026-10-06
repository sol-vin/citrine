#include <stdio.h>
#include <math.h>
#include "../include/citrine_draw2d.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

void Citrine_DrawRectangle(float x, float y, float w, float h, uint32_t color) {
    (void)x; (void)y; (void)w; (void)h; (void)color;
#ifndef HOST_TEST_BUILD
    // Emits GS_SET_PRIM(PRIM_SPRITE) DMA packet to Graphic Synthesizer
#endif
}

void Citrine_DrawRectangleRotated(float x, float y, float w, float h, float angle, float ox, float oy, uint32_t color) {
    float rad = (float)(angle * (M_PI / 180.0));
    float c = cosf(rad);
    float s = sinf(rad);

    float corners[4][2] = {
        { 0.0f, 0.0f },
        { w,    0.0f },
        { w,    h    },
        { 0.0f, h    }
    };
    float rx[4], ry[4];
    for (int i = 0; i < 4; i++) {
        float lx = corners[i][0] - ox;
        float ly = corners[i][1] - oy;
        rx[i] = x + (lx * c - ly * s) + ox;
        ry[i] = y + (lx * s + ly * c) + oy;
    }
    Citrine_DrawQuad(rx[0], ry[0], rx[1], ry[1], rx[2], ry[2], rx[3], ry[3], color);
}

void Citrine_DrawRoundedRectangle(float x, float y, float w, float h, float radius, uint32_t color) {
    (void)radius;
    Citrine_DrawRectangle(x, y, w, h, color);
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

void Citrine_DrawTextRotated(const char* text, float x, float y, int size, float angle, float ox, float oy, uint32_t color) {
    (void)text; (void)x; (void)y; (void)size; (void)angle; (void)ox; (void)oy; (void)color;
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

void Citrine_DrawTexturePro(uint32_t tex_id, float sx, float sy, float sw, float sh,
                            float dx, float dy, float dw, float dh,
                            float angle, float ox, float oy, uint32_t tint, uint8_t flip_flags) {
    (void)tex_id; (void)sx; (void)sy; (void)sw; (void)sh; (void)flip_flags;
    if (angle == 0.0f && ox == 0.0f && oy == 0.0f) {
        Citrine_DrawRectangle(dx, dy, dw, dh, tint);
        return;
    }
    Citrine_DrawRectangleRotated(dx, dy, dw, dh, angle, ox, oy, tint);
}

uint32_t Citrine_LoadPalette(const char* path) {
    (void)path;
    static uint32_t s_next_pal_id = 1;
    return s_next_pal_id++;
}

void Citrine_SetPalette(uint32_t pal_id) {
    (void)pal_id;
}

void Citrine_UnloadTexture(uint32_t tex_id) {
    (void)tex_id;
}

