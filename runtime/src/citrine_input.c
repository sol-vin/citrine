#include <stdint.h>
#include <stdbool.h>
#include "../include/citrine_input.h"
#include "../include/citrine_core.h"

static uint16_t s_buttons_curr = 0;
static uint16_t s_buttons_prev = 0;
static float    s_analogs[4]   = {0.0f, 0.0f, 0.0f, 0.0f};
static uint32_t s_input_polled_frame = 0xFFFFFFFF;

#ifdef _WIN32
#include <windows.h>
#endif

void Citrine_InitInput(void) {
    s_buttons_curr = 0;
    s_buttons_prev = 0;
    s_input_polled_frame = 0xFFFFFFFF;
#ifndef HOST_TEST_BUILD
    // PS2SDK SIF RPC module load: rom0:SIO2MAN, rom0:PADMAN
    // padInit(0);
    // padPortOpen(0, 0, pad_buf);
#endif
}

void Citrine_PollInput(void) {
    s_buttons_prev = s_buttons_curr;
#if defined(_WIN32)
    uint16_t mask = 0;
    // Map keyboard to PS2 DualShock 2 buttons:
    // Cross = 14 (mapped to 'X' key, Space, or Enter)
    if ((GetAsyncKeyState('X') & 0x8000) || (GetAsyncKeyState(VK_SPACE) & 0x8000) || (GetAsyncKeyState(VK_RETURN) & 0x8000)) mask |= (1 << 14);
    // Circle = 13 (mapped to 'C' key)
    if (GetAsyncKeyState('C') & 0x8000) mask |= (1 << 13);
    // Square = 15 (mapped to 'Z' key)
    if (GetAsyncKeyState('Z') & 0x8000) mask |= (1 << 15);
    // Triangle = 12 (mapped to 'V' key)
    if (GetAsyncKeyState('V') & 0x8000) mask |= (1 << 12);
    // D-Pad: Up=4, Right=5, Down=6, Left=7
    if (GetAsyncKeyState(VK_UP) & 0x8000) mask |= (1 << 4);
    if (GetAsyncKeyState(VK_RIGHT) & 0x8000) mask |= (1 << 5);
    if (GetAsyncKeyState(VK_DOWN) & 0x8000) mask |= (1 << 6);
    if (GetAsyncKeyState(VK_LEFT) & 0x8000) mask |= (1 << 7);
    // Start = 3, Select = 0
    if (GetAsyncKeyState(VK_TAB) & 0x8000) mask |= (1 << 0);
    if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) mask |= (1 << 3);
    s_buttons_curr = mask;
#endif
#ifndef HOST_TEST_BUILD
    // Polls pad states using padGetState & padRead
#endif
}

void Citrine_PollInputIfNeeded(void) {
    if (s_input_polled_frame != g_citrine_ctx.frame_count) {
        s_input_polled_frame = g_citrine_ctx.frame_count;
        Citrine_PollInput();
    }
}

bool Citrine_ButtonDown(int button) {
    Citrine_PollInputIfNeeded();
    if (button < 0 || button > 15) return false;
    return (s_buttons_curr & (1 << button)) != 0;
}

bool Citrine_ButtonPressed(int button) {
    Citrine_PollInputIfNeeded();
    if (button < 0 || button > 15) return false;
    return ((s_buttons_curr & (1 << button)) != 0) && ((s_buttons_prev & (1 << button)) == 0);
}

bool Citrine_ButtonReleased(int button) {
    Citrine_PollInputIfNeeded();
    if (button < 0 || button > 15) return false;
    return ((s_buttons_curr & (1 << button)) == 0) && ((s_buttons_prev & (1 << button)) != 0);
}

float Citrine_GetAnalog(int axis) {
    if (axis < 0 || axis > 3) return 0.0f;
    return s_analogs[axis];
}

void Citrine_SetRumble(uint8_t small_motor, uint8_t large_motor) {
    (void)small_motor;
    (void)large_motor;
#ifndef HOST_TEST_BUILD
    // padSetActDirect(0, 0, actuators);
#endif
}
