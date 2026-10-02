#include <stdint.h>
#include <stdbool.h>
#include "../include/citrine_input.h"

static uint16_t s_buttons_curr = 0;
static uint16_t s_buttons_prev = 0;
static float    s_analogs[4]   = {0.0f, 0.0f, 0.0f, 0.0f};

void Citrine_InitInput(void) {
#ifndef HOST_TEST_BUILD
    // PS2SDK SIF RPC module load: rom0:SIO2MAN, rom0:PADMAN
    // padInit(0);
    // padPortOpen(0, 0, pad_buf);
#endif
}

void Citrine_PollInput(void) {
    s_buttons_prev = s_buttons_curr;
#ifndef HOST_TEST_BUILD
    // Polls pad states using padGetState & padRead
#endif
}

bool Citrine_ButtonDown(int button) {
    if (button < 0 || button > 15) return false;
    return (s_buttons_curr & (1 << button)) != 0;
}

bool Citrine_ButtonPressed(int button) {
    if (button < 0 || button > 15) return false;
    return ((s_buttons_curr & (1 << button)) != 0) && ((s_buttons_prev & (1 << button)) == 0);
}

bool Citrine_ButtonReleased(int button) {
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
