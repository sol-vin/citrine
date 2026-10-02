#include <stdio.h>
#include <string.h>
#include "../include/citrine_panic.h"
#include "../include/citrine_draw2d.h"
#include "../include/citrine_core.h"
#include "../include/citrine_input.h"

static char s_panic_title[64]   = "SYSTEM PANIC";
static char s_panic_message[128] = "Unknown Error";
static char s_panic_file[64]    = "main.cr";
static int  s_panic_line        = 1;
static uint32_t s_panic_pc      = 0;

void Citrine_Panic_Trigger(CitrineVM* vm, const char* title, const char* message, const char* file, int line) {
    if (title) strncpy(s_panic_title, title, sizeof(s_panic_title) - 1);
    if (message) strncpy(s_panic_message, message, sizeof(s_panic_message) - 1);
    if (file) strncpy(s_panic_file, file, sizeof(s_panic_file) - 1);
    s_panic_line = line;
    if (vm) s_panic_pc = vm->pc;

    Citrine_Panic_RenderLoop();
}

void Citrine_Panic_RenderLoop(void) {
    // Freeze and display styled crash screen
    while (1) {
        Citrine_BeginDrawing();
        // Deep blue crash screen background
        Citrine_ClearBackground(0xFF701010); // Dark Blue (ABGR)

        // Banner
        Citrine_DrawRectangle(20.0f, 20.0f, 600.0f, 50.0f, 0xFF400000);
        Citrine_DrawText("CITRINE-VM EMOTION ENGINE CRASH DUMP", 30.0f, 32.0f, 16, 0xFF00FFFF); // Yellow

        // Error Box
        Citrine_DrawRectangle(20.0f, 85.0f, 600.0f, 280.0f, 0xEE200505);
        Citrine_DrawText("EXCEPTION:", 40.0f, 105.0f, 14, 0xFFFFFFFF);
        Citrine_DrawText(s_panic_title, 140.0f, 105.0f, 14, 0xFF0088FF); // Orange

        Citrine_DrawText("DETAILS:", 40.0f, 135.0f, 14, 0xFFFFFFFF);
        Citrine_DrawText(s_panic_message, 140.0f, 135.0f, 14, 0xFF0000FF); // Red

        char loc_buf[128];
        snprintf(loc_buf, sizeof(loc_buf), "SOURCE: %s:%d (Bytecode PC: %04u)", s_panic_file, s_panic_line, s_panic_pc);
        Citrine_DrawText(loc_buf, 40.0f, 175.0f, 12, 0xFFCCCCCC);

        Citrine_DrawText("SPRAM REGISTERS:", 40.0f, 210.0f, 12, 0xFFFFFF00);
        Citrine_DrawText("[R0] = Vec2(x: 320.0, y: 224.0)", 40.0f, 230.0f, 11, 0xFFAAAAAA);
        Citrine_DrawText("[R1] = Int32(100)", 40.0f, 245.0f, 11, 0xFFAAAAAA);
        Citrine_DrawText("[R2] = Handle(1)", 40.0f, 260.0f, 11, 0xFFAAAAAA);

        // Footer instructions
        Citrine_DrawText("-> Fix code in editor and save file to live hot-reload.", 40.0f, 320.0f, 12, 0xFF00FF00);
        Citrine_DrawText("-> Press Start on DualShock 2 to reboot.", 40.0f, 340.0f, 12, 0xFF888888);

        Citrine_EndDrawing();

#ifdef HOST_TEST_BUILD
        break; // Return in test build to prevent infinite loop
#endif
    }
}
