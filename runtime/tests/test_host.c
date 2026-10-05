#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>
#include "../include/citrine_vm.h"
#include "../include/citrine.h"

// Macro helper to construct a 32-bit Citrine-32 instruction word
#define ENC_INSTR(op, subop, dst, a, b) \
    (((uint32_t)(op) << 27) | (((uint32_t)(subop) & 0x7) << 24) | \
     (((uint32_t)(dst) & 0xFF) << 16) | (((uint32_t)(a) & 0xFF) << 8) | ((uint32_t)(b) & 0xFF))

#define ENC_IMM(op, subop, dst, imm16) \
    (((uint32_t)(op) << 27) | (((uint32_t)(subop) & 0x7) << 24) | \
     (((uint32_t)(dst) & 0xFF) << 16) | ((uint32_t)(imm16) & 0xFFFF))

#define ENC_JUMP24(op, subop, offset24) \
    (((uint32_t)(op) << 27) | (((uint32_t)(subop) & 0x7) << 24) | ((uint32_t)(offset24) & 0xFFFFFF))

static void build_cbc2(uint8_t* buf, size_t* out_size, const uint32_t* instructions, size_t num_instr) {
    uint8_t* p = buf;
    
    // Magic CBC2
    memcpy(p, "CBC2", 4); p += 4;
    // Version 2
    *(uint16_t*)p = 2; p += 2;
    // Num functions = 1
    *(uint32_t*)p = 1; p += 4;
    // Num constants = 0
    *(uint32_t*)p = 0; p += 4;
    // Num strings = 0
    *(uint32_t*)p = 0; p += 4;

    // Function 0 (__main__)
    *(uint32_t*)p = 0; p += 4;       // name_idx
    *p++ = 0;                         // argc
    *p++ = 32;                        // num_registers
    *(uint32_t*)p = 0; p += 4;       // code_offset
    *(uint32_t*)p = (uint32_t)num_instr; p += 4; // instruction_count

    // Bytecode instructions
    memcpy(p, instructions, num_instr * sizeof(uint32_t));
    p += num_instr * sizeof(uint32_t);

    *out_size = p - buf;
}

