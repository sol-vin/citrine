#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include "../include/citrine_vm.h"
#include "../include/citrine_core.h"
#include "../include/citrine_draw2d.h"
#include "../include/citrine_draw3d.h"
#include "../include/citrine_input.h"
#include "../include/citrine_audio.h"
#include "../include/citrine_video.h"
#include "../include/citrine_hud.h"
#include "../include/citrine_panic.h"
#include "../include/citrine_gl.h"

#ifdef HOST_TEST_BUILD
Value g_host_spram[1024];
#endif

// Forward declaration of native dispatch table
static void native_dispatch(CitrineVM* vm, uint16_t native_id, Value* args, uint8_t argc, Value* out_ret);

static inline void* citrine_arena_alloc(Arena* arena, size_t size) {
    if (!arena || !arena->buffer) return NULL;
    size_t aligned_size = (size + 15) & ~15;
    if (arena->offset + aligned_size > arena->capacity) {
        return NULL;
    }
    void* ptr = arena->buffer + arena->offset;
    arena->offset += aligned_size;
    return ptr;
}

// ----------------------------------------------------------------------------
// Core Parity Data Structures: Arrays, IO::Memory, Objects
// ----------------------------------------------------------------------------

static void citrine_value_to_str(Value val, char* out_buf, size_t buf_size) {
    if (!out_buf || buf_size == 0) return;
    switch (val.type) {
        case VAL_STRING:
            snprintf(out_buf, buf_size, "%s", val.as.str ? val.as.str : "");
            break;
        case VAL_INT32:
            snprintf(out_buf, buf_size, "%d", val.as.i);
            break;
        case VAL_FLOAT32:
            snprintf(out_buf, buf_size, "%g", val.as.f);
            break;
        case VAL_BOOL:
            snprintf(out_buf, buf_size, "%s", val.as.i ? "true" : "false");
            break;
        case VAL_NIL:
            snprintf(out_buf, buf_size, "nil");
            break;
        case VAL_OBJECT:
            snprintf(out_buf, buf_size, "<object %p>", val.as.ptr);
            break;
        default:
            snprintf(out_buf, buf_size, "<value>");
            break;
    }
}

static CitrineArray* citrine_array_new(uint32_t capacity, bool is_static) {
    if (capacity == 0) capacity = 4;
    CitrineArray* arr = (CitrineArray*)calloc(1, sizeof(CitrineArray));
    if (!arr) return NULL;
    arr->capacity = capacity;
    arr->size = is_static ? capacity : 0;
    arr->is_static = is_static;
    arr->elements = (Value*)calloc(capacity, sizeof(Value));
    return arr;
}

static void citrine_array_push(CitrineArray* arr, Value val) {
    if (!arr || arr->is_static) return;
    if (arr->size >= arr->capacity) {
        uint32_t new_cap = arr->capacity * 2;
        Value* new_elems = (Value*)realloc(arr->elements, new_cap * sizeof(Value));
        if (new_elems) {
            arr->elements = new_elems;
            arr->capacity = new_cap;
        } else {
            return;
        }
    }
    arr->elements[arr->size++] = val;
}

static Value citrine_array_pop(CitrineArray* arr) {
    Value nil_val = { .type = VAL_NIL, .flags = 0, .as = { .i = 0 } };
    if (!arr || arr->size == 0) return nil_val;
    arr->size--;
    return arr->elements[arr->size];
}

static Value citrine_array_get(CitrineArray* arr, int32_t index) {
    Value nil_val = { .type = VAL_NIL, .flags = 0, .as = { .i = 0 } };
    if (!arr || index < 0 || (uint32_t)index >= arr->size) return nil_val;
    return arr->elements[index];
}

static void citrine_array_set(CitrineArray* arr, int32_t index, Value val) {
    if (!arr || index < 0) return;
    if ((uint32_t)index >= arr->capacity) {
        if (arr->is_static) return;
        uint32_t new_cap = ((uint32_t)index + 1) * 2;
        Value* new_elems = (Value*)realloc(arr->elements, new_cap * sizeof(Value));
        if (!new_elems) return;
        for (uint32_t i = arr->capacity; i < new_cap; i++) {
            new_elems[i].type = VAL_NIL;
        }
        arr->elements = new_elems;
        arr->capacity = new_cap;
    }
    if ((uint32_t)index >= arr->size) {
        arr->size = (uint32_t)index + 1;
    }
    arr->elements[index] = val;
}

static CitrineMemoryIO* citrine_memory_io_new(size_t capacity) {
    if (capacity == 0) capacity = 64;
    CitrineMemoryIO* io = (CitrineMemoryIO*)calloc(1, sizeof(CitrineMemoryIO));
    if (!io) return NULL;
    io->capacity = capacity;
    io->size = 0;
    io->pos = 0;
    io->buffer = (char*)calloc(capacity, 1);
    return io;
}

static void citrine_memory_io_write(CitrineMemoryIO* io, const char* str, size_t len) {
    if (!io || !str || len == 0) return;
    if (io->pos + len + 1 >= io->capacity) {
        size_t new_cap = (io->capacity + len) * 2;
        char* new_buf = (char*)realloc(io->buffer, new_cap);
        if (!new_buf) return;
        io->buffer = new_buf;
        io->capacity = new_cap;
    }
    memcpy(io->buffer + io->pos, str, len);
    io->pos += len;
    if (io->pos > io->size) io->size = io->pos;
    io->buffer[io->size] = '\0';
}

static void citrine_memory_io_write_byte(CitrineMemoryIO* io, uint8_t byte) {
    char b = (char)byte;
    citrine_memory_io_write(io, &b, 1);
}

static void citrine_memory_io_puts(CitrineMemoryIO* io, const char* str) {
    if (str) citrine_memory_io_write(io, str, strlen(str));
    citrine_memory_io_write(io, "\n", 1);
}

static const char* citrine_memory_io_to_s(CitrineMemoryIO* io) {
    if (!io || !io->buffer) return "";
    io->buffer[io->size] = '\0';
    return io->buffer;
}

static CitrineObject* citrine_object_new(uint32_t class_id, uint32_t field_count) {
    CitrineObject* obj = (CitrineObject*)calloc(1, sizeof(CitrineObject));
    if (!obj) return NULL;
    obj->class_id = class_id;
    obj->field_count = field_count;
    obj->fields = (field_count > 0) ? (Value*)calloc(field_count, sizeof(Value)) : NULL;
    return obj;
}


