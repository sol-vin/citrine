#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../include/citrine_gl.h"
#include "../include/citrine_draw2d.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static CitrineGLContext s_gl_ctx;

static void matrix_identity(CitrineGLMatrix* mat) {
    memset(mat->m, 0, sizeof(mat->m));
    mat->m[0]  = 1.0f;
    mat->m[5]  = 1.0f;
    mat->m[10] = 1.0f;
    mat->m[15] = 1.0f;
}

static void matrix_multiply(CitrineGLMatrix* out, const CitrineGLMatrix* a, const CitrineGLMatrix* b) {
    CitrineGLMatrix res;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float sum = 0.0f;
            for (int k = 0; k < 4; k++) {
                sum += a->m[k * 4 + j] * b->m[i * 4 + k];
            }
            res.m[i * 4 + j] = sum;
        }
    }
    *out = res;
}

static void matrix_transform_point(const CitrineGLMatrix* mat, float in_x, float in_y, float in_z, float* out_x, float* out_y, float* out_z) {
    *out_x = mat->m[0] * in_x + mat->m[4] * in_y + mat->m[8]  * in_z + mat->m[12];
    *out_y = mat->m[1] * in_x + mat->m[5] * in_y + mat->m[9]  * in_z + mat->m[13];
    *out_z = mat->m[2] * in_x + mat->m[6] * in_y + mat->m[10] * in_z + mat->m[14];
}

void Citrine_GL_Init(void) {
    memset(&s_gl_ctx, 0, sizeof(s_gl_ctx));
    s_gl_ctx.current_color = 0xFFFFFFFF;
    s_gl_ctx.matrix_top = 0;
    matrix_identity(&s_gl_ctx.matrix_stack[0]);
}

void Citrine_GL_Begin(int mode) {
    s_gl_ctx.mode = (CitrineGLMode)mode;
    s_gl_ctx.in_begin = true;
    s_gl_ctx.vertex_count = 0;
}

void Citrine_GL_End(void) {
    if (!s_gl_ctx.in_begin) return;
    s_gl_ctx.in_begin = false;

    uint32_t count = s_gl_ctx.vertex_count;
    if (count == 0) return;

    CitrineGLVertex* v = s_gl_ctx.vertices;

    switch (s_gl_ctx.mode) {
        case CITRINE_GL_POINTS: {
            for (uint32_t i = 0; i < count; i++) {
                Citrine_DrawRectangle(v[i].x, v[i].y, 1.0f, 1.0f, v[i].color);
            }
            break;
        }
        case CITRINE_GL_LINES: {
            for (uint32_t i = 0; i + 1 < count; i += 2) {
                Citrine_DrawLine(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i].color);
            }
            break;
        }
        case CITRINE_GL_LINE_STRIP: {
            for (uint32_t i = 0; i + 1 < count; i++) {
                Citrine_DrawLine(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i].color);
            }
            break;
        }
        case CITRINE_GL_LINE_LOOP: {
            if (count > 1) {
                for (uint32_t i = 0; i + 1 < count; i++) {
                    Citrine_DrawLine(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i].color);
                }
                Citrine_DrawLine(v[count - 1].x, v[count - 1].y, v[0].x, v[0].y, v[count - 1].color);
            }
            break;
        }
        case CITRINE_GL_TRIANGLES: {
            for (uint32_t i = 0; i + 2 < count; i += 3) {
                Citrine_DrawTriangle(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i + 2].x, v[i + 2].y, v[i].color);
            }
            break;
        }
        case CITRINE_GL_TRIANGLE_STRIP: {
            for (uint32_t i = 0; i + 2 < count; i++) {
                if ((i & 1) == 0) {
                    Citrine_DrawTriangle(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i + 2].x, v[i + 2].y, v[i].color);
                } else {
                    Citrine_DrawTriangle(v[i + 1].x, v[i + 1].y, v[i].x, v[i].y, v[i + 2].x, v[i + 2].y, v[i].color);
                }
            }
            break;
        }
        case CITRINE_GL_TRIANGLE_FAN: {
            if (count >= 3) {
                for (uint32_t i = 1; i + 1 < count; i++) {
                    Citrine_DrawTriangle(v[0].x, v[0].y, v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[0].color);
                }
            }
            break;
        }
        case CITRINE_GL_QUADS: {
            // Granular opcode decomposition: quad decomposes into TWO triangles!
            for (uint32_t i = 0; i + 3 < count; i += 4) {
                // Triangle 1: (v[i], v[i+1], v[i+2])
                Citrine_DrawTriangle(v[i].x, v[i].y, v[i + 1].x, v[i + 1].y, v[i + 2].x, v[i + 2].y, v[i].color);
                // Triangle 2: (v[i], v[i+2], v[i+3])
                Citrine_DrawTriangle(v[i].x, v[i].y, v[i + 2].x, v[i + 2].y, v[i + 3].x, v[i + 3].y, v[i].color);
            }
            break;
        }
    }
}

