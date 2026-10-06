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

// Citrine Object Header (Classes & Structs)
typedef struct {
    uint32_t class_id;
    uint32_t field_count;
    Value*   fields;
} CitrineObject;

// Citrine Array Header (Dynamic & Static Arrays)
typedef struct {
    uint32_t capacity;
    uint32_t size;
    bool     is_static;
    Value*   elements;
} CitrineArray;

// Citrine In-Memory IO Stream (IO::Memory)
typedef struct {
    char*    buffer;
    size_t   capacity;
    size_t   size;
    size_t   pos;
} CitrineMemoryIO;


// Scratchpad RAM (SPRAM) mapping on PS2 Emotion Engine
#ifndef HOST_TEST_BUILD
#define SPRAM_BASE ((Value*)0x70000000)
#else
extern Value g_host_spram[1024];
#define SPRAM_BASE (g_host_spram)
#endif

#define MAX_SPRAM_REGISTERS 1024
#define SPRAM_CANARY_VALUE 0xDEADBEEF

// Citrine-32 Primary Opcodes (0x00..0x1F, 5 bits in [31:27])
typedef enum {
    OP_SYS         = 0x00,
    OP_MOVE        = 0x01,
    OP_LOAD_CONST  = 0x02,
    OP_LOAD_IMM    = 0x03,
    OP_LOAD_MEM    = 0x04,
    OP_STORE_MEM   = 0x05,
    OP_ADD         = 0x06,
    OP_SUB         = 0x07,
    OP_MUL         = 0x08,
    OP_DIV_MOD     = 0x09,
    OP_BITWISE     = 0x0A,
    OP_SHIFT       = 0x0B,
    OP_COMPARE     = 0x0C,
    OP_TEST        = 0x0D,
    OP_FLOAT_ALU   = 0x0E,
    OP_JUMP        = 0x0F,
    OP_BRANCH_Z    = 0x10,
    OP_BRANCH_CMP  = 0x11,
    OP_CALL        = 0x12,
    OP_RETURN      = 0x13,
    OP_CALL_NATIVE = 0x14,
    OP_VEC2_MATH   = 0x15,
    OP_VEC2_PROP   = 0x16,
    OP_COLOR_OP    = 0x17,
    OP_SIMD_MMI    = 0x18,
    OP_COLLECTION  = 0x19,
    OP_FIBER_OP    = 0x1A,
    OP_CHANNEL_OP  = 0x1B,
    OP_PS2_HW      = 0x1C,
    OP_INLINE_ASM  = 0x1D,
    OP_LOOP_DEC_BR = 0x1E,
    OP_FUSED_MADD  = 0x1F
} Opcode;

// Sub-opcode definitions (3 bits in [26:24])
#define SUBOP_SYS_NOP            0
#define SUBOP_SYS_HALT           1
#define SUBOP_SYS_BREAK          2
#define SUBOP_SYS_SYNC           3
#define SUBOP_SYS_FLUSH_ICACHE   4
#define SUBOP_SYS_FLUSH_DCACHE   5
#define SUBOP_SYS_WATCHDOG_RESET 6
#define SUBOP_SYS_PROFILE_MARK   7

#define SUBOP_MOVE_32            0
#define SUBOP_MOVE_64            1
#define SUBOP_MOVE_128           2
#define SUBOP_MOVE_CMOVZ         3
#define SUBOP_MOVE_CMOVN         4
#define SUBOP_MOVE_SWAP          5

#define SUBOP_IMM_NIL            0
#define SUBOP_IMM_BOOL           1
#define SUBOP_IMM_INT16          2
#define SUBOP_IMM_UINT16         3
#define SUBOP_IMM_UPPER16        4
#define SUBOP_IMM_ZERO           5
#define SUBOP_IMM_MINUS1         6

#define SUBOP_MEM_LB             0
#define SUBOP_MEM_LBU            1
#define SUBOP_MEM_LH             2
#define SUBOP_MEM_LHU            3
#define SUBOP_MEM_LW             4
#define SUBOP_MEM_LWC1           5
#define SUBOP_MEM_LD             6
#define SUBOP_MEM_LQ             7