CitrineVM* citrine_vm_create(const uint8_t* cbc_data, size_t cbc_size) {
    if (cbc_size < 18 || (memcmp(cbc_data, "CBC1", 4) != 0 && memcmp(cbc_data, "CBC2", 4) != 0)) {
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

    // Read function table
    vm->num_functions = num_funcs;
    if (num_funcs > 0) {
        vm->functions = (CitrineFunction*)calloc(num_funcs, sizeof(CitrineFunction));
    }
    uint32_t main_code_offset = 0;
    for (uint32_t i = 0; i < num_funcs; i++) {
        vm->functions[i].name_idx = *(uint32_t*)ptr; ptr += 4;
        vm->functions[i].argc = *ptr++;
        vm->functions[i].num_registers = *ptr++;
        vm->functions[i].code_offset = *(uint32_t*)ptr; ptr += 4;
        vm->functions[i].instruction_count = *(uint32_t*)ptr; ptr += 4;
        main_code_offset = vm->functions[i].code_offset;
    }

    // Bytecode instructions start here
    vm->bytecode = (const uint32_t*)ptr;
    vm->bytecode_size = (cbc_size - (ptr - cbc_data)) / 4;
    vm->pc = main_code_offset;

    // Pin SPRAM register window to PS2 Scratchpad RAM (0x70000000)
    vm->spram_regs = SPRAM_BASE;
    memset(vm->spram_regs, 0, sizeof(Value) * MAX_SPRAM_REGISTERS);
    vm->spram_regs[1023].flags = SPRAM_CANARY_VALUE; // SPRAM Stack Canary

    // Initialize Concurrency Scheduler
    vm->scheduler.max_fibers = CITRINE_DEFAULT_MAX_FIBERS;
    vm->scheduler.max_channels = CITRINE_DEFAULT_MAX_CHANNELS;
    vm->scheduler.next_fiber_id = 1;
    vm->scheduler.current_fiber = 0;
    vm->scheduler.fiber_count = 1;
    vm->scheduler.next_channel_id = 1;

    CitrineFiber* main_fib = &vm->scheduler.fibers[0];
    main_fib->id = 0;
    main_fib->state = FIBER_RUNNING;
    main_fib->pc = main_code_offset;
    main_fib->reg_count = (num_funcs > 0) ? vm->functions[num_funcs - 1].num_registers : 32;
    main_fib->call_depth = 0;

    // Initialize Memory Arenas
    vm->frame_arena.capacity = 512 * 1024; // 512 KB
    vm->frame_arena.buffer = (uint8_t*)malloc(vm->frame_arena.capacity);
    vm->frame_arena.offset = 0;

    vm->level_arena.capacity = 2 * 1024 * 1024; // 2 MB
    vm->level_arena.buffer = (uint8_t*)malloc(vm->level_arena.capacity);
    vm->level_arena.offset = 0;

    vm->watchdog_limit = 5000000; // 5M instructions per frame max

    Citrine_GL_Init();

    return vm;
}

void citrine_vm_destroy(CitrineVM* vm) {
    if (!vm) return;
    if (vm->functions) free(vm->functions);
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

bool citrine_vm_step(CitrineVM* vm) {
    if (!vm || vm->panic_triggered) return false;
    citrine_vm_run(vm);
    return !vm->panic_triggered;
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

// ----------------------------------------------------------------------------
// Citrine Concurrency Scheduler & Channel Subsystem
// ----------------------------------------------------------------------------

void citrine_scheduler_tick(CitrineVM* vm, float dt) {
    if (!vm) return;
    for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
        CitrineFiber* fib = &vm->scheduler.fibers[i];
        if (fib->state == FIBER_SLEEPING) {
            fib->sleep_timer -= dt;
            if (fib->sleep_timer <= 0.0f) {
                fib->sleep_timer = 0.0f;
                fib->state = FIBER_READY;
            }
        }
    }
}

uint32_t citrine_scheduler_spawn(CitrineVM* vm, uint32_t func_idx, Value* args, uint8_t argc) {
    if (!vm || func_idx >= vm->num_functions) return 0;

    for (uint32_t i = 1; i < vm->scheduler.max_fibers; i++) {
        CitrineFiber* fib = &vm->scheduler.fibers[i];
        if (fib->state == FIBER_FREE || fib->state == FIBER_DEAD) {
            fib->id = vm->scheduler.next_fiber_id++;
            fib->state = FIBER_READY;
            fib->pc = vm->functions[func_idx].code_offset;
            fib->call_depth = 0;
            fib->reg_count = vm->functions[func_idx].num_registers;
            fib->sleep_timer = 0.0f;
            fib->waiting_chan_id = 0;
            fib->waiting_send = false;
            memset(fib->saved_regs, 0, sizeof(fib->saved_regs));
            if (args && argc > 0) {
                uint8_t copy_count = argc;
                if (copy_count > CITRINE_FIBER_REGS_MAX) copy_count = CITRINE_FIBER_REGS_MAX;
                memcpy(fib->saved_regs, args, copy_count * sizeof(Value));
            }
            vm->scheduler.fiber_count++;
            return fib->id;
        }
    }

    citrine_vm_panic(vm, "Max concurrent fibers limit (%u) exceeded", vm->scheduler.max_fibers);
    return 0;
}

void citrine_scheduler_sleep(CitrineVM* vm, float seconds) {
    if (!vm) return;
    CitrineFiber* curr = &vm->scheduler.fibers[vm->scheduler.current_fiber];
    curr->sleep_timer = seconds;
    curr->state = FIBER_SLEEPING;
}

uint32_t citrine_scheduler_current_fiber(CitrineVM* vm) {
    if (!vm) return 0;
    return vm->scheduler.fibers[vm->scheduler.current_fiber].id;
}

bool citrine_scheduler_fiber_alive(CitrineVM* vm, uint32_t fiber_id) {
    if (!vm) return false;
    for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
        if (vm->scheduler.fibers[i].id == fiber_id) {
            FiberState s = vm->scheduler.fibers[i].state;
            return (s != FIBER_FREE && s != FIBER_DEAD);
        }
    }
    return false;
}

static void scheduler_switch_next(CitrineVM* vm, Value* regs) {
    uint32_t curr_idx = vm->scheduler.current_fiber;
    CitrineFiber* curr = &vm->scheduler.fibers[curr_idx];

    // If current fiber was running, set it back to ready unless it sleeping/waiting/dead
    if (curr->state == FIBER_RUNNING) {
        curr->state = FIBER_READY;
    }

    // Save current fiber execution context
    curr->pc = vm->pc;
    curr->call_depth = vm->call_depth;
    for (uint32_t i = 0; i < vm->call_depth && i < CITRINE_FIBER_STACK_MAX; i++) {
        curr->call_stack[i] = vm->call_stack[i];
    }
    uint8_t count = curr->reg_count;
    if (count > CITRINE_FIBER_REGS_MAX) count = CITRINE_FIBER_REGS_MAX;
    if (count > 0) {
        memcpy(curr->saved_regs, regs, count * sizeof(Value));
    }

    // Round-robin selection of next ready fiber
    uint32_t next_idx = curr_idx;
    bool found = false;
    for (uint32_t i = 1; i <= vm->scheduler.max_fibers; i++) {
        uint32_t candidate = (curr_idx + i) % vm->scheduler.max_fibers;
        if (vm->scheduler.fibers[candidate].state == FIBER_READY) {
            next_idx = candidate;
            found = true;
            break;
        }
    }

    if (!found) {
        // If current fiber can still run, keep running
        if (curr->state == FIBER_READY) {
            curr->state = FIBER_RUNNING;
            return;
        }

        // All active fibers are sleeping or waiting; find shortest sleep timer
        float min_sleep = 999999.0f;
        for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
            if (vm->scheduler.fibers[i].state == FIBER_SLEEPING) {
                if (vm->scheduler.fibers[i].sleep_timer < min_sleep) {
                    min_sleep = vm->scheduler.fibers[i].sleep_timer;
                }
            }
        }

        if (min_sleep < 999999.0f && min_sleep > 0.0f) {
            citrine_scheduler_tick(vm, min_sleep);
            for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
                if (vm->scheduler.fibers[i].state == FIBER_READY) {
                    next_idx = i;
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // No runnable fibers left
            return;
        }
    }

    // Switch to next fiber
    CitrineFiber* next = &vm->scheduler.fibers[next_idx];
    vm->scheduler.current_fiber = next_idx;
    next->state = FIBER_RUNNING;
    vm->pc = next->pc;
    vm->call_depth = next->call_depth;
    for (uint32_t i = 0; i < next->call_depth && i < CITRINE_FIBER_STACK_MAX; i++) {
        vm->call_stack[i] = next->call_stack[i];
    }
    uint8_t next_count = next->reg_count;
    if (next_count > CITRINE_FIBER_REGS_MAX) next_count = CITRINE_FIBER_REGS_MAX;
    if (next_count > 0) {
        memcpy(regs, next->saved_regs, next_count * sizeof(Value));
    }
}

void citrine_scheduler_yield(CitrineVM* vm) {
    if (!vm) return;
    scheduler_switch_next(vm, vm->spram_regs);
}

// ----------------------------------------------------------------------------
// Channel Ring Buffer API
// ----------------------------------------------------------------------------

uint32_t citrine_channel_create(CitrineVM* vm, uint32_t capacity) {
    if (!vm) return 0;
    if (capacity == 0 || capacity > CITRINE_CHANNEL_BUFFER_CAP) {
        capacity = CITRINE_CHANNEL_BUFFER_CAP;
    }

    for (uint32_t i = 0; i < vm->scheduler.max_channels; i++) {
        CitrineChannel* ch = &vm->scheduler.channels[i];
        if (!ch->active) {
            ch->active = true;
            ch->id = vm->scheduler.next_channel_id++;
            ch->head = 0;
            ch->tail = 0;
            ch->count = 0;
            ch->capacity = capacity;
            vm->scheduler.channel_count++;
            return ch->id;
        }
    }

    citrine_vm_panic(vm, "Max concurrent channels (%u) exceeded", vm->scheduler.max_channels);
    return 0;
}

static CitrineChannel* find_channel(CitrineVM* vm, uint32_t chan_id) {
    if (!vm) return NULL;
    for (uint32_t i = 0; i < vm->scheduler.max_channels; i++) {
        if (vm->scheduler.channels[i].active && vm->scheduler.channels[i].id == chan_id) {
            return &vm->scheduler.channels[i];
        }
    }
    return NULL;
}

bool citrine_channel_send(CitrineVM* vm, uint32_t chan_id, Value val) {
    CitrineChannel* ch = find_channel(vm, chan_id);
    if (!ch) return false;

    if (ch->count < ch->capacity) {
        ch->buffer[ch->tail] = val;
        ch->tail = (ch->tail + 1) % ch->capacity;
        ch->count++;

        // Wake any fiber waiting to receive
        for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
            CitrineFiber* f = &vm->scheduler.fibers[i];
            if (f->state == FIBER_WAITING_CHAN && f->waiting_chan_id == chan_id && !f->waiting_send) {
                f->state = FIBER_READY;
                f->waiting_chan_id = 0;
            }
        }
        return true;
    } else {
        // Channel is full: block current fiber
        CitrineFiber* curr = &vm->scheduler.fibers[vm->scheduler.current_fiber];
        curr->state = FIBER_WAITING_CHAN;
        curr->waiting_chan_id = chan_id;
        curr->waiting_send = true;
        curr->pending_send_val = val;
        return false;
    }
}

