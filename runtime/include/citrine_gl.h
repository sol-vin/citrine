#ifndef CITRINE_GL_H
#define CITRINE_GL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CITRINE_GL_POINTS         = 0,
    CITRINE_GL_LINES          = 1,
    CITRINE_GL_LINE_STRIP     = 2,
    CITRINE_GL_LINE_LOOP      = 3,
    CITRINE_GL_TRIANGLES      = 4,
    CITRINE_GL_TRIANGLE_STRIP = 5,
    CITRINE_GL_TRIANGLE_FAN   = 6,
    CITRINE_GL_QUADS          = 7
} CitrineGLMode;

typedef struct {
    float x, y, z;
    float u, v;
    uint32_t color;
} CitrineGLVertex;

typedef struct {
    float m[16];
} CitrineGLMatrix;

#define CITRINE_GL_MAX_VERTICES 256
#define CITRINE_GL_MATRIX_STACK_SIZE 16

typedef struct {
    CitrineGLMode mode;
    bool in_begin;
    uint32_t current_color;
    float current_u, current_v;
    CitrineGLVertex vertices[CITRINE_GL_MAX_VERTICES];
    uint32_t vertex_count;

    CitrineGLMatrix matrix_stack[CITRINE_GL_MATRIX_STACK_SIZE];
    uint32_t matrix_top;
} CitrineGLContext;

void Citrine_GL_Init(void);
void Citrine_GL_Begin(int mode);
void Citrine_GL_End(void);
void Citrine_GL_Color4f(float r, float g, float b, float a);
void Citrine_GL_Color4ub(uint8_t r, uint8_t g, uint8_t b, uint8_t a);
void Citrine_GL_ColorHex(uint32_t hex);
void Citrine_GL_TexCoord2f(float u, float v);
void Citrine_GL_Vertex2f(float x, float y);
void Citrine_GL_Vertex3f(float x, float y, float z);

void Citrine_GL_PushMatrix(void);
void Citrine_GL_PopMatrix(void);
void Citrine_GL_LoadIdentity(void);
void Citrine_GL_Translate(float x, float y, float z);
void Citrine_GL_Rotate(float angle_deg, float x, float y, float z);
void Citrine_GL_Scale(float x, float y, float z);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_GL_H