#define SUBOP_ADD_I32            0
#define SUBOP_ADD_U32            1
#define SUBOP_ADD_SAT            2
#define SUBOP_ADD_STR            3
#define SUBOP_ADD_IMM8           4

#define SUBOP_SUB_I32            0
#define SUBOP_SUB_U32            1
#define SUBOP_SUB_SAT            2
#define SUBOP_SUB_NEG            3
#define SUBOP_SUB_IMM8           4

#define SUBOP_MUL_LO             0
#define SUBOP_MUL_HI             1
#define SUBOP_MUL_UHI            2
#define SUBOP_MUL_SAT            3
#define SUBOP_MUL_IMM8           4

#define SUBOP_DIV_S32            0
#define SUBOP_MOD_S32            1
#define SUBOP_DIV_U32            2
#define SUBOP_MOD_U32            3

#define SUBOP_BIT_AND            0
#define SUBOP_BIT_OR             1
#define SUBOP_BIT_XOR            2
#define SUBOP_BIT_NOR            3
#define SUBOP_BIT_AND_NOT        4
#define SUBOP_BIT_XNOR           5

#define SUBOP_SHIFT_SLL          0
#define SUBOP_SHIFT_SRL          1
#define SUBOP_SHIFT_SRA          2
#define SUBOP_SHIFT_ROTL         3
#define SUBOP_SHIFT_ROTR         4
#define SUBOP_SHIFT_CLZ          5

#define SUBOP_CMP_EQ             0
#define SUBOP_CMP_NE             1
#define SUBOP_CMP_LT             2
#define SUBOP_CMP_LE             3
#define SUBOP_CMP_GT             4
#define SUBOP_CMP_GE             5
#define SUBOP_CMP_STR_EQ         6
#define SUBOP_CMP_PTR_EQ         7

#define SUBOP_TEST_NIL           0
#define SUBOP_TEST_NOT_NIL       1
#define SUBOP_TEST_ZERO          2
#define SUBOP_TEST_NOT_ZERO      3
#define SUBOP_TEST_TRUTHY        4
#define SUBOP_TEST_FALSY         5
#define SUBOP_TEST_TAG           6
#define SUBOP_TEST_BIT           7

#define SUBOP_FLOAT_ADD          0
#define SUBOP_FLOAT_SUB          1
#define SUBOP_FLOAT_MUL          2
#define SUBOP_FLOAT_DIV          3
#define SUBOP_FLOAT_NEG          4
#define SUBOP_FLOAT_ABS          5
#define SUBOP_FLOAT_SQRT         6
#define SUBOP_FLOAT_CVT          7

#define SUBOP_JUMP_REL24         0
#define SUBOP_JUMP_REL16         1
#define SUBOP_JUMP_REG           2
#define SUBOP_JUMP_TABLE         3

#define SUBOP_BRZ_TRUTHY         0
#define SUBOP_BRZ_FALSY          1
#define SUBOP_BRZ_ZERO           2
#define SUBOP_BRZ_NONZERO        3
#define SUBOP_BRZ_POS            4
#define SUBOP_BRZ_NEG            5

#define SUBOP_BRCMP_BEQ          0
#define SUBOP_BRCMP_BNE          1
#define SUBOP_BRCMP_BLT          2
#define SUBOP_BRCMP_BLE          3
#define SUBOP_BRCMP_BGT          4
#define SUBOP_BRCMP_BGE          5

#define SUBOP_CALL_DIRECT        0
#define SUBOP_CALL_INDIRECT      1
#define SUBOP_CALL_TAIL_DIRECT   2
#define SUBOP_CALL_TAIL_INDIRECT 3

#define SUBOP_RET_VAL            0
#define SUBOP_RET_NIL            1
#define SUBOP_RET_VOID           2
#define SUBOP_RET_MULTI          3