bool citrine_channel_receive(CitrineVM* vm, uint32_t chan_id, Value* out_val) {
    CitrineChannel* ch = find_channel(vm, chan_id);
    if (!ch) {
        if (out_val) out_val->type = VAL_NIL;
        return false;
    }

    if (ch->count > 0) {
        if (out_val) *out_val = ch->buffer[ch->head];
        ch->head = (ch->head + 1) % ch->capacity;
        ch->count--;

        // Wake any fiber waiting to send
        for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
            CitrineFiber* f = &vm->scheduler.fibers[i];
            if (f->state == FIBER_WAITING_CHAN && f->waiting_chan_id == chan_id && f->waiting_send) {
                ch->buffer[ch->tail] = f->pending_send_val;
                ch->tail = (ch->tail + 1) % ch->capacity;
                ch->count++;
                f->state = FIBER_READY;
                f->waiting_chan_id = 0;
                f->waiting_send = false;
                break;
            }
        }
        return true;
    } else {
        // Channel empty: block current fiber
        CitrineFiber* curr = &vm->scheduler.fibers[vm->scheduler.current_fiber];
        curr->state = FIBER_WAITING_CHAN;
        curr->waiting_chan_id = chan_id;
        curr->waiting_send = false;
        if (out_val) out_val->type = VAL_NIL;
        return false;
    }
}

bool citrine_channel_try_receive(CitrineVM* vm, uint32_t chan_id, Value* out_val) {
    CitrineChannel* ch = find_channel(vm, chan_id);
    if (!ch || ch->count == 0) {
        if (out_val) out_val->type = VAL_NIL;
        return false;
    }

    if (out_val) *out_val = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;

    // Wake any fiber waiting to send
    for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
        CitrineFiber* f = &vm->scheduler.fibers[i];
        if (f->state == FIBER_WAITING_CHAN && f->waiting_chan_id == chan_id && f->waiting_send) {
            ch->buffer[ch->tail] = f->pending_send_val;
            ch->tail = (ch->tail + 1) % ch->capacity;
            ch->count++;
            f->state = FIBER_READY;
            f->waiting_chan_id = 0;
            f->waiting_send = false;
            break;
        }
    }
    return true;
}

uint32_t citrine_channel_count(CitrineVM* vm, uint32_t chan_id) {
    CitrineChannel* ch = find_channel(vm, chan_id);
    return ch ? ch->count : 0;
}

uint32_t citrine_channel_capacity(CitrineVM* vm, uint32_t chan_id) {
    CitrineChannel* ch = find_channel(vm, chan_id);
    return ch ? ch->capacity : 0;
}