void Citrine_GL_Color4f(float r, float g, float b, float a) {
    uint8_t ur = (uint8_t)(r * 255.0f);
    uint8_t ug = (uint8_t)(g * 255.0f);
    uint8_t ub = (uint8_t)(b * 255.0f);
    uint8_t ua = (uint8_t)(a * 255.0f);
    Citrine_GL_Color4ub(ur, ug, ub, ua);
}

void Citrine_GL_Color4ub(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    s_gl_ctx.current_color = ((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)g << 8) | (uint32_t)r;
}

void Citrine_GL_ColorHex(uint32_t hex) {
    s_gl_ctx.current_color = hex;
}

void Citrine_GL_TexCoord2f(float u, float v) {
    s_gl_ctx.current_u = u;
    s_gl_ctx.current_v = v;
}

void Citrine_GL_Vertex2f(float x, float y) {
    Citrine_GL_Vertex3f(x, y, 0.0f);
}

void Citrine_GL_Vertex3f(float x, float y, float z) {
    if (!s_gl_ctx.in_begin) return;
    if (s_gl_ctx.vertex_count >= CITRINE_GL_MAX_VERTICES) return;

    float tx, ty, tz;
    matrix_transform_point(&s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], x, y, z, &tx, &ty, &tz);

    CitrineGLVertex* vert = &s_gl_ctx.vertices[s_gl_ctx.vertex_count++];
    vert->x = tx;
    vert->y = ty;
    vert->z = tz;
    vert->u = s_gl_ctx.current_u;
    vert->v = s_gl_ctx.current_v;
    vert->color = s_gl_ctx.current_color;
}

void Citrine_GL_PushMatrix(void) {
    if (s_gl_ctx.matrix_top + 1 < CITRINE_GL_MATRIX_STACK_SIZE) {
        s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top + 1] = s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top];
        s_gl_ctx.matrix_top++;
    }
}

void Citrine_GL_PopMatrix(void) {
    if (s_gl_ctx.matrix_top > 0) {
        s_gl_ctx.matrix_top--;
    }
}

void Citrine_GL_LoadIdentity(void) {
    matrix_identity(&s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top]);
}

void Citrine_GL_Translate(float x, float y, float z) {
    CitrineGLMatrix trans;
    matrix_identity(&trans);
    trans.m[12] = x;
    trans.m[13] = y;
    trans.m[14] = z;
    matrix_multiply(&s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &trans);
}

void Citrine_GL_Scale(float x, float y, float z) {
    CitrineGLMatrix s;
    matrix_identity(&s);
    s.m[0]  = x;
    s.m[5]  = y;
    s.m[10] = z;
    matrix_multiply(&s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &s);
}

void Citrine_GL_Rotate(float angle_deg, float x, float y, float z) {
    float rad = (float)(angle_deg * (M_PI / 180.0));
    float c = cosf(rad);
    float s = sinf(rad);

    float len = sqrtf(x * x + y * y + z * z);
    if (len == 0.0f) return;
    x /= len; y /= len; z /= len;

    CitrineGLMatrix rot;
    matrix_identity(&rot);
    rot.m[0] = x*x*(1 - c) + c;
    rot.m[1] = y*x*(1 - c) + z*s;
    rot.m[2] = z*x*(1 - c) - y*s;

    rot.m[4] = x*y*(1 - c) - z*s;
    rot.m[5] = y*y*(1 - c) + c;
    rot.m[6] = z*y*(1 - c) + x*s;

    rot.m[8] = x*z*(1 - c) + y*s;
    rot.m[9] = y*z*(1 - c) - x*s;
    rot.m[10] = z*z*(1 - c) + c;

    matrix_multiply(&s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &s_gl_ctx.matrix_stack[s_gl_ctx.matrix_top], &rot);
}
