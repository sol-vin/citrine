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
