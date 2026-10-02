#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "../include/citrine_vm.h"
#include "../include/citrine_core.h"
#include "../include/citrine_draw2d.h"
#include "../include/citrine_draw3d.h"
#include "../include/citrine_input.h"
#include "../include/citrine_audio.h"
#include "../include/citrine_hud.h"
#include "../include/citrine_panic.h"

#ifdef HOST_TEST_BUILD
Value g_host_spram[1024];
#endif

// Forward declaration of native dispatch table
static void native_dispatch(CitrineVM* vm, uint16_t native_id, Value* args, uint8_t argc, Value* out_ret);

CitrineVM* citrine_vm_create(const uint8_t* cbc_data, size_t cbc_size) {
    if (cbc_size < 18 || memcmp(cbc_data, "CBC1", 4) != 0) {
        fprintf(stderr, "[CitrineVM] Error: Invalid bytecode magic header\n");
        return NULL;
    }

    CitrineVM* vm = (CitrineVM*)calloc(1, sizeof(CitrineVM));
    if (!vm) return NULL;

    const uint8_t* ptr = cbc_data + 4;
    uint16_t version = *(uint16_t*)ptr; ptr += 2;
    (void)version;
    uint32_t num_funcs = *(uint32_t*)ptr; ptr += 4;
    (void)num_funcs;
    vm->num_constants = *(uint32_t*)ptr; ptr += 4;
    vm->num_strings = *(uint32_t*)ptr; ptr += 4;

    // Allocate & read string pool
    if (vm->num_strings > 0) {
        vm->string_pool = (char**)calloc(vm->num_strings, sizeof(char*));
        for (uint32_t i = 0; i < vm->num_strings; i++) {
            uint32_t len = *(uint32_t*)ptr; ptr += 4;
            vm->string_pool[i] = (char*)malloc(len + 1);
            memcpy(vm->string_pool[i], ptr, len);
            vm->string_pool[i][len] = '\0';
            ptr += len;
        }
    }

    // Allocate & read constant pool
    if (vm->num_constants > 0) {
        vm->constant_pool = (Value*)calloc(vm->num_constants, sizeof(Value));
        for (uint32_t i = 0; i < vm->num_constants; i++) {
            uint8_t type = *ptr++;
            vm->constant_pool[i].type = type;
            switch (type) {
                case VAL_INT32:
                case VAL_COLOR:
                    vm->constant_pool[i].as.i = *(int32_t*)ptr;
                    ptr += 4;
                    break;
                case VAL_FLOAT32:
                    vm->constant_pool[i].as.f = *(float*)ptr;
                    ptr += 4;
                    break;
                case VAL_VEC2:
                    vm->constant_pool[i].as.vec2.x = *(float*)ptr; ptr += 4;
                    vm->constant_pool[i].as.vec2.y = *(float*)ptr; ptr += 4;
                    break;
                case VAL_BOOL:
                    vm->constant_pool[i].as.i = *ptr++;
                    break;
                case VAL_STRING: {
                    uint32_t s_idx = *(uint32_t*)ptr; ptr += 4;
                    vm->constant_pool[i].as.str = vm->string_pool[s_idx];
                    break;
                }
                default:
                    ptr += 4;
                    break;
            }
        }
    }

    // Read function table to locate entrypoint (main is the last function)
    uint32_t main_code_offset = 0;
    for (uint32_t i = 0; i < num_funcs; i++) {
        ptr += 4; // name_idx
        ptr += 1; // argc
        ptr += 1; // num_registers
        uint32_t offset = *(uint32_t*)ptr; ptr += 4;
        ptr += 4; // count
        main_code_offset = offset;
    }

    // Bytecode instructions start here
    vm->bytecode = (const uint32_t*)ptr;
    vm->bytecode_size = (cbc_size - (ptr - cbc_data)) / 4;
    vm->pc = main_code_offset;

    // Pin SPRAM register window to PS2 Scratchpad RAM (0x70000000)
    vm->spram_regs = SPRAM_BASE;
    memset(vm->spram_regs, 0, sizeof(Value) * MAX_SPRAM_REGISTERS);
    vm->spram_regs[1023].flags = SPRAM_CANARY_VALUE; // SPRAM Stack Canary

    // Initialize Memory Arenas
    vm->frame_arena.capacity = 512 * 1024; // 512 KB
    vm->frame_arena.buffer = (uint8_t*)malloc(vm->frame_arena.capacity);
    vm->frame_arena.offset = 0;

    vm->level_arena.capacity = 2 * 1024 * 1024; // 2 MB
    vm->level_arena.buffer = (uint8_t*)malloc(vm->level_arena.capacity);
    vm->level_arena.offset = 0;

    vm->watchdog_limit = 5000000; // 5M instructions per frame max

    return vm;
}

