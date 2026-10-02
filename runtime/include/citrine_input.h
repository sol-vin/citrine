#ifndef CITRINE_INPUT_H
#define CITRINE_INPUT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BTN_SELECT   =  0,
    BTN_L3       =  1,
    BTN_R3       =  2,
    BTN_START    =  3,
    BTN_UP       =  4,
    BTN_RIGHT    =  5,
    BTN_DOWN     =  6,
    BTN_LEFT     =  7,
    BTN_L2       =  8,
    BTN_R2       =  9,
    BTN_L1       = 10,
    BTN_R1       = 11,
    BTN_TRIANGLE = 12,
    BTN_CIRCLE   = 13,
    BTN_CROSS    = 14,
    BTN_SQUARE   = 15
} CitrineButton;

void  Citrine_InitInput(void);
void  Citrine_PollInput(void);
bool  Citrine_ButtonDown(int button);
bool  Citrine_ButtonPressed(int button);
bool  Citrine_ButtonReleased(int button);
float Citrine_GetAnalog(int axis);
void  Citrine_SetRumble(uint8_t small_motor, uint8_t large_motor);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_INPUT_H
