#include <stdio.h>
#include <stdlib.h>
#include "../include/citrine.h"

int main(int argc, char* argv[]) {
    const char* cbc_path = "host:game.cbc";
    if (argc > 1) {
        cbc_path = argv[1];
    }

    printf("[Citrine Runner] Initializing PlayStation 2 Hardware...\n");
    Citrine_InitInput();
    Citrine_InitAudio();
    Citrine_InitWindow(640, 448, "Citrine PS2");

    printf("[Citrine Runner] Loading bytecode from %s...\n", cbc_path);
    FILE* fp = fopen(cbc_path, "rb");
    if (!fp) {
        // Try local relative path
        fp = fopen("game.cbc", "rb");
    }

    if (!fp) {
        fprintf(stderr, "[Citrine Runner] Error: Could not open bytecode file '%s'.\n", cbc_path);
        Citrine_Panic_Trigger(NULL, "Bytecode Load Error", "Could not locate game.cbc", cbc_path, 0);
        return 1;
    }

    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    uint8_t* cbc_data = (uint8_t*)malloc(fsize);
    if (!cbc_data) {
        fclose(fp);
        Citrine_Panic_Trigger(NULL, "Out of Memory", "Failed to allocate buffer for game.cbc", cbc_path, 0);
        return 1;
    }

    fread(cbc_data, 1, fsize, fp);
    fclose(fp);

    printf("[Citrine Runner] Launching Citrine-VM (%ld bytes)...\n", fsize);
    CitrineVM* vm = citrine_vm_create(cbc_data, fsize);
    if (!vm) {
        free(cbc_data);
        Citrine_Panic_Trigger(NULL, "VM Init Error", "Failed to initialize Citrine-VM", cbc_path, 0);
        return 1;
    }

    // Run the game
    citrine_vm_run(vm);

    citrine_vm_destroy(vm);
    free(cbc_data);
    Citrine_CloseWindow();

    return 0;
}