#define SUBOP_NAT_KERNEL         0
#define SUBOP_NAT_GS             1
#define SUBOP_NAT_AUDIO          2
#define SUBOP_NAT_PAD            3
#define SUBOP_NAT_VIDEO          4
#define SUBOP_NAT_HUD            5
#define SUBOP_NAT_IO             6
#define SUBOP_NAT_USER           7

#define SUBOP_VEC2_NEW           0
#define SUBOP_VEC2_ADD           1
#define SUBOP_VEC2_SUB           2
#define SUBOP_VEC2_MUL           3
#define SUBOP_VEC2_DIV           4
#define SUBOP_VEC2_SCALE         5
#define SUBOP_VEC2_DOT           6
#define SUBOP_VEC2_CROSS         7

#define SUBOP_VPROP_X            0
#define SUBOP_VPROP_Y            1
#define SUBOP_VPROP_SET_X        2
#define SUBOP_VPROP_SET_Y        3
#define SUBOP_VPROP_LEN          4
#define SUBOP_VPROP_LENSQ        5
#define SUBOP_VPROP_NORM         6
#define SUBOP_VPROP_LERP         7

#define SUBOP_COLOR_RGBA32       0
#define SUBOP_COLOR_RGBA16       1
#define SUBOP_COLOR_UNPACK       2
#define SUBOP_COLOR_LERP         3
#define SUBOP_COLOR_MODULATE     4
#define SUBOP_COLOR_PREMUL       5

#define SUBOP_MMI_PADDB          0
#define SUBOP_MMI_PADDW          1
#define SUBOP_MMI_PSUBW          2
#define SUBOP_MMI_PMULTH         3
#define SUBOP_MMI_PMAXW          4
#define SUBOP_MMI_PMINW          5
#define SUBOP_MMI_PEXTW          6
#define SUBOP_MMI_PPACW          7

#define SUBOP_COLL_AGET          0
#define SUBOP_COLL_ASET          1
#define SUBOP_COLL_ALEN          2
#define SUBOP_COLL_APUSH         3
#define SUBOP_COLL_APOP          4
#define SUBOP_COLL_FGET          5
#define SUBOP_COLL_FSET          6
#define SUBOP_COLL_HGET          7

#define SUBOP_FIBER_SPAWN        0
#define SUBOP_FIBER_YIELD        1
#define SUBOP_FIBER_RESUME       2
#define SUBOP_FIBER_STATUS       3
#define SUBOP_FIBER_KILL         4
#define SUBOP_FIBER_ID           5
#define SUBOP_FIBER_SLEEP        6

#define SUBOP_CHAN_CREATE        0
#define SUBOP_CHAN_SEND          1
#define SUBOP_CHAN_RECV          2
#define SUBOP_CHAN_TRY_RECV      3
#define SUBOP_CHAN_COUNT         4
#define SUBOP_CHAN_CAP           5
#define SUBOP_CHAN_CLOSE         6

#define SUBOP_HW_GIF             0
#define SUBOP_HW_VIF1            1
#define SUBOP_HW_WAIT            2
#define SUBOP_HW_VSYNC           3
#define SUBOP_HW_SWAP            4
#define SUBOP_HW_KEYON           5
#define SUBOP_HW_PAD             6

#define SUBOP_ASM_MFC0           0
#define SUBOP_ASM_MTC0           1
#define SUBOP_ASM_VU0            2
#define SUBOP_ASM_SPRAM          3
#define SUBOP_ASM_PERF_START     4
#define SUBOP_ASM_PERF_STOP      5

#define SUBOP_DECBR_NZ           0
#define SUBOP_DECBR_GEZ          1
#define SUBOP_INCBR_LT           2

#define SUBOP_MADD_I32           0
#define SUBOP_MSUB_I32           1
#define SUBOP_MADD_F32           2
#define SUBOP_MSUB_F32           3
#define SUBOP_DOT_VEC2           4

// Call Frame
typedef struct {
    uint32_t return_pc;
    uint16_t reg_base;
    uint8_t  dest_reg;
} CallFrame;

