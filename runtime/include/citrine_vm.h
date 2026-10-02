#ifndef CITRINE_VM_H
#define CITRINE_VM_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 16-byte aligned 128-bit QWORD Value for Emotion Engine
typedef enum {
    VAL_NIL     = 0,
    VAL_BOOL    = 1,
    VAL_INT32   = 2,
    VAL_FLOAT32 = 3,
    VAL_VEC2    = 4,
    VAL_COLOR   = 5,
    VAL_HANDLE  = 6,
    VAL_STRING  = 7,
    VAL_OBJECT  = 8
} ValueType;

typedef struct __attribute__((aligned(16))) {
    uint32_t type;     // 4 bytes: ValueType
    uint32_t flags;    // 4 bytes: metadata / canary
    union {            // 8 bytes: payload
        int32_t  i;
        float    f;
        uint32_t handle;
        const char* str;
        void*    ptr;
        struct { float x, y; } vec2;
        struct { uint8_t r, g, b, a; } color;
    } as;
} Value;

// Scratchpad RAM (SPRAM) mapping on PS2 Emotion Engine
#ifndef HOST_TEST_BUILD
#define SPRAM_BASE ((Value*)0x70000000)
#else
extern Value g_host_spram[1024];
#define SPRAM_BASE (g_host_spram)
#endif

#define MAX_SPRAM_REGISTERS 1024
#define SPRAM_CANARY_VALUE 0xDEADBEEF

// Opcode Definitions
typedef enum {
    OP_NOP         =  0,
    OP_MOVE        =  1,
    OP_LOAD_NIL    =  2,
    OP_LOAD_BOOL   =  3,
    OP_LOAD_INT    =  4,
    OP_LOAD_CONST  =  5,
    OP_ADD         = 10,
    OP_SUB         = 11,
    OP_MUL         = 12,
    OP_DIV         = 13,
    OP_MOD         = 14,
    OP_NEG         = 15,
    OP_VEC2_NEW    = 20,
    OP_VEC2_GETX   = 21,
    OP_VEC2_GETY   = 22,
    OP_VEC2_SETX   = 23,
    OP_VEC2_SETY   = 24,
    OP_VEC2_ADD    = 25,
    OP_COLOR_NEW   = 26,
    OP_EQ          = 30,
    OP_NE          = 31,
    OP_LT          = 32,
    OP_LE          = 33,
    OP_GT          = 34,
    OP_GE          = 35,
    OP_JUMP        = 40,
    OP_JUMP_IF_TRUE  = 41,
    OP_JUMP_IF_FALSE = 42,
    OP_CALL        = 50,
    OP_RETURN      = 51,
    OP_CALL_NATIVE = 52,
    OP_SPAWN_FIBER = 60,
    OP_YIELD       = 61,
    OP_RESUME_FIBER= 62,
    OP_HALT        = 70
} Opcode;

// Call Frame
typedef struct {
    uint32_t return_pc;
    uint16_t reg_base;
    uint8_t  dest_reg;
} CallFrame;

// Zero-GC Arena Allocator
typedef struct {
    uint8_t* buffer;
    size_t   capacity;
    size_t   offset;
} Arena;

// VM State
typedef struct {
    const uint32_t* bytecode;
    uint32_t        bytecode_size;
    uint32_t        pc;
    Value*          spram_regs;     // Points to SPRAM (0x70000000)
    CallFrame       call_stack[64];
    uint32_t        call_depth;
    
    // Constant & String pools
    Value*          constant_pool;
    uint32_t        num_constants;
    char**          string_pool;
    uint32_t        num_strings;

    // Memory Arenas
    Arena           frame_arena;    // Reset every frame at EndDrawing
    Arena           level_arena;    // Reset on level reload

    // Safety & Watchdog
    uint32_t        instruction_count;
    uint32_t        watchdog_limit;
    bool            panic_triggered;
    char            panic_message[128];
} CitrineVM;

// Native FFI Function Prototype
typedef void (*NativeFn)(CitrineVM* vm, Value* args, uint8_t argc, Value* out_ret);

// VM Core Lifecycle API
CitrineVM* citrine_vm_create(const uint8_t* cbc_data, size_t cbc_size);
void       citrine_vm_destroy(CitrineVM* vm);
bool       citrine_vm_step(CitrineVM* vm);
void       citrine_vm_run(CitrineVM* vm);
void       citrine_vm_panic(CitrineVM* vm, const char* format, ...);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_VM_H
