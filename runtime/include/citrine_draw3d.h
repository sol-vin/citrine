#ifndef CITRINE_DRAW3D_H
#define CITRINE_DRAW3D_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x;
    float y;
    float z;
} CitrineVector3;

typedef struct {
    CitrineVector3 position;
    CitrineVector3 target;
    CitrineVector3 up;
    float          fovy;
    int            projection; // 0: Perspective, 1: Orthographic
} CitrineCamera3D;

void Citrine_BeginMode3D(CitrineCamera3D camera);
void Citrine_EndMode3D(void);
void Citrine_DrawCube(CitrineVector3 pos, float width, float height, float length, uint32_t color);
void Citrine_DrawCubeWires(CitrineVector3 pos, float width, float height, float length, uint32_t color);
void Citrine_DrawGrid(int slices, float spacing);
void Citrine_DrawMesh(uint32_t mesh_id, CitrineVector3 pos, uint32_t tint);
uint32_t Citrine_LoadModel(const char* path);
void Citrine_DrawModel(uint32_t model_id, CitrineVector3 pos, float scale, uint32_t tint);
void Citrine_DrawModelEx(uint32_t model_id, CitrineVector3 pos, CitrineVector3 rot_axis, float rot_angle, CitrineVector3 scale, uint32_t tint);
void Citrine_UnloadModel(uint32_t model_id);
void Citrine_DrawTriangle3D(CitrineVector3 v1, CitrineVector3 v2, CitrineVector3 v3, uint32_t color);
void Citrine_DrawBillboard(uint32_t tex_id, CitrineVector3 cam_pos, CitrineVector3 pos, float size, uint32_t tint);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_DRAW3D_H