// Concurrency Scheduler Definitions
typedef enum {
    FIBER_FREE         = 0,
    FIBER_READY        = 1,
    FIBER_RUNNING      = 2,
    FIBER_SLEEPING     = 3,
    FIBER_WAITING_CHAN = 4,
    FIBER_DEAD         = 5
} FiberState;

#define CITRINE_DEFAULT_MAX_FIBERS 64
#define CITRINE_FIBER_STACK_MAX 16
#define CITRINE_FIBER_REGS_MAX 64

typedef struct {
    uint32_t   id;
    FiberState state;
    uint32_t   pc;
    uint8_t    call_depth;
    CallFrame  call_stack[CITRINE_FIBER_STACK_MAX];
    uint8_t    reg_count;
    Value      saved_regs[CITRINE_FIBER_REGS_MAX];
    float      sleep_timer;        // Seconds remaining
    uint32_t   waiting_chan_id;    // Channel ID waiting on
    bool       waiting_send;       // true if waiting to send, false if waiting to recv
    Value      pending_send_val;   // Buffered value for pending send
} CitrineFiber;

#define CITRINE_DEFAULT_MAX_CHANNELS 32
#define CITRINE_CHANNEL_BUFFER_CAP 32

typedef struct {
    uint32_t id;
    bool     active;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
    uint32_t capacity;
    Value    buffer[CITRINE_CHANNEL_BUFFER_CAP];
} CitrineChannel;

typedef struct {
    uint32_t        max_fibers;
    CitrineFiber    fibers[CITRINE_DEFAULT_MAX_FIBERS];
    uint32_t        current_fiber;
    uint32_t        fiber_count;
    uint32_t        next_fiber_id;

    uint32_t        max_channels;
    CitrineChannel  channels[CITRINE_DEFAULT_MAX_CHANNELS];
    uint32_t        channel_count;
    uint32_t        next_channel_id;
} CitrineScheduler;

// Compiled Function Header
typedef struct {
    uint32_t name_idx;
    uint8_t  argc;
    uint8_t  num_registers;
    uint32_t code_offset;
    uint32_t instruction_count;
} CitrineFunction;

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
    
    // Function table
    CitrineFunction* functions;
    uint32_t        num_functions;

    // Constant & String pools
    Value*          constant_pool;
    uint32_t        num_constants;
    char**          string_pool;
    uint32_t        num_strings;

    // Concurrency Scheduler
    CitrineScheduler scheduler;

    // Memory Arenas
    Arena           frame_arena;    // Reset every frame at EndDrawing
    Arena           context_arena;  // Reset every context switch between main_loops
    Arena           level_arena;    // Reset on level reload

    // Context & Subsystem State
    uint32_t        active_subsystems;
    uint16_t        active_context_id;
    bool            in_main_loop;

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
void       citrine_vm_switch_context(CitrineVM* vm, uint16_t context_id, uint32_t subsys_mask);
void       citrine_vm_clear_context(CitrineVM* vm);

// Concurrency Scheduler API
uint32_t   citrine_scheduler_spawn(CitrineVM* vm, uint32_t func_idx, Value* args, uint8_t argc);
void       citrine_scheduler_yield(CitrineVM* vm);
void       citrine_scheduler_sleep(CitrineVM* vm, float seconds);
void       citrine_scheduler_tick(CitrineVM* vm, float dt);
uint32_t   citrine_scheduler_current_fiber(CitrineVM* vm);
bool       citrine_scheduler_fiber_alive(CitrineVM* vm, uint32_t fiber_id);

// Channel API
uint32_t   citrine_channel_create(CitrineVM* vm, uint32_t capacity);
bool       citrine_channel_send(CitrineVM* vm, uint32_t chan_id, Value val);
bool       citrine_channel_receive(CitrineVM* vm, uint32_t chan_id, Value* out_val);
bool       citrine_channel_try_receive(CitrineVM* vm, uint32_t chan_id, Value* out_val);
uint32_t   citrine_channel_count(CitrineVM* vm, uint32_t chan_id);
uint32_t   citrine_channel_capacity(CitrineVM* vm, uint32_t chan_id);

#ifdef __cplusplus
}
#endif

#endif // CITRINE_VM_H