void citrine_vm_run(CitrineVM* vm) {
    if (!vm || vm->panic_triggered) return;

    Value* spram = vm->spram_regs;
    uint16_t reg_base = 0;
    Value* regs = spram + reg_base;

#if defined(__GNUC__)
    // Citrine-32 Primary Opcode Dispatch Table (32 entries = 128 bytes, locks in 2 L1 D-Cache lines)
    static const void* primary_dispatch[32] = {
        [OP_SYS]         = &&do_sys,         // 0x00
        [OP_MOVE]        = &&do_move,        // 0x01
        [OP_LOAD_CONST]  = &&do_load_const,  // 0x02
        [OP_LOAD_IMM]    = &&do_load_imm,    // 0x03
        [OP_LOAD_MEM]    = &&do_load_mem,    // 0x04
        [OP_STORE_MEM]   = &&do_store_mem,   // 0x05
        [OP_ADD]         = &&do_add,         // 0x06
        [OP_SUB]         = &&do_sub,         // 0x07
        [OP_MUL]         = &&do_mul,         // 0x08
        [OP_DIV_MOD]     = &&do_div_mod,     // 0x09
        [OP_BITWISE]     = &&do_bitwise,     // 0x0A
        [OP_SHIFT]       = &&do_shift,       // 0x0B
        [OP_COMPARE]     = &&do_compare,     // 0x0C
        [OP_TEST]        = &&do_test,        // 0x0D
        [OP_FLOAT_ALU]   = &&do_float_alu,   // 0x0E
        [OP_JUMP]        = &&do_jump,        // 0x0F
        [OP_BRANCH_Z]    = &&do_branch_z,    // 0x10
        [OP_BRANCH_CMP]  = &&do_branch_cmp,  // 0x11
        [OP_CALL]        = &&do_call,        // 0x12
        [OP_RETURN]      = &&do_return,      // 0x13
        [OP_CALL_NATIVE] = &&do_call_native, // 0x14
        [OP_VEC2_MATH]   = &&do_vec2_math,   // 0x15
        [OP_VEC2_PROP]   = &&do_vec2_prop,   // 0x16
        [OP_COLOR_OP]    = &&do_color_op,    // 0x17
        [OP_SIMD_MMI]    = &&do_simd_mmi,    // 0x18
        [OP_COLLECTION]  = &&do_collection,  // 0x19
        [OP_FIBER_OP]    = &&do_fiber_op,    // 0x1A
        [OP_CHANNEL_OP]  = &&do_channel_op,  // 0x1B
        [OP_PS2_HW]      = &&do_ps2_hw,      // 0x1C
        [OP_INLINE_ASM]  = &&do_inline_asm,  // 0x1D
        [OP_LOOP_DEC_BR] = &&do_loop_dec_br, // 0x1E
        [OP_FUSED_MADD]  = &&do_fused_madd   // 0x1F
    };

    #define DISPATCH() do { \
        if (++vm->instruction_count > vm->watchdog_limit) { \
            citrine_vm_panic(vm, "Instruction Watchdog Timeout (> 5M instructions without yield)"); \
            return; \
        } \
        uint32_t instr_word = vm->bytecode[vm->pc++]; \
        uint8_t op = (instr_word >> 27) & 0x1F; \
        goto *primary_dispatch[op]; \
    } while (0)

    #define INSTR_SUBOP(raw)   (((raw) >> 24) & 0x07)
    #define INSTR_DST(raw)     (((raw) >> 16) & 0xFF)
    #define INSTR_A(raw)       (((raw) >> 8) & 0xFF)
    #define INSTR_B(raw)       ((raw) & 0xFF)
    #define INSTR_IMM16(raw)   ((uint16_t)((raw) & 0xFFFF))
    #define INSTR_SIMM16(raw)  ((int16_t)((raw) & 0xFFFF))
    #define INSTR_OFFSET8(raw) ((int8_t)((raw) & 0xFF))
    #define INSTR_JUMP24(raw)  (((int32_t)(((raw) & 0xFFFFFF) << 8)) >> 8)

    DISPATCH();

    // 0x00: OP_SYS
    do_sys: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        if (subop == SUBOP_SYS_HALT) {
            return;
        } else if (subop == SUBOP_SYS_BREAK) {
            citrine_vm_panic(vm, "Breakpoint trap");
            return;
        } else if (subop == SUBOP_SYS_WATCHDOG_RESET) {
            vm->instruction_count = 0;
        }
        DISPATCH();
    }

    // 0x01: OP_MOVE
    do_move: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        if (subop == SUBOP_MOVE_CMOVZ) {
            uint8_t b = INSTR_B(raw);
            if (regs[b].type == VAL_NIL || (regs[b].type == VAL_BOOL && !regs[b].as.i) || (regs[b].type == VAL_INT32 && regs[b].as.i == 0)) {
                regs[dst] = regs[a];
            }
        } else if (subop == SUBOP_MOVE_CMOVN) {
            uint8_t b = INSTR_B(raw);
            if (!(regs[b].type == VAL_NIL || (regs[b].type == VAL_BOOL && !regs[b].as.i) || (regs[b].type == VAL_INT32 && regs[b].as.i == 0))) {
                regs[dst] = regs[a];
            }
        } else if (subop == SUBOP_MOVE_SWAP) {
            Value tmp = regs[dst];
            regs[dst] = regs[a];
            regs[a] = tmp;
        } else {
            regs[dst] = regs[a];
        }
        DISPATCH();
    }

    // 0x02: OP_LOAD_CONST
    do_load_const: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = INSTR_DST(raw);
        uint16_t c_idx = INSTR_IMM16(raw);
        if (c_idx < vm->num_constants) {
            regs[dst] = vm->constant_pool[c_idx];
        }
        DISPATCH();
    }

    // 0x03: OP_LOAD_IMM
    do_load_imm: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        int16_t simm = INSTR_SIMM16(raw);
        uint16_t uimm = INSTR_IMM16(raw);
        switch (subop) {
            case SUBOP_IMM_NIL:
                regs[dst].type = VAL_NIL;
                regs[dst].as.i = 0;
                break;
            case SUBOP_IMM_BOOL:
                regs[dst].type = VAL_BOOL;
                regs[dst].as.i = (uimm != 0);
                break;
            case SUBOP_IMM_INT16:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)simm;
                break;
            case SUBOP_IMM_UINT16:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)uimm;
                break;
            case SUBOP_IMM_UPPER16:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = ((int32_t)uimm) << 16;
                break;
            case SUBOP_IMM_ZERO:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = 0;
                break;
            case SUBOP_IMM_MINUS1:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = -1;
                break;
            default:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)simm;
                break;
        }
        DISPATCH();
    }

    // 0x04: OP_LOAD_MEM
    do_load_mem: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        uint8_t* ptr = (uint8_t*)regs[a].as.ptr + b;
        switch (subop) {
            case SUBOP_MEM_LB:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int8_t)*ptr;
                break;
            case SUBOP_MEM_LBU:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (uint8_t)*ptr;
                break;
            case SUBOP_MEM_LH:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = *(int16_t*)ptr;
                break;
            case SUBOP_MEM_LHU:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = *(uint16_t*)ptr;
                break;
            case SUBOP_MEM_LW:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = *(int32_t*)ptr;
                break;
            case SUBOP_MEM_LWC1:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = *(float*)ptr;
                break;
            case SUBOP_MEM_LD:
            case SUBOP_MEM_LQ:
                regs[dst] = *(Value*)ptr;
                break;
            default:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = *(int32_t*)ptr;
                break;
        }
        DISPATCH();
    }

    // 0x05: OP_STORE_MEM
    do_store_mem: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        uint8_t* ptr = (uint8_t*)regs[a].as.ptr + b;
        switch (subop) {
            case 0:
                *ptr = (uint8_t)regs[dst].as.i;
                break;
            case 1:
                *(uint16_t*)ptr = (uint16_t)regs[dst].as.i;
                break;
            case 2:
                *(int32_t*)ptr = regs[dst].as.i;
                break;
            case 3:
                *(float*)ptr = regs[dst].as.f;
                break;
            case 4:
            case 5:
                *(Value*)ptr = regs[dst];
                break;
            default:
                *(int32_t*)ptr = regs[dst].as.i;
                break;
        }
        DISPATCH();
    }

    // 0x06: OP_ADD
    do_add: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        if (subop == SUBOP_ADD_IMM8) {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i + (int8_t)b;
        } else if (subop == SUBOP_ADD_STR || (regs[a].type == VAL_STRING && regs[b].type == VAL_STRING)) {
            const char* sa = regs[a].as.str ? regs[a].as.str : "";
            const char* sb = regs[b].as.str ? regs[b].as.str : "";
            size_t la = strlen(sa);
            size_t lb = strlen(sb);
            char* cat = (char*)citrine_arena_alloc(&vm->frame_arena, la + lb + 1);
            if (cat) {
                memcpy(cat, sa, la);
                memcpy(cat + la, sb, lb);
                cat[la + lb] = '\0';
                regs[dst].type = VAL_STRING;
                regs[dst].as.str = cat;
            }
        } else if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
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

    // 0x07: OP_SUB
    do_sub: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        if (subop == SUBOP_SUB_NEG) {
            if (regs[a].type == VAL_FLOAT32) {
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = -regs[a].as.f;
            } else {
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = -regs[a].as.i;
            }
        } else if (subop == SUBOP_SUB_IMM8) {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i - (int8_t)b;
        } else if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
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

    // 0x08: OP_MUL
    do_mul: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        if (subop == SUBOP_MUL_IMM8) {
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i * (int8_t)b;
        } else if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
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

    // 0x09: OP_DIV_MOD
    do_div_mod: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        if (subop == SUBOP_MOD_S32) {
            if (regs[b].as.i == 0) {
                citrine_vm_panic(vm, "Modulo by zero");
                return;
            }
            regs[dst].type = VAL_INT32;
            regs[dst].as.i = regs[a].as.i % regs[b].as.i;
        } else {
            if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
                float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
                if (fb == 0.0f) {
                    citrine_vm_panic(vm, "Division by zero");
                    return;
                }
                float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = fa / fb;
            } else {
                if (regs[b].as.i == 0) {
                    citrine_vm_panic(vm, "Division by zero");
                    return;
                }
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = regs[a].as.i / regs[b].as.i;
            }
        }
        DISPATCH();
    }

    // 0x0A: OP_BITWISE
    do_bitwise: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_INT32;
        switch (subop) {
            case SUBOP_BIT_AND:
                regs[dst].as.i = regs[a].as.i & regs[b].as.i;
                break;
            case SUBOP_BIT_OR:
                regs[dst].as.i = regs[a].as.i | regs[b].as.i;
                break;
            case SUBOP_BIT_XOR:
                regs[dst].as.i = regs[a].as.i ^ regs[b].as.i;
                break;
            case SUBOP_BIT_NOR:
                regs[dst].as.i = ~(regs[a].as.i | regs[b].as.i);
                break;
            case SUBOP_BIT_AND_NOT:
                regs[dst].as.i = regs[a].as.i & ~regs[b].as.i;
                break;
            case SUBOP_BIT_XNOR:
                regs[dst].as.i = ~(regs[a].as.i ^ regs[b].as.i);
                break;
            default:
                regs[dst].as.i = regs[a].as.i & regs[b].as.i;
                break;
        }
        DISPATCH();
    }

    // 0x0B: OP_SHIFT
    do_shift: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_INT32;
        uint32_t shift = (uint32_t)(regs[b].as.i & 0x1F);
        switch (subop) {
            case SUBOP_SHIFT_SLL:
                regs[dst].as.i = (int32_t)((uint32_t)regs[a].as.i << shift);
                break;
            case SUBOP_SHIFT_SRL:
                regs[dst].as.i = (int32_t)((uint32_t)regs[a].as.i >> shift);
                break;
            case SUBOP_SHIFT_SRA:
                regs[dst].as.i = regs[a].as.i >> shift;
                break;
            case SUBOP_SHIFT_ROTL: {
                uint32_t v = (uint32_t)regs[a].as.i;
                regs[dst].as.i = (int32_t)((v << shift) | (v >> (32 - shift)));
                break;
            }
            case SUBOP_SHIFT_ROTR: {
                uint32_t v = (uint32_t)regs[a].as.i;
                regs[dst].as.i = (int32_t)((v >> shift) | (v << (32 - shift)));
                break;
            }
            default:
                regs[dst].as.i = (int32_t)((uint32_t)regs[a].as.i << shift);
                break;
        }
        DISPATCH();
    }

    // 0x0C: OP_COMPARE
    do_compare: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_BOOL;
        if (subop == SUBOP_CMP_STR_EQ) {
            regs[dst].as.i = (strcmp(regs[a].as.str ? regs[a].as.str : "", regs[b].as.str ? regs[b].as.str : "") == 0);
        } else if (subop == SUBOP_CMP_PTR_EQ) {
            regs[dst].as.i = (regs[a].as.ptr == regs[b].as.ptr);
        } else if (regs[a].type == VAL_FLOAT32 || regs[b].type == VAL_FLOAT32) {
            float fa = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
            float fb = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
            switch (subop) {
                case SUBOP_CMP_EQ: regs[dst].as.i = (fa == fb); break;
                case SUBOP_CMP_NE: regs[dst].as.i = (fa != fb); break;
                case SUBOP_CMP_LT: regs[dst].as.i = (fa < fb); break;
                case SUBOP_CMP_LE: regs[dst].as.i = (fa <= fb); break;
                case SUBOP_CMP_GT: regs[dst].as.i = (fa > fb); break;
                case SUBOP_CMP_GE: regs[dst].as.i = (fa >= fb); break;
                default: regs[dst].as.i = (fa == fb); break;
            }
        } else {
            int32_t ia = regs[a].as.i;
            int32_t ib = regs[b].as.i;
            switch (subop) {
                case SUBOP_CMP_EQ: regs[dst].as.i = (ia == ib); break;
                case SUBOP_CMP_NE: regs[dst].as.i = (ia != ib); break;
                case SUBOP_CMP_LT: regs[dst].as.i = (ia < ib); break;
                case SUBOP_CMP_LE: regs[dst].as.i = (ia <= ib); break;
                case SUBOP_CMP_GT: regs[dst].as.i = (ia > ib); break;
                case SUBOP_CMP_GE: regs[dst].as.i = (ia >= ib); break;
                default: regs[dst].as.i = (ia == ib); break;
            }
        }
        DISPATCH();
    }

    // 0x0D: OP_TEST
    do_test: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        regs[dst].type = VAL_BOOL;
        switch (subop) {
            case SUBOP_TEST_NIL:
                regs[dst].as.i = (regs[a].type == VAL_NIL);
                break;
            case SUBOP_TEST_NOT_NIL:
                regs[dst].as.i = (regs[a].type != VAL_NIL);
                break;
            case SUBOP_TEST_ZERO:
                regs[dst].as.i = (regs[a].as.i == 0);
                break;
            case SUBOP_TEST_NOT_ZERO:
                regs[dst].as.i = (regs[a].as.i != 0);
                break;
            case SUBOP_TEST_TRUTHY:
                regs[dst].as.i = !(regs[a].type == VAL_NIL || (regs[a].type == VAL_BOOL && !regs[a].as.i));
                break;
            case SUBOP_TEST_FALSY:
                regs[dst].as.i = (regs[a].type == VAL_NIL || (regs[a].type == VAL_BOOL && !regs[a].as.i));
                break;
            default:
                regs[dst].as.i = (regs[a].as.i != 0);
                break;
        }
        DISPATCH();
    }

    // 0x0E: OP_FLOAT_ALU
    do_float_alu: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_FLOAT32;
        switch (subop) {
            case SUBOP_FLOAT_ADD:
                regs[dst].as.f = regs[a].as.f + regs[b].as.f;
                break;
            case SUBOP_FLOAT_SUB:
                regs[dst].as.f = regs[a].as.f - regs[b].as.f;
                break;
            case SUBOP_FLOAT_MUL:
                regs[dst].as.f = regs[a].as.f * regs[b].as.f;
                break;
            case SUBOP_FLOAT_DIV:
                regs[dst].as.f = regs[a].as.f / regs[b].as.f;
                break;
            case SUBOP_FLOAT_NEG:
                regs[dst].as.f = -regs[a].as.f;
                break;
            case SUBOP_FLOAT_ABS:
                regs[dst].as.f = fabsf(regs[a].as.f);
                break;
            case SUBOP_FLOAT_SQRT:
                regs[dst].as.f = sqrtf(regs[a].as.f);
                break;
            case SUBOP_FLOAT_CVT:
                regs[dst].as.f = (float)regs[a].as.i;
                break;
            default:
                regs[dst].as.f = regs[a].as.f + regs[b].as.f;
                break;
        }
        DISPATCH();
    }

    // 0x0F: OP_JUMP
    do_jump: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        if (subop == SUBOP_JUMP_REG) {
            uint8_t dst = INSTR_DST(raw);
            vm->pc = (uint32_t)regs[dst].as.i;
        } else if (subop == SUBOP_JUMP_REL16) {
            vm->pc += INSTR_SIMM16(raw);
        } else {
            // SUBOP_JUMP_REL24 (default 24-bit jump covering entire 32MB address space)
            vm->pc += INSTR_JUMP24(raw);
        }
        DISPATCH();
    }

    // 0x10: OP_BRANCH_Z
    do_branch_z: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t cond_reg = INSTR_DST(raw);
        int16_t offset = INSTR_SIMM16(raw);
        switch (subop) {
            case SUBOP_BRZ_TRUTHY:
                if (regs[cond_reg].type == VAL_BOOL && regs[cond_reg].as.i != 0) {
                    vm->pc += offset;
                }
                break;
            case SUBOP_BRZ_FALSY:
                if (regs[cond_reg].type == VAL_NIL || (regs[cond_reg].type == VAL_BOOL && regs[cond_reg].as.i == 0)) {
                    vm->pc += offset;
                }
                break;
            case SUBOP_BRZ_ZERO:
                if (regs[cond_reg].as.i == 0) vm->pc += offset;
                break;
            case SUBOP_BRZ_NONZERO:
                if (regs[cond_reg].as.i != 0) vm->pc += offset;
                break;
            case SUBOP_BRZ_POS:
                if (regs[cond_reg].as.i > 0) vm->pc += offset;
                break;
            case SUBOP_BRZ_NEG:
                if (regs[cond_reg].as.i < 0) vm->pc += offset;
                break;
            default:
                if (regs[cond_reg].type == VAL_BOOL && regs[cond_reg].as.i != 0) vm->pc += offset;
                break;
        }
        DISPATCH();
    }

    // 0x11: OP_BRANCH_CMP (Fused Compare-and-Branch)
    do_branch_cmp: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t r1 = INSTR_DST(raw);
        uint8_t r2 = INSTR_A(raw);
        int8_t offset = INSTR_OFFSET8(raw);
        if (regs[r1].type == VAL_FLOAT32 || regs[r2].type == VAL_FLOAT32) {
            float fa = (regs[r1].type == VAL_FLOAT32) ? regs[r1].as.f : (float)regs[r1].as.i;
            float fb = (regs[r2].type == VAL_FLOAT32) ? regs[r2].as.f : (float)regs[r2].as.i;
            switch (subop) {
                case SUBOP_BRCMP_BEQ: if (fa == fb) vm->pc += offset; break;
                case SUBOP_BRCMP_BNE: if (fa != fb) vm->pc += offset; break;
                case SUBOP_BRCMP_BLT: if (fa <  fb) vm->pc += offset; break;
                case SUBOP_BRCMP_BLE: if (fa <= fb) vm->pc += offset; break;
                case SUBOP_BRCMP_BGT: if (fa >  fb) vm->pc += offset; break;
                case SUBOP_BRCMP_BGE: if (fa >= fb) vm->pc += offset; break;
                default: break;
            }
        } else {
            int32_t ia = regs[r1].as.i;
            int32_t ib = regs[r2].as.i;
            switch (subop) {
                case SUBOP_BRCMP_BEQ: if (ia == ib) vm->pc += offset; break;
                case SUBOP_BRCMP_BNE: if (ia != ib) vm->pc += offset; break;
                case SUBOP_BRCMP_BLT: if (ia <  ib) vm->pc += offset; break;
                case SUBOP_BRCMP_BLE: if (ia <= ib) vm->pc += offset; break;
                case SUBOP_BRCMP_BGT: if (ia >  ib) vm->pc += offset; break;
                case SUBOP_BRCMP_BGE: if (ia >= ib) vm->pc += offset; break;
                default: break;
            }
        }
        DISPATCH();
    }

    // 0x12: OP_CALL
    do_call: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint16_t func_idx = (subop == SUBOP_CALL_INDIRECT) ? (uint16_t)regs[dst].as.i : INSTR_IMM16(raw);
        if (vm->call_depth >= 63) {
            citrine_vm_panic(vm, "Stack Overflow: call depth exceeded 64 frames");
            return;
        }
        if (func_idx >= vm->num_functions) {
            citrine_vm_panic(vm, "Call to invalid function index %u (num_functions=%u)", func_idx, vm->num_functions);
            return;
        }
        CitrineFunction* target_fn = &vm->functions[func_idx];
        if (subop == SUBOP_CALL_TAIL_DIRECT || subop == SUBOP_CALL_TAIL_INDIRECT) {
            // Zero-Stack Tail Call: reuse current frame directly
            vm->pc = target_fn->code_offset;
        } else {
            vm->call_stack[vm->call_depth].return_pc = vm->pc;
            vm->call_stack[vm->call_depth].reg_base = reg_base;
            vm->call_stack[vm->call_depth].dest_reg = dst;
            vm->call_depth++;
            reg_base += dst + 1;
            if (reg_base + target_fn->num_registers >= MAX_SPRAM_REGISTERS - 1) {
                citrine_vm_panic(vm, "SPRAM Register Window Overflow (exceeded %u registers)", MAX_SPRAM_REGISTERS);
                return;
            }
            regs = spram + reg_base;
            vm->pc = target_fn->code_offset;
        }
        DISPATCH();
    }

    // 0x13: OP_RETURN
    do_return: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t ret_reg = INSTR_DST(raw);
        Value ret_val;
        if (subop == SUBOP_RET_NIL) {
            ret_val.type = VAL_NIL; ret_val.flags = 0; ret_val.as.i = 0;
        } else {
            ret_val = regs[ret_reg];
        }
        if (vm->call_depth == 0) {
            if (vm->scheduler.current_fiber == 0) {
                return;
            } else {
                CitrineFiber* curr = &vm->scheduler.fibers[vm->scheduler.current_fiber];
                curr->state = FIBER_DEAD;
                if (vm->scheduler.fiber_count > 0) vm->scheduler.fiber_count--;
                scheduler_switch_next(vm, spram);
                reg_base = 0;
                regs = spram;
                DISPATCH();
            }
        }
        vm->call_depth--;
        uint16_t caller_base = vm->call_stack[vm->call_depth].reg_base;
        uint8_t caller_dest = vm->call_stack[vm->call_depth].dest_reg;
        reg_base = caller_base;
        regs = spram + reg_base;
        regs[caller_dest] = ret_val;
        vm->pc = vm->call_stack[vm->call_depth].return_pc;
        DISPATCH();
    }

    // 0x14: OP_CALL_NATIVE
    do_call_native: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = INSTR_DST(raw);
        uint8_t base = INSTR_A(raw);
        uint16_t native_id = INSTR_B(raw);
        native_dispatch(vm, native_id, &regs[base], 0, &regs[dst]);
        if (vm->scheduler.fibers[vm->scheduler.current_fiber].state != FIBER_RUNNING) {
            scheduler_switch_next(vm, regs);
        }
        DISPATCH();
    }

    // 0x15: OP_VEC2_MATH
    do_vec2_math: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        switch (subop) {
            case SUBOP_VEC2_NEW:
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
                regs[dst].as.vec2.y = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
                break;
            case SUBOP_VEC2_ADD:
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = regs[a].as.vec2.x + regs[b].as.vec2.x;
                regs[dst].as.vec2.y = regs[a].as.vec2.y + regs[b].as.vec2.y;
                break;
            case SUBOP_VEC2_SUB:
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = regs[a].as.vec2.x - regs[b].as.vec2.x;
                regs[dst].as.vec2.y = regs[a].as.vec2.y - regs[b].as.vec2.y;
                break;
            case SUBOP_VEC2_MUL:
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = regs[a].as.vec2.x * regs[b].as.vec2.x;
                regs[dst].as.vec2.y = regs[a].as.vec2.y * regs[b].as.vec2.y;
                break;
            case SUBOP_VEC2_DIV:
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = regs[a].as.vec2.x / regs[b].as.vec2.x;
                regs[dst].as.vec2.y = regs[a].as.vec2.y / regs[b].as.vec2.y;
                break;
            case SUBOP_VEC2_SCALE: {
                float s = (regs[b].type == VAL_FLOAT32) ? regs[b].as.f : (float)regs[b].as.i;
                regs[dst].type = VAL_VEC2;
                regs[dst].as.vec2.x = regs[a].as.vec2.x * s;
                regs[dst].as.vec2.y = regs[a].as.vec2.y * s;
                break;
            }
            case SUBOP_VEC2_DOT:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = regs[a].as.vec2.x * regs[b].as.vec2.x + regs[a].as.vec2.y * regs[b].as.vec2.y;
                break;
            case SUBOP_VEC2_CROSS:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = regs[a].as.vec2.x * regs[b].as.vec2.y - regs[a].as.vec2.y * regs[b].as.vec2.x;
                break;
            default:
                break;
        }
        DISPATCH();
    }

    // 0x16: OP_VEC2_PROP
    do_vec2_prop: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        switch (subop) {
            case SUBOP_VPROP_X:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = regs[a].as.vec2.x;
                break;
            case SUBOP_VPROP_Y:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = regs[a].as.vec2.y;
                break;
            case SUBOP_VPROP_SET_X:
                regs[dst].as.vec2.x = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
                break;
            case SUBOP_VPROP_SET_Y:
                regs[dst].as.vec2.y = (regs[a].type == VAL_FLOAT32) ? regs[a].as.f : (float)regs[a].as.i;
                break;
            case SUBOP_VPROP_LEN:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = sqrtf(regs[a].as.vec2.x * regs[a].as.vec2.x + regs[a].as.vec2.y * regs[a].as.vec2.y);
                break;
            case SUBOP_VPROP_LENSQ:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f = regs[a].as.vec2.x * regs[a].as.vec2.x + regs[a].as.vec2.y * regs[a].as.vec2.y;
                break;
            default:
                break;
        }
        DISPATCH();
    }

    // 0x17: OP_COLOR_OP
    do_color_op: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_COLOR;
        regs[dst].as.color.r = (uint8_t)regs[a].as.i;
        regs[dst].as.color.g = (uint8_t)regs[b].as.i;
        regs[dst].as.color.b = 0;
        regs[dst].as.color.a = 255;
        DISPATCH();
    }

    // 0x18: OP_SIMD_MMI
    do_simd_mmi: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        regs[dst].type = VAL_INT32;
        switch (subop) {
            case SUBOP_MMI_PADDW:
                regs[dst].as.i = regs[a].as.i + regs[b].as.i;
                break;
            case SUBOP_MMI_PSUBW:
                regs[dst].as.i = regs[a].as.i - regs[b].as.i;
                break;
            case SUBOP_MMI_PMAXW:
                regs[dst].as.i = (regs[a].as.i > regs[b].as.i) ? regs[a].as.i : regs[b].as.i;
                break;
            case SUBOP_MMI_PMINW:
                regs[dst].as.i = (regs[a].as.i < regs[b].as.i) ? regs[a].as.i : regs[b].as.i;
                break;
            default:
                regs[dst].as.i = regs[a].as.i + regs[b].as.i;
                break;
        }
        DISPATCH();
    }

    // 0x19: OP_COLLECTION
    do_collection: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        switch (subop) {
            case SUBOP_COLL_AGET: {
                CitrineArray* arr = (CitrineArray*)regs[a].as.ptr;
                regs[dst] = citrine_array_get(arr, regs[b].as.i);
                break;
            }
            case SUBOP_COLL_ASET: {
                CitrineArray* arr = (CitrineArray*)regs[a].as.ptr;
                citrine_array_set(arr, regs[b].as.i, regs[dst]);
                break;
            }
            case SUBOP_COLL_ALEN: {
                CitrineArray* arr = (CitrineArray*)regs[a].as.ptr;
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = arr ? (int32_t)arr->size : 0;
                break;
            }
            case SUBOP_COLL_APUSH: {
                CitrineArray* arr = (CitrineArray*)regs[dst].as.ptr;
                citrine_array_push(arr, regs[a]);
                break;
            }
            case SUBOP_COLL_APOP: {
                CitrineArray* arr = (CitrineArray*)regs[a].as.ptr;
                regs[dst] = citrine_array_pop(arr);
                break;
            }
            case SUBOP_COLL_FGET: {
                CitrineObject* obj = (CitrineObject*)regs[a].as.ptr;
                uint32_t f_idx = (uint32_t)b;
                if (obj && f_idx < obj->field_count) {
                    regs[dst] = obj->fields[f_idx];
                } else {
                    regs[dst].type = VAL_NIL;
                }
                break;
            }
            case SUBOP_COLL_FSET: {
                CitrineObject* obj = (CitrineObject*)regs[a].as.ptr;
                uint32_t f_idx = (uint32_t)b;
                if (obj && f_idx < obj->field_count) {
                    obj->fields[f_idx] = regs[dst];
                }
                break;
            }
            default:
                break;
        }
        DISPATCH();
    }

    // 0x1A: OP_FIBER_OP
    do_fiber_op: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        switch (subop) {
            case SUBOP_FIBER_SPAWN: {
                uint16_t func_idx = INSTR_IMM16(raw);
                uint8_t argc = (func_idx < vm->num_functions) ? vm->functions[func_idx].argc : 0;
                uint32_t fib_id = citrine_scheduler_spawn(vm, func_idx, &regs[dst + 1], argc);
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)fib_id;
                break;
            }
            case SUBOP_FIBER_YIELD:
                scheduler_switch_next(vm, regs);
                break;
            case SUBOP_FIBER_RESUME: {
                uint32_t fib_id = (uint32_t)regs[dst].as.i;
                for (uint32_t i = 0; i < vm->scheduler.max_fibers; i++) {
                    if (vm->scheduler.fibers[i].id == fib_id && vm->scheduler.fibers[i].state != FIBER_DEAD) {
                        vm->scheduler.fibers[i].state = FIBER_READY;
                        break;
                    }
                }
                break;
            }
            case SUBOP_FIBER_STATUS: {
                uint32_t fib_id = (uint32_t)regs[dst].as.i;
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = citrine_scheduler_fiber_alive(vm, fib_id) ? 1 : 0;
                break;
            }
            case SUBOP_FIBER_ID:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)citrine_scheduler_current_fiber(vm);
                break;
            default:
                break;
        }
        DISPATCH();
    }

    // 0x1B: OP_CHANNEL_OP
    do_channel_op: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        switch (subop) {
            case SUBOP_CHAN_CREATE: {
                uint32_t cid = citrine_channel_create(vm, (uint32_t)regs[a].as.i);
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)cid;
                break;
            }
            case SUBOP_CHAN_SEND:
                citrine_channel_send(vm, (uint32_t)regs[dst].as.i, regs[a]);
                if (vm->scheduler.fibers[vm->scheduler.current_fiber].state != FIBER_RUNNING) {
                    scheduler_switch_next(vm, regs);
                }
                break;
            case SUBOP_CHAN_RECV:
                citrine_channel_receive(vm, (uint32_t)regs[a].as.i, &regs[dst]);
                if (vm->scheduler.fibers[vm->scheduler.current_fiber].state != FIBER_RUNNING) {
                    scheduler_switch_next(vm, regs);
                }
                break;
            case SUBOP_CHAN_TRY_RECV: {
                bool ok = citrine_channel_try_receive(vm, (uint32_t)regs[a].as.i, &regs[dst]);
                if (!ok) { regs[dst].type = VAL_NIL; }
                break;
            }
            case SUBOP_CHAN_COUNT:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)citrine_channel_count(vm, (uint32_t)regs[a].as.i);
                break;
            case SUBOP_CHAN_CAP:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i = (int32_t)citrine_channel_capacity(vm, (uint32_t)regs[a].as.i);
                break;
            default:
                break;
        }
        DISPATCH();
    }

    // 0x1C: OP_PS2_HW
    do_ps2_hw: {
        DISPATCH();
    }

    // 0x1D: OP_INLINE_ASM
    do_inline_asm: {
        DISPATCH();
    }

    // 0x1E: OP_LOOP_DEC_BR (Peephole Fused Loop Decrement/Increment & Branch)
    do_loop_dec_br: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t cnt_reg = INSTR_DST(raw);
        if (subop == SUBOP_INCBR_LT) {
            uint8_t limit_reg = INSTR_A(raw);
            int8_t offset = INSTR_OFFSET8(raw);
            regs[cnt_reg].as.i += 1;
            if (regs[cnt_reg].as.i < regs[limit_reg].as.i) {
                vm->pc += offset;
            }
        } else if (subop == SUBOP_DECBR_GEZ) {
            int16_t offset = INSTR_SIMM16(raw);
            regs[cnt_reg].as.i -= 1;
            if (regs[cnt_reg].as.i >= 0) {
                vm->pc += offset;
            }
        } else {
            // SUBOP_DECBR_NZ (default)
            int16_t offset = INSTR_SIMM16(raw);
            regs[cnt_reg].as.i -= 1;
            if (regs[cnt_reg].as.i != 0) {
                vm->pc += offset;
            }
        }
        DISPATCH();
    }

    // 0x1F: OP_FUSED_MADD (Peephole Fused Multiply-Accumulate / Dot)
    do_fused_madd: {
        uint32_t raw = vm->bytecode[vm->pc - 1];
        uint8_t subop = INSTR_SUBOP(raw);
        uint8_t dst = INSTR_DST(raw);
        uint8_t a = INSTR_A(raw);
        uint8_t b = INSTR_B(raw);
        switch (subop) {
            case SUBOP_MADD_I32:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i += (regs[a].as.i * regs[b].as.i);
                break;
            case SUBOP_MSUB_I32:
                regs[dst].type = VAL_INT32;
                regs[dst].as.i -= (regs[a].as.i * regs[b].as.i);
                break;
            case SUBOP_MADD_F32:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f += (regs[a].as.f * regs[b].as.f);
                break;
            case SUBOP_MSUB_F32:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f -= (regs[a].as.f * regs[b].as.f);
                break;
            case SUBOP_DOT_VEC2:
                regs[dst].type = VAL_FLOAT32;
                regs[dst].as.f += (regs[a].as.vec2.x * regs[b].as.vec2.x + regs[a].as.vec2.y * regs[b].as.vec2.y);
                break;
            default:
                regs[dst].as.i += (regs[a].as.i * regs[b].as.i);
                break;
        }
        DISPATCH();
    }

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
            citrine_scheduler_tick(vm, Citrine_GetDeltaTime());
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
        case 23: // DrawTriangle(x1, y1, x2, y2, x3, y3, color)
            Citrine_DrawTriangle(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i,
                (args[4].type == VAL_FLOAT32) ? args[4].as.f : (float)args[4].as.i,
                (args[5].type == VAL_FLOAT32) ? args[5].as.f : (float)args[5].as.i,
                (uint32_t)args[6].as.i
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
        case 35: // LoadSound(path)
            out_ret->type = VAL_HANDLE;
            out_ret->as.handle = Citrine_LoadSound(args[0].as.str);
            break;
        case 36: // PlaySound(id)
            Citrine_PlaySound(args[0].as.handle);
            break;
        case 37: // StopSound(id)
            Citrine_StopSound(args[0].as.handle);
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
        case 65: // Sleep(seconds)
            citrine_scheduler_sleep(vm, (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i);
            break;
        case 66: // FiberId()
            out_ret->type = VAL_INT32;
            out_ret->as.i = citrine_scheduler_current_fiber(vm);
            break;
        case 67: // FiberAlive(id)
            out_ret->type = VAL_BOOL;
            out_ret->as.i = citrine_scheduler_fiber_alive(vm, (uint32_t)args[0].as.i);
            break;
        case 70: // Log(msg) / puts / print
        case 71: { // DebugLog(msg) / debug_puts
            if (args[0].type == VAL_STRING && args[0].as.str) {
                printf("%s\n", args[0].as.str);
            } else if (args[0].type == VAL_INT32) {
                printf("%d\n", args[0].as.i);
            } else if (args[0].type == VAL_FLOAT32) {
                printf("%g\n", args[0].as.f);
            } else if (args[0].type == VAL_BOOL) {
                printf("%s\n", args[0].as.i ? "true" : "false");
            } else if (args[0].type == VAL_NIL) {
                printf("nil\n");
            } else {
                char tmp[128];
                citrine_value_to_str(args[0], tmp, sizeof(tmp));
                printf("%s\n", tmp);
            }
            fflush(stdout);
            break;
        }
        case 80: // ChannelNew(capacity)
            out_ret->type = VAL_HANDLE;
            out_ret->as.handle = citrine_channel_create(vm, (uint32_t)args[0].as.i);
            break;
        case 81: { // ChannelSend(chan, val)
            bool ok = citrine_channel_send(vm, args[0].as.handle, args[1]);
            out_ret->type = VAL_BOOL;
            out_ret->as.i = ok ? 1 : 0;
            break;
        }
        case 82: // ChannelReceive(chan)
            citrine_channel_receive(vm, args[0].as.handle, out_ret);
            break;
        case 83: // ChannelTryReceive(chan)
            citrine_channel_try_receive(vm, args[0].as.handle, out_ret);
            break;
        case 84: // ChannelCount(chan)
            out_ret->type = VAL_INT32;
            out_ret->as.i = citrine_channel_count(vm, args[0].as.handle);
            break;
        case 85: // ChannelCapacity(chan)
            out_ret->type = VAL_INT32;
            out_ret->as.i = citrine_channel_capacity(vm, args[0].as.handle);
            break;
        case 90: // LoadVideo(path)
            out_ret->type = VAL_HANDLE;
            out_ret->as.handle = Citrine_LoadVideo(args[0].as.str);
            break;
        case 91: // PlayVideo(id, loop)
            out_ret->type = VAL_BOOL;
            out_ret->as.i = Citrine_PlayVideo(args[0].as.handle, args[1].as.i != 0) ? 1 : 0;
            break;
        case 92: // DrawVideoFrame(id, x, y, w, h)
            Citrine_DrawVideoFrame(
                args[0].as.handle,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i,
                (args[4].type == VAL_FLOAT32) ? args[4].as.f : (float)args[4].as.i
            );
            break;
        case 93: // VideoFinished(id)
            out_ret->type = VAL_BOOL;
            out_ret->as.i = Citrine_VideoFinished(args[0].as.handle) ? 1 : 0;
            break;
        case 94: // PauseVideo(id)
            Citrine_PauseVideo(args[0].as.handle);
            break;
        case 95: // StopVideo(id)
            Citrine_StopVideo(args[0].as.handle);
            break;
        case 99: // Panic(msg)
            citrine_vm_panic(vm, "%s", args[0].as.str ? args[0].as.str : "User Panic");
            break;
        case 100: // DrawQuad(x1, y1, x2, y2, x3, y3, x4, y4, color)
            Citrine_DrawQuad(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i,
                (args[4].type == VAL_FLOAT32) ? args[4].as.f : (float)args[4].as.i,
                (args[5].type == VAL_FLOAT32) ? args[5].as.f : (float)args[5].as.i,
                (args[6].type == VAL_FLOAT32) ? args[6].as.f : (float)args[6].as.i,
                (args[7].type == VAL_FLOAT32) ? args[7].as.f : (float)args[7].as.i,
                (uint32_t)args[8].as.i
            );
            break;
        case 101: // GLBegin(mode)
            Citrine_GL_Begin(args[0].as.i);
            break;
        case 102: // GLEnd()
            Citrine_GL_End();
            break;
        case 103: { // GLVertex(x, y, [z])
            float vx = (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i;
            float vy = (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i;
            float vz = (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i;
            Citrine_GL_Vertex3f(vx, vy, vz);
            break;
        }
        case 104: { // GLColor(color or r, g, b, [a])
            if (args[0].type == VAL_COLOR || args[0].type == VAL_INT32) {
                Citrine_GL_ColorHex((uint32_t)args[0].as.i);
            } else {
                float cr = (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i / 255.0f;
                float cg = (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i / 255.0f;
                float cb = (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i / 255.0f;
                float ca = (args[3].type == VAL_FLOAT32) ? args[3].as.f : 1.0f;
                Citrine_GL_Color4f(cr, cg, cb, ca);
            }
            break;
        }
        case 105: // GLTexCoord(u, v)
            Citrine_GL_TexCoord2f(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i
            );
            break;
        case 106: // GLPushMatrix()
            Citrine_GL_PushMatrix();
            break;
        case 107: // GLPopMatrix()
            Citrine_GL_PopMatrix();
            break;
        case 108: // GLTranslate(x, y, [z])
            Citrine_GL_Translate(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i
            );
            break;
        case 109: // GLRotate(deg, x, y, z)
            Citrine_GL_Rotate(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : (float)args[2].as.i,
                (args[3].type == VAL_FLOAT32) ? args[3].as.f : (float)args[3].as.i
            );
            break;
        case 110: // GLScale(x, y, [z])
            Citrine_GL_Scale(
                (args[0].type == VAL_FLOAT32) ? args[0].as.f : (float)args[0].as.i,
                (args[1].type == VAL_FLOAT32) ? args[1].as.f : (float)args[1].as.i,
                (args[2].type == VAL_FLOAT32) ? args[2].as.f : 1.0f
            );
            break;
        case 111: // GLLoadIdentity()
            Citrine_GL_LoadIdentity();
            break;

        case 120: { // ArrayNew(capacity)
            uint32_t cap = (args[0].type == VAL_INT32 && args[0].as.i > 0) ? (uint32_t)args[0].as.i : 4;
            CitrineArray* arr = citrine_array_new(cap, false);
            out_ret->type = VAL_OBJECT;
            out_ret->as.ptr = arr;
            break;
        }
        case 121: { // ArrayGet(arr, index)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            int32_t idx = (args[1].type == VAL_INT32) ? args[1].as.i : 0;
            *out_ret = citrine_array_get(arr, idx);
            break;
        }
        case 122: { // ArraySet(arr, index, val)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            int32_t idx = (args[1].type == VAL_INT32) ? args[1].as.i : 0;
            citrine_array_set(arr, idx, args[2]);
            *out_ret = args[2];
            break;
        }
        case 123: { // ArrayPush(arr, val)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            citrine_array_push(arr, args[1]);
            *out_ret = args[0];
            break;
        }
        case 124: { // ArrayPop(arr)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            *out_ret = citrine_array_pop(arr);
            break;
        }
        case 125: { // ArraySize(arr)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            out_ret->type = VAL_INT32;
            out_ret->as.i = arr ? (int32_t)arr->size : 0;
            break;
        }
        case 126: { // ArrayClear(arr)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            if (arr) arr->size = 0;
            out_ret->type = VAL_NIL;
            break;
        }

        case 130: { // StaticArrayNew(size, [default_val])
            uint32_t sz = (args[0].type == VAL_INT32 && args[0].as.i > 0) ? (uint32_t)args[0].as.i : 1;
            CitrineArray* arr = citrine_array_new(sz, true);
            if (arr) {
                Value def_val = { .type = VAL_NIL, .flags = 0, .as = { .i = 0 } };
                if (args[1].type != VAL_NIL) def_val = args[1];
                for (uint32_t i = 0; i < sz; i++) arr->elements[i] = def_val;
            }
            out_ret->type = VAL_OBJECT;
            out_ret->as.ptr = arr;
            break;
        }
        case 131: { // StaticArrayGet(arr, index)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            int32_t idx = (args[1].type == VAL_INT32) ? args[1].as.i : 0;
            *out_ret = citrine_array_get(arr, idx);
            break;
        }
        case 132: { // StaticArraySet(arr, index, val)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            int32_t idx = (args[1].type == VAL_INT32) ? args[1].as.i : 0;
            citrine_array_set(arr, idx, args[2]);
            *out_ret = args[2];
            break;
        }
        case 133: { // StaticArraySize(arr)
            CitrineArray* arr = (CitrineArray*)args[0].as.ptr;
            out_ret->type = VAL_INT32;
            out_ret->as.i = arr ? (int32_t)arr->size : 0;
            break;
        }

        case 140: { // MemoryIONew([capacity_or_str])
            size_t cap = 64;
            if (args[0].type == VAL_INT32 && args[0].as.i > 0) cap = (size_t)args[0].as.i;
            CitrineMemoryIO* io = citrine_memory_io_new(cap);
            if (args[0].type == VAL_STRING && args[0].as.str) {
                citrine_memory_io_write(io, args[0].as.str, strlen(args[0].as.str));
            }
            out_ret->type = VAL_OBJECT;
            out_ret->as.ptr = io;
            break;
        }
        case 141: { // MemoryIOWriteByte(io, byte)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            citrine_memory_io_write_byte(io, (uint8_t)args[1].as.i);
            out_ret->type = VAL_NIL;
            break;
        }
        case 142: { // MemoryIOWrite(io, val)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            char tmp[128];
            citrine_value_to_str(args[1], tmp, sizeof(tmp));
            citrine_memory_io_write(io, tmp, strlen(tmp));
            out_ret->type = VAL_NIL;
            break;
        }
        case 143: { // MemoryIOPuts(io, val)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            char tmp[128];
            citrine_value_to_str(args[1], tmp, sizeof(tmp));
            citrine_memory_io_puts(io, tmp);
            out_ret->type = VAL_NIL;
            break;
        }
        case 144: { // MemoryIOToS(io)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            out_ret->type = VAL_STRING;
            out_ret->as.str = citrine_memory_io_to_s(io);
            break;
        }
        case 145: { // MemoryIORewind(io)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            if (io) io->pos = 0;
            out_ret->type = VAL_NIL;
            break;
        }
        case 146: { // MemoryIOPos(io)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            out_ret->type = VAL_INT32;
            out_ret->as.i = io ? (int32_t)io->pos : 0;
            break;
        }
        case 147: { // MemoryIOSize(io)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            out_ret->type = VAL_INT32;
            out_ret->as.i = io ? (int32_t)io->size : 0;
            break;
        }
        case 148: { // MemoryIOClear(io)
            CitrineMemoryIO* io = (CitrineMemoryIO*)args[0].as.ptr;
            if (io) {
                io->size = 0;
                io->pos = 0;
                if (io->buffer) io->buffer[0] = '\0';
            }
            out_ret->type = VAL_NIL;
            break;
        }

        case 150: { // ObjectNew(class_id, field_count)
            uint32_t cid = (uint32_t)args[0].as.i;
            uint32_t fcount = (uint32_t)args[1].as.i;
            CitrineObject* obj = citrine_object_new(cid, fcount);
            out_ret->type = VAL_OBJECT;
            out_ret->as.ptr = obj;
            break;
        }
        case 151: { // ObjectGetField(obj, field_idx)
            CitrineObject* obj = (CitrineObject*)args[0].as.ptr;
            uint32_t f_idx = (uint32_t)args[1].as.i;
            if (obj && f_idx < obj->field_count) {
                *out_ret = obj->fields[f_idx];
            } else {
                out_ret->type = VAL_NIL;
            }
            break;
        }
        case 152: { // ObjectSetField(obj, field_idx, val)
            CitrineObject* obj = (CitrineObject*)args[0].as.ptr;
            uint32_t f_idx = (uint32_t)args[1].as.i;
            if (obj && f_idx < obj->field_count) {
                obj->fields[f_idx] = args[2];
            }
            *out_ret = args[2];
            break;
        }

        default:
            break;
    }
}
