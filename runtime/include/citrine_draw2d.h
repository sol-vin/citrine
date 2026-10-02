#ifndef CITRINE_DRAW2D_H
#define CITRINE_DRAW2D_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void Citrine_DrawRectangle(float x, float y, float w, float h, uint32_t color);
void Citrine_DrawCircle(float cx, float cy, float radius, uint32_t color);
void Citrine_DrawLine(float x1, float y1, float x2, float y2, uint32_t color);
void Citrine_DrawTriangle(float x1, float y1, float x2, float y2, float x3, float y3, uint32_t color);
void Citrine_DrawQuad(float x1, float y1, float x2, float y2, float x3, float y3, float x4, float y4, uint32_t color);
void Citrine_DrawText(const char* text, float x, float y, int size, uint32_t color);

uint32_t Citrine_LoadTexture(const char* path);
void Citrine_DrawTexture(uint32_t tex_id, float x, float y, uint32_t tint);
void Citrine_DrawTextureRec(uint32_t tex_id, float sx, float sy, float sw, float sh, float dx, float dy, uint32_t tint);
void Citrine_UnloadTexture(uint32_t tex_id);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_DRAW2D_H