void citrine_vm_destroy(CitrineVM* vm) {
    if (!vm) return;
    if (vm->frame_arena.buffer) free(vm->frame_arena.buffer);
    if (vm->level_arena.buffer) free(vm->level_arena.buffer);
    if (vm->string_pool) {
        for (uint32_t i = 0; i < vm->num_strings; i++) {
            free(vm->string_pool[i]);
        }
        free(vm->string_pool);
    }
    if (vm->constant_pool) free(vm->constant_pool);
    free(vm);
}

void citrine_vm_panic(CitrineVM* vm, const char* format, ...) {
    vm->panic_triggered = true;
    va_list args;
    va_start(args, format);
    vsnprintf(vm->panic_message, sizeof(vm->panic_message), format, args);
    va_end(args);

    fprintf(stderr, "\n[CITRINE PANIC] %s (at PC: %04u)\n", vm->panic_message, vm->pc);
    Citrine_Panic_Trigger(vm, "Citrine-VM Hardware Panic", vm->panic_message, "unknown", 0);
}

void citrine_vm_run(CitrineVM* vm) {
    if (!vm || vm->panic_triggered) return;

    Value* regs = vm->spram_regs;

#if defined(__GNUC__)
    // Direct-Threaded Dispatch using computed goto (GNU labels-as-values)
    static const void* dispatch_table[] = {
        [OP_NOP]          = &&do_nop,
        [OP_MOVE]         = &&do_move,
        [OP_LOAD_NIL]     = &&do_load_nil,
        [OP_LOAD_BOOL]    = &&do_load_bool,
        [OP_LOAD_INT]     = &&do_load_int,
        [OP_LOAD_CONST]   = &&do_load_const,
        [OP_ADD]          = &&do_add,
        [OP_SUB]          = &&do_sub,
        [OP_MUL]          = &&do_mul,
        [OP_DIV]          = &&do_div,
        [OP_MOD]          = &&do_mod,
        [OP_NEG]          = &&do_neg,
        [OP_VEC2_NEW]     = &&do_vec2_new,
        [OP_VEC2_GETX]    = &&do_vec2_getx,
        [OP_VEC2_GETY]    = &&do_vec2_gety,
        [OP_VEC2_SETX]    = &&do_vec2_setx,
        [OP_VEC2_SETY]    = &&do_vec2_sety,
        [OP_VEC2_ADD]     = &&do_vec2_add,
        [OP_COLOR_NEW]    = &&do_color_new,
        [OP_EQ]           = &&do_eq,
        [OP_NE]           = &&do_ne,
        [OP_LT]           = &&do_lt,
        [OP_LE]           = &&do_le,
        [OP_GT]           = &&do_gt,
        [OP_GE]           = &&do_ge,
        [OP_JUMP]         = &&do_jump,
        [OP_JUMP_IF_TRUE] = &&do_jump_if_true,
        [OP_JUMP_IF_FALSE]= &&do_jump_if_false,
        [OP_CALL]         = &&do_call,
        [OP_RETURN]       = &&do_return,
        [OP_CALL_NATIVE]  = &&do_call_native,
        [OP_SPAWN_FIBER]  = &&do_spawn_fiber,
        [OP_YIELD]        = &&do_yield,
        [OP_RESUME_FIBER] = &&do_resume_fiber,
        [OP_HALT]         = &&do_halt
    };

    #define DISPATCH() do { \
        if (++vm->instruction_count > vm->watchdog_limit) { \
            citrine_vm_panic(vm, "Instruction Watchdog Timeout (> 5M instructions without yield)"); \
            return; \
        } \
        uint32_t instr_word = vm->bytecode[vm->pc++]; \
        uint8_t op = (instr_word >> 24) & 0xFF; \
        goto *dispatch_table[op]; \
    } while (0)

    DISPATCH();

    do_nop:
        DISPATCH();

    do_move: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t src = (raw >> 8) & 0xFF;
        regs[dst] = regs[src];
        DISPATCH();
    }

    do_load_nil: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        regs[dst].type = VAL_NIL;
        DISPATCH();
    }

    do_load_bool: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint16_t imm = raw & 0xFFFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (imm != 0);
        DISPATCH();
    }

    do_load_int: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        int16_t imm = (int16_t)(raw & 0xFFFF);
        regs[dst].type = VAL_INT32;
        regs[dst].as.i = imm;
        DISPATCH();
    }

    do_load_const: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint16_t c_idx = raw & 0xFFFF;
        if (c_idx < vm->num_constants) {
            regs[dst] = vm->constant_pool[c_idx];
        }
        DISPATCH();
    }

    do_add: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
            float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
            float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
            regs[dst].type = VAL_FLOAT32;
            regs[dst].as.f = fa + fb;
        } else {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i + regs[b].as.i;
        }
        DISPATCH();
    }

    do_sub: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
            float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
            float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
            regs[dst].type = VAL_FLOAT32;
            regs[dst].as.f = fa - fb;
        } else {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i - regs[b].as.i;
        }
        DISPATCH();
    }

    do_mul: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
            float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
            float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
            regs[dst].type = VAL_FLOAT32;
            regs[dst].as.f = fa * fb;
        } else {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i * regs[b].as.i;
        }
        DISPATCH();
    }

    do_div: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
        if (fb == 0.0f) {
            citrine_vm_panic(vm, "Division by zero");
            return;
        }
        float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
        regs[dst].type = VAL_FLOAT32;
        regs[dst].as.f = fa / fb;
        DISPATCH();
    }

    do_mod: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        if (regs[b].as.i == 0) {
            citrine_vm_panic(vm, "Modulo by zero");
            return;
        }
        regs[dst].type = VAL_INT32;
        regs[dst].as.i = regs[a].as.i % regs[b].as.i;
        DISPATCH();
    }

    do_neg: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        if (regs[a].type == VAL_FLOAT32) {
            regs[dst].type = VAL_FLOAT32;
            regs[dst].as.f = -regs[a].as.f;
        } else {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = -regs[a].as.i;
        }
        DISPATCH();
    }

    do_vec2_new: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_VEC2;
        regs[dst].as.vec2.x = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
        regs[dst].as.vec2.y = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
        DISPATCH();
    }

    do_vec2_getx: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        regs[dst].type = VAL_FLOAT32;
        regs[dst].as.f = regs[a].as.vec2.x;
        DISPATCH();
    }

    do_vec2_gety: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        regs[dst].type = VAL_FLOAT32;
        regs[dst].as.f = regs[a].as.vec2.y;
        DISPATCH();
    }

    do_vec2_setx: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        regs[dst].as.vec2.x = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
        DISPATCH();
    }

    do_vec2_sety: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        regs[dst].as.vec2.y = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
        DISPATCH();
    }

    do_vec2_add: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_VEC2;
        regs[dst].as.vec2.x = regs[a].as.vec2.x + regs[b].as.vec2.x;
        regs[dst].as.vec2.y = regs[a].as.vec2.y + regs[b].as.vec2.y;
        DISPATCH();
    }

    do_color_new: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_COLOR;
        regs[dst].as.color.r = (uint8_t)regs[a].as.i;
        regs[dst].as.color.g = (uint8_t)regs[b].as.i;
        regs[dst].as.color.b = 0;
        regs[dst].as.color.a = 255;
        DISPATCH();
    }

    do_eq: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (regs[a].as.i == regs[b].as.i);
        DISPATCH();
    }

    do_ne: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (regs[a].as.i != regs[b].as.i);
        DISPATCH();
    }

    do_lt: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
            float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
            float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
            regs[dst].as.i = (fa < fb);
        } else {
            regs[dst].as.i = (regs[a].as.i < regs[b].as.i);
        }
        DISPATCH();
    }

    do_le: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (regs[a].as.i <= regs[b].as.i);
        DISPATCH();
    }

    do_gt: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (regs[a].as.i > regs[b].as.i);
        DISPATCH();
    }

    do_ge: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t a = (raw >> 8) & 0xFF;
        uint8_t b = raw & 0xFF;
        regs[dst].type = VAL_BOOL;
        regs[dst].as.i = (regs[a].as.i >= regs[b].as.i);
        DISPATCH();
    }

    do_jump: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        int16_t offset = (int16_t)(raw & 0xFFFF);
        vm->pc += offset;
        DISPATCH();
    }

    do_jump_if_true: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t cond_reg = (raw >> 16) & 0xFF;
        int16_t offset = (int16_t)(raw & 0xFFFF);
        if (regs[cond_reg].type == VAL_BOOL && regs[cond_reg].as.i != 0) {
            vm->pc += offset;
        }
        DISPATCH();
    }

    do_jump_if_false: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t cond_reg = (raw >> 16) & 0xFF;
        int16_t offset = (int16_t)(raw & 0xFFFF);
        if (regs[cond_reg].type == VAL_NIL || (regs[cond_reg].type == VAL_BOOL && regs[cond_reg].as.i == 0)) {
            vm->pc += offset;
        }
        DISPATCH();
    }

    do_call: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t base = (raw >> 8) & 0xFF;
        (void)base;
        // Function call handling
        if (vm->call_depth >= 63) {
            citrine_vm_panic(vm, "Stack Overflow: call depth exceeded 64 frames");
            return;
        }
        vm->call_stack[vm->call_depth].return_pc = vm->pc;
        vm->call_stack[vm->call_depth].dest_reg = dst;
        vm->call_depth++;
        DISPATCH();
    }

    do_return: {
        if (vm->call_depth == 0) {
            // Exit program
            return;
        }
        vm->call_depth--;
        vm->pc = vm->call_stack[vm->call_depth].return_pc;
        DISPATCH();
    }

    do_call_native: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = (raw >> 16) & 0xFF;
        uint8_t base = (raw >> 8) & 0xFF;
        uint16_t native_id = raw & 0xFF; // bottom 8 or 16 bits
        native_dispatch(vm, native_id, &regs[base], 0, &regs[dst]);
        DISPATCH();
    }

    do_spawn_fiber:
    do_yield:
    do_resume_fiber:
        DISPATCH();

    do_halt:
        return;

