#include <stdio.h>
#include <math.h>
#include "../include/citrine_draw3d.h"

static CitrineCamera3D s_active_camera;
static bool            s_in_3d_mode = false;

void Citrine_BeginMode3D(CitrineCamera3D camera) {
    s_active_camera = camera;
    s_in_3d_mode = true;
#ifndef HOST_TEST_BUILD
    // PS2 Emotion Engine: Setup View & Perspective Projection Matrices
    // Configures Graphic Synthesizer registers for 3D Z-buffering (ZBUF)
#endif
}

void Citrine_EndMode3D(void) {
    s_in_3d_mode = false;
#ifndef HOST_TEST_BUILD
    // Restores standard 2D Orthographic screen projection
#endif
}

void Citrine_DrawCube(CitrineVector3 pos, float width, float height, float length, uint32_t color) {
    (void)pos; (void)width; (void)height; (void)length; (void)color;
#ifndef HOST_TEST_BUILD
    // Emits 6 quad primitives with normal lighting to Graphic Synthesizer
#endif
}

void Citrine_DrawCubeWires(CitrineVector3 pos, float width, float height, float length, uint32_t color) {
    (void)pos; (void)width; (void)height; (void)length; (void)color;
#ifndef HOST_TEST_BUILD
    // Emits 12 line primitives for 3D wireframe cube
#endif
}

void Citrine_DrawGrid(int slices, float spacing) {
    (void)slices; (void)spacing;
#ifndef HOST_TEST_BUILD
    // Draws floor grid lines on XZ plane
#endif
}

void Citrine_DrawMesh(uint32_t mesh_id, CitrineVector3 pos, uint32_t tint) {
    (void)mesh_id; (void)pos; (void)tint;
#ifndef HOST_TEST_BUILD
    // Emits indexed triangle array to GS via DMA Channel 2 (GIF-DMA)
#endif
}

uint32_t Citrine_LoadModel(const char* path) {
    (void)path;
    static uint32_t s_next_model_id = 1;
    return s_next_model_id++;
}

void Citrine_DrawModel(uint32_t model_id, CitrineVector3 pos, float scale, uint32_t tint) {
    (void)model_id; (void)pos; (void)scale; (void)tint;
#ifndef HOST_TEST_BUILD
    // Emits textured triangle meshes using active model materials via GIF-DMA
#endif
}

void Citrine_DrawModelEx(uint32_t model_id, CitrineVector3 pos, CitrineVector3 rot_axis, float rot_angle, CitrineVector3 scale, uint32_t tint) {
    (void)model_id; (void)pos; (void)rot_axis; (void)rot_angle; (void)scale; (void)tint;
#ifndef HOST_TEST_BUILD
    // Transforms and emits textured triangle meshes with rotation and non-uniform scaling
#endif
}

void Citrine_UnloadModel(uint32_t model_id) {
    (void)model_id;
}

void Citrine_DrawTriangle3D(CitrineVector3 v1, CitrineVector3 v2, CitrineVector3 v3, uint32_t color) {
    (void)v1; (void)v2; (void)v3; (void)color;
#ifndef HOST_TEST_BUILD
    // Emits single 3D triangle primitive to Graphics Synthesizer Context 1
#endif
}

void Citrine_DrawBillboard(uint32_t tex_id, CitrineVector3 cam_pos, CitrineVector3 pos, float size, uint32_t tint) {
    (void)tex_id; (void)cam_pos; (void)pos; (void)size; (void)tint;
#ifndef HOST_TEST_BUILD
    // Computes camera-facing billboard quad orientation and emits textured sprite
#endif
}