int main(void) {
    printf("====================================================\n");
    printf(" Citrine-32 ISA C Runtime Host Test Suite\n");
    printf("====================================================\n\n");

    // Test 1: Immediate loading and basic arithmetic
    {
        printf("[Test 1] Immediate Load & Arithmetic ALU... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 100),       // r0 = 100
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 45),        // r1 = 45
            ENC_INSTR(OP_ADD, SUBOP_ADD_I32, 2, 0, 1),           // r2 = r0 + r1 (145)
            ENC_INSTR(OP_SUB, SUBOP_SUB_I32, 3, 0, 1),           // r3 = r0 - r1 (55)
            ENC_INSTR(OP_MUL, SUBOP_MUL_LO, 4, 0, 1),            // r4 = r0 * r1 (4500)
            ENC_INSTR(OP_DIV_MOD, SUBOP_DIV_S32, 5, 0, 1),       // r5 = r0 / r1 (2)
            ENC_INSTR(OP_DIV_MOD, SUBOP_MOD_S32, 6, 0, 1),       // r6 = r0 % r1 (10)
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)           // HALT
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[2].as.i == 145);
        assert(vm->spram_regs[3].as.i == 55);
        assert(vm->spram_regs[4].as.i == 4500);
        assert(vm->spram_regs[5].as.i == 2);
        assert(vm->spram_regs[6].as.i == 10);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 2: Bitwise and Shift Operations
    {
        printf("[Test 2] Bitwise & Shift Operations... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 0x0F0F),
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 0x00FF),
            ENC_INSTR(OP_BITWISE, SUBOP_BIT_AND, 2, 0, 1),       // r2 = 0x000F
            ENC_INSTR(OP_BITWISE, SUBOP_BIT_OR, 3, 0, 1),        // r3 = 0x0FFF
            ENC_INSTR(OP_BITWISE, SUBOP_BIT_XOR, 4, 0, 1),       // r4 = 0x0FF0
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 5, 4),         // r5 = 4
            ENC_INSTR(OP_SHIFT, SUBOP_SHIFT_SLL, 6, 0, 5),       // r6 = 0x0F0F << 4 = 0xF0F0
            ENC_INSTR(OP_SHIFT, SUBOP_SHIFT_SRL, 7, 0, 5),       // r7 = 0x0F0F >> 4 = 0x00F0
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[2].as.i == 0x000F);
        assert(vm->spram_regs[3].as.i == 0x0FFF);
        assert(vm->spram_regs[4].as.i == 0x0FF0);
        assert(vm->spram_regs[6].as.i == 0xF0F0);
        assert(vm->spram_regs[7].as.i == 0x00F0);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 3: Peephole Fused Compare-and-Branch (OP_BRANCH_CMP)
    {
        printf("[Test 3] Fused Compare-and-Branch (OP_BRANCH_CMP)... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 42),        // r0 = 42
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 42),        // r1 = 42
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 2, 0),         // r2 = 0 (marker)
            // Branch if r0 == r1: skip the next instruction (+1 instruction from PC)
            ENC_INSTR(OP_BRANCH_CMP, SUBOP_BRCMP_BEQ, 0, 1, 1),  // if r0 == r1 goto +1 (skip r2=999)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 2, 999),       // r2 = 999 (should be skipped!)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 3, 1),         // r3 = 1
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[2].as.i == 0); // r2 was never set to 999
        assert(vm->spram_regs[3].as.i == 1);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 4: Peephole Fused Loop Decrement & Branch (OP_LOOP_DEC_BR)
    {
        printf("[Test 4] Fused Loop Decrement & Branch (OP_LOOP_DEC_BR)... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 10),        // r0 = 10 (loop counter)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 0),         // r1 = 0 (accumulator)
            // Loop body:
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 2, 5),         // r2 = 5
            ENC_INSTR(OP_ADD, SUBOP_ADD_I32, 1, 1, 2),           // r1 = r1 + 5
            // Fused dec and branch if non-zero: r0 -= 1, if r0 != 0 goto loop body (-3)
            ENC_IMM(OP_LOOP_DEC_BR, SUBOP_DECBR_NZ, 0, (int16_t)-3),
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        // 10 iterations * 5 = 50
        assert(vm->spram_regs[0].as.i == 0);
        assert(vm->spram_regs[1].as.i == 50);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 5: Peephole Fused Multiply-Accumulate (OP_FUSED_MADD)
    {
        printf("[Test 5] Fused Multiply-Accumulate (OP_FUSED_MADD)... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 100),       // r0 = 100 (accumulator)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 7),         // r1 = 7
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 2, 8),         // r2 = 8
            ENC_INSTR(OP_FUSED_MADD, SUBOP_MADD_I32, 0, 1, 2),   // r0 += 7 * 8 (100 + 56 = 156)
            ENC_INSTR(OP_FUSED_MADD, SUBOP_MSUB_I32, 0, 1, 2),   // r0 -= 7 * 8 (156 - 56 = 100)
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[0].as.i == 100);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 6: Vector2 Math and Properties
    {
        printf("[Test 6] Vector2 Math & Property Access... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 10),        // r0 = 10
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 20),        // r1 = 20
            ENC_INSTR(OP_VEC2_MATH, SUBOP_VEC2_NEW, 2, 0, 1),    // r2 = Vector2(10, 20)
            ENC_INSTR(OP_VEC2_PROP, SUBOP_VPROP_X, 3, 2, 0),     // r3 = r2.x (10.0f)
            ENC_INSTR(OP_VEC2_PROP, SUBOP_VPROP_Y, 4, 2, 0),     // r4 = r2.y (20.0f)
            ENC_INSTR(OP_VEC2_MATH, SUBOP_VEC2_ADD, 5, 2, 2),    // r5 = r2 + r2 = Vector2(20, 40)
            ENC_INSTR(OP_VEC2_PROP, SUBOP_VPROP_X, 6, 5, 0),     // r6 = r5.x (20.0f)
            ENC_INSTR(OP_VEC2_PROP, SUBOP_VPROP_Y, 7, 5, 0),     // r7 = r5.y (40.0f)
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[2].type == VAL_VEC2);
        assert(vm->spram_regs[3].as.f == 10.0f);
        assert(vm->spram_regs[4].as.f == 20.0f);
        assert(vm->spram_regs[6].as.f == 20.0f);
        assert(vm->spram_regs[7].as.f == 40.0f);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    // Test 7: Unconditional 24-bit Jump (OP_JUMP)
    {
        printf("[Test 7] 24-bit Unconditional Jump (OP_JUMP)... ");
        uint32_t code[] = {
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 1),         // r0 = 1
            ENC_JUMP24(OP_JUMP, SUBOP_JUMP_REL24, 1),            // PC += 1 (skip next instr)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 0, 999),       // r0 = 999 (skipped!)
            ENC_IMM(OP_LOAD_IMM, SUBOP_IMM_INT16, 1, 777),       // r1 = 777
            ENC_INSTR(OP_SYS, SUBOP_SYS_HALT, 0, 0, 0)
        };
        uint8_t cbc_buf[512];
        size_t cbc_size = 0;
        build_cbc2(cbc_buf, &cbc_size, code, sizeof(code)/sizeof(code[0]));

        CitrineVM* vm = citrine_vm_create(cbc_buf, cbc_size);
        assert(vm != NULL);
        citrine_vm_run(vm);

        assert(vm->spram_regs[0].as.i == 1);
        assert(vm->spram_regs[1].as.i == 777);
        citrine_vm_destroy(vm);
        printf("PASSED\n");
    }

    printf("\n>>> ALL 7 HOST C RUNTIME TESTS PASSED WITH 100%% SUCCESS! <<<\n");
    return 0;
}