#endif
}

static void native_dispatch(CitrineVM* vm, uint16_t native_id, Value* args, uint8_t argc, Value* out_ret) {
    (void)argc;
    switch (native_id) {
        case 1: // InitWindow(w, h, title)
            Citrine_InitWindow(args[0].as.i, args[1].as.i, args[2].as.str);
            break;
        case 2: // CloseWindow()
            Citrine_CloseWindow();
            break;
        case 3: // WindowOpen()
            out_ret->type = VAL_BOOL;
            out_ret->as.i = Citrine_WindowOpen();
            break;
        case 4: // SetTargetFPS(fps)
            Citrine_SetTargetFPS(args[0].as.i);
            break;
        case 5: // GetFPS()
            out_ret->type = VAL_FLOAT32;
            out_ret->as.f = Citrine_GetFPS();
            break;
        case 6: // GetDeltaTime()
            out_ret->type = VAL_FLOAT32;
            out_ret->as.f = Citrine_GetDeltaTime();
            break;
        case 10: // BeginDrawing()
            Citrine_BeginDrawing();
            break;
        case 11: // EndDrawing()
            Citrine_EndDrawing();
            // Zero-GC: Reset Frame Bump Arena every frame
            vm->frame_arena.offset = 0;
            vm->instruction_count = 0; // Reset watchdog
            break;
        case 12: // ClearBackground(color)
            Citrine_ClearBackground((uint32_t)args[0].as.i);
            break;
        case 20: // DrawRectangle(x, y, w, h, color)
            Citrine_DrawRectangle(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i,
                (uint32_t)args[4].as.i
            );
            break;
        case 21: // DrawCircle(cx, cy, r, color)
            Citrine_DrawCircle(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (uint32_t)args[3].as.i
            );
            break;
        case 22: // DrawLine(x1, y1, x2, y2, color)
            Citrine_DrawLine(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i,
                (uint32_t)args[4].as.i
            );
            break;
        case 24: // DrawText(text, x, y, size, color)
            Citrine_DrawText(
                args[0].as.str ? args[0].as.str : "",
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                args[3].as.i,
                (uint32_t)args[4].as.i
            );
            break;
        case 25: { // BeginMode3D(cam)
            CitrineCamera3D cam = {0};
            Citrine_BeginMode3D(cam);
            break;
        }
        case 26: // EndMode3D()
            Citrine_EndMode3D();
            break;
        case 27: { // DrawCube(pos_x, pos_y, pos_z, w, h, l, color)
            CitrineVector3 pos = {
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i
            };
            float w = (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i;
            float h = (args[4].type == VAL_FLOAT32) ? args[4].as.f : (float)args[4].as.i;
            float l = (args[5].type == VAL_FLOAT32) ? args[5].as.f : (float)args[5].as.i;
            Citrine_DrawCube(pos, w, h, l, (uint32_t)args[6].as.i);
            break;
        }
        case 28: { // DrawCubeWires(pos_x, pos_y, pos_z, w, h, l, color)
            CitrineVector3 pos = {
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i
            };
            float w = (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i;
            float h = (args[4].type == VAL_FLOAT32) ? args[4].as.f : (float)args[4].as.i;
            float l = (args[5].type == VAL_FLOAT32) ? args[5].as.f : (float)args[5].as.i;
            Citrine_DrawCubeWires(pos, w, h, l, (uint32_t)args[6].as.i);
            break;
        }
        case 29: // DrawGrid(slices, spacing)
            Citrine_DrawGrid(args[0].as.i, (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i);
            break;
        case 34: { // DrawMesh(mesh_id, pos_x, pos_y, pos_z, tint)
            CitrineVector3 pos = {
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i
            };
            Citrine_DrawMesh(args[0].as.handle, pos, (uint32_t)args[4].as.i);
            break;
        }
        case 30: // LoadTexture(path)
            out_ret->type = VAL_HANDLE;
            out_ret->as.handle = Citrine_LoadTexture(args[0].as.str);
            break;
        case 31: // DrawTexture(id, x, y, tint)
            Citrine_DrawTexture(
                args[0].as.handle,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (uint32_t)args[3].as.i
            );
            break;
        case 40: // ButtonDown(btn)
            out_ret->type = VAL_BOOL;
            out_ret->as.i = Citrine_ButtonDown(args[0].as.i);
            break;
        case 41: // ButtonPressed(btn)
            out_ret->type = VAL_BOOL;
            out_ret->as.i = Citrine_ButtonPressed(args[0].as.i);
            break;
        case 43: // GetAnalog(axis)
            out_ret->type = VAL_FLOAT32;
            out_ret->as.f = Citrine_GetAnalog(args[0].as.i);
            break;
        case 60: // SetDebugOverlay(bool)
            Citrine_HUD_SetVisible(args[0].as.i != 0);
            break;
        case 99: // Panic(msg)
            citrine_vm_panic(vm, "%s", args[0].as.str ? args[0].as.str : "User Panic");
            break;
        default:
            break;
    }
}
