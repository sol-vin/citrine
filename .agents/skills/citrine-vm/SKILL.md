---
name: citrine-vm
description: Authoritative guide for Citrine Virtual Machine architecture, Citrine-32 instruction set, opcode encoding, register allocation, direct-threaded C runtime, and MIPS R5900 JIT emitter on PlayStation 2. Use when writing compiler passes, adding VM instructions, inspecting bytecode (.cbc), implementing native calls, or debugging EE execution.
license: MIT
metadata:
  author: Citrine Project
  version: "2.0.0"
  domain: virtual-machines
  triggers: Citrine VM, Citrine-32, Bytecode, Opcode, NativeId, CBC, CBC2, RegisterAllocator, ElfBuilder, MipsEmitter, direct-threaded, virtual registers, peephole fusion
  role: specialist
  scope: implementation
  output-format: code
  related-skills: ps2-dev, pcsx2-cli, r2-ps2-debug, cpp-pro
---

# Citrine Virtual Machine Architecture & Bytecode Specification (Citrine-32 ISA)

Specialist guide for the Citrine Virtual Machine (Citrine-32 ISA), targeting the Sony PlayStation 2 Emotion Engine (EE MIPS R5900 @ 294.912 MHz).

## Core Architecture Overview

Citrine-32 compresses all VM semantics into **exactly 32 primary opcodes** (`0x00` through `0x1F`, 5-bit opcode field in bits `[31:27]` with 3-bit sub-opcodes in `[26:24]`), preserving 100% of language capabilities, AST transformations, and PS2 hardware subsystem emulation.

```text
+--------------------------------------------------------------------------+
|                     Citrine-32 Virtual Machine Architecture              |
|  - 32-bit Little-Endian Fixed-Width Instruction Words                    |
|  - 5-bit Primary Opcode [31:27] -> zero-mask extraction: instr >> 27     |
|  - 3-bit Sub-Opcode [26:24] providing 256 unique instruction variants   |
|  - Flat 256 Virtual Registers per Frame ($r0..$r255, 16-byte aligned)    |
|  - 128-byte Primary Dispatch Table (locks into 2 L1 D-Cache lines)       |
|  - Direct-Threaded C Engine (GCC computed gotos: &&do_op)                |
|  - Direct MIPS R5900 JIT / Machine Code Emitter (Citrine::ElfBuilder)    |
|  - Peephole Fusions: BranchCmp, LoopDecBr, FusedMadd                     |
|  - Zero-Stack Tail Calls & 24-bit Unconditional Jump Reach (32 MB)       |
+--------------------------------------------------------------------------+
```

## Instruction Formats (32-bit)

Instructions use four encodings, always 4-byte aligned:

```text
1. Format ABC (Register-to-Register Arithmetic, Logic, Vectors):
 31     27 26   24 23       16 15        8 7         0
+---------+-------+-----------+-----------+-----------+
| Primary | SubOp |  Dst Reg  |   Reg A   |   Reg B   |
+---------+-------+-----------+-----------+-----------+

2. Format AB_IMM (Immediate Loading, Calls, Fibers, Channels):
 31     27 26   24 23       16 15                    0
+---------+-------+-----------+-----------------------+
| Primary | SubOp |  Dst Reg  |    Immediate UInt16   |
+---------+-------+-----------+-----------------------+

3. Format BRANCH_CMP (Fused Compare-and-Branch):
 31     27 26   24 23       16 15        8 7         0
+---------+-------+-----------+-----------+-----------+
| Primary | SubOp |  Dst Reg  |   Reg A   |  Offset8  |
+---------+-------+-----------+-----------+-----------+

4. Format JUMP24 (Unconditional 24-bit Relative Jump):
 31     27 26   24 23                                0
+---------+-------+-----------------------------------+
| Primary | SubOp |         Signed 24-bit Offset      |
+---------+-------+-----------------------------------+
```

## The 32 Primary Opcodes (Citrine::Opcode)

| Primary Opcode | Hex | Sub-Opcodes (`0..7`) | Semantics | MIPS R5900 Translation |
|---|---|---|---|---|
| `OP_SYS` | `0x00` | `0:NOP`, `1:HALT`, `2:BREAK`, `3:SYNC`, `4:FLUSH_I`, `5:FLUSH_D`, `6:WD_RESET`, `7:PROF_MARK` | System control & hardware sync | `nop`, `sync.l`, `break` |
| `OP_MOVE` | `0x01` | `0:MOVE32`, `1:MOVE64`, `2:MOVE128`, `3:CMOVZ`, `4:CMOVN`, `5:SWAP` | Register copy & conditional moves | `move $dst, $a`, `movz`, `movn` |
| `OP_LOAD_CONST` | `0x02` | `0..7`: Constant pool tag | Load constant from pool at `imm16` | Pointer load from `.rodata` |
| `OP_LOAD_IMM` | `0x03` | `0:NIL`, `1:BOOL`, `2:INT16`, `3:UINT16`, `4:UPPER16`, `5:ZERO`, `6:MINUS1` | Load immediate values | `ori $dst, $zero, imm16` |
| `OP_LOAD_MEM` | `0x04` | `0:LB`, `1:LBU`, `2:LH`, `3:LHU`, `4:LW`, `5:LWC1`, `6:LD`, `7:LQ` | Memory loads (including 128-bit Quadword) | `lb`, `lh`, `lw`, `lwc1`, `ld`, `lq` |
| `OP_STORE_MEM` | `0x05` | `0:SB`, `1:SH`, `2:SW`, `3:SWC1`, `4:SD`, `5:SQ` | Memory stores | `sb`, `sh`, `sw`, `swc1`, `sd`, `sq` |
| `OP_ADD` | `0x06` | `0:I32`, `1:U32`, `2:SAT`, `3:STR_CONCAT`, `4:IMM8` | Integer addition & string concatenation | `addu $dst, $a, $b` |
| `OP_SUB` | `0x07` | `0:I32`, `1:U32`, `2:SAT`, `3:NEG`, `4:IMM8` | Integer subtraction & negation | `subu $dst, $a, $b` |
| `OP_MUL` | `0x08` | `0:LO`, `1:HI`, `2:UHI`, `3:SAT`, `4:IMM8` | Integer multiplication | `mult $a, $b; mflo $dst` |
| `OP_DIV_MOD` | `0x09` | `0:DIV_S32`, `1:MOD_S32`, `2:DIV_U32`, `3:MOD_U32` | Division and modulo (guarded) | `div $a, $b; mflo/mfhi $dst` |
| `OP_BITWISE` | `0x0A` | `0:AND`, `1:OR`, `2:XOR`, `3:NOR`, `4:AND_NOT`, `5:XNOR` | Bitwise logical operations | `and`, `or`, `xor`, `nor` |
| `OP_SHIFT` | `0x0B` | `0:SLL`, `1:SRL`, `2:SRA`, `3:ROTL`, `4:ROTR`, `5:CLZ` | Bit shifts, rotates, count leading zeros | `sllv`, `srlv`, `srav` |
| `OP_COMPARE` | `0x0C` | `0:EQ`, `1:NE`, `2:LT`, `3:LE`, `4:GT`, `5:GE`, `6:STR_EQ`, `7:PTR_EQ` | Register relational comparisons | `slt $dst, $a, $b` |
| `OP_TEST` | `0x0D` | `0:NIL`, `1:NOT_NIL`, `2:ZERO`, `3:NOT_ZERO`, `4:TRUTHY`, `5:FALSY`, `6:TAG`, `7:BIT` | Fast boolean & type testing | Zero & tag tests |
| `OP_FLOAT_ALU` | `0x0E` | `0:ADD`, `1:SUB`, `2:MUL`, `3:DIV`, `4:NEG`, `5:ABS`, `6:SQRT`, `7:CVT` | Single-precision float operations | `add.s`, `sub.s`, `mul.s`, `div.s` |
| `OP_JUMP` | `0x0F` | `0:REL24`, `1:REL16`, `2:REG`, `3:TABLE` | 24-bit relative jump (32 MB reach) | `j / b label; nop` |
| `OP_BRANCH_Z` | `0x10` | `0:TRUTHY`, `1:FALSY`, `2:ZERO`, `3:NONZERO`, `4:POS`, `5:NEG` | Branch on register zero / truthiness | `beq`, `bne`, `bgtz`, `bltz` |
| `OP_BRANCH_CMP`| `0x11` | `0:BEQ`, `1:BNE`, `2:BLT`, `3:BLE`, `4:BGT`, `5:BGE` | **Fused Compare-and-Branch** | Fused `beq`, `bne`, `slt + beq` |
| `OP_CALL` | `0x12` | `0:DIRECT`, `1:INDIRECT`, `2:TAIL_DIRECT`, `3:TAIL_INDIRECT` | Function call & tail-call elimination | `jal target; nop` |
| `OP_RETURN` | `0x13` | `0:VAL`, `1:NIL`, `2:VOID`, `3:MULTI` | Return value from frame | `jr $ra; nop` |
| `OP_CALL_NATIVE`| `0x14`| `0:KERNEL`, `1:GS`, `2:AUDIO`, `3:PAD`, `4:VIDEO`, `5:HUD`, `6:IO`, `7:USER` | Native hardware subsystem trampoline | Domain-partitioned C driver |
| `OP_VEC2_MATH` | `0x15` | `0:NEW`, `1:ADD`, `2:SUB`, `3:MUL`, `4:DIV`, `5:SCALE`, `6:DOT`, `7:CROSS` | Vector2 arithmetic & products | `PADDW` (128-bit MMI SIMD) |
| `OP_VEC2_PROP` | `0x16` | `0:GET_X`, `1:GET_Y`, `2:SET_X`, `3:SET_Y`, `4:LEN`, `5:LENSQ`, `6:NORM`, `7:LERP`| Vector2 property access & normalization | Float slot extraction |
| `OP_COLOR_OP` | `0x17` | `0:RGBA32`, `1:RGBA16`, `2:UNPACK`, `3:LERP`, `4:MODULATE`, `5:PREMUL` | Packed RGBA color constructors & blend | `PPAC5` (128-bit RGBA pack) |
| `OP_SIMD_MMI` | `0x18` | `0:PADDB`, `1:PADDW`, `2:PSUBW`, `3:PMULTH`, `4:PMAXW`, `5:PMINW`, `6:PEXTW`, `7:PPACW` | Emotion Engine MMI SIMD instructions | `paddw`, `psubw`, `pmaxw`, `pminw` |
| `OP_COLLECTION` | `0x19` | `0:AGET`, `1:ASET`, `2:ALEN`, `3:APUSH`, `4:APOP`, `5:FGET`, `6:FSET`, `7:HGET` | Array indexing, field get/set | Array & object operations |
| `OP_FIBER_OP` | `0x1A` | `0:SPAWN`, `1:YIELD`, `2:RESUME`, `3:STATUS`, `4:KILL`, `5:ID`, `6:SLEEP` | Concurrency fibers | Scheduler context switch |
| `OP_CHANNEL_OP` | `0x1B` | `0:CREATE`, `1:SEND`, `2:RECV`, `3:TRY_RECV`, `4:COUNT`, `5:CAP`, `6:CLOSE` | CSP channels | Channel ring buffer |
| `OP_PS2_HW` | `0x1C` | `0:GIF`, `1:VIF1`, `2:WAIT`, `3:VSYNC`, `4:SWAP`, `5:KEYON`, `6:PAD` | PS2 hardware registers & DMA | Direct GIF / GS DMA |
| `OP_INLINE_ASM` | `0x1D` | `0:MFC0`, `1:MTC0`, `2:VU0`, `3:SPRAM`, `4:PERF_START`, `5:PERF_STOP` | Privileged COP0/COP2 registers & timers | `mfc0`, `mtc0`, perf counters |
| `OP_LOOP_DEC_BR`| `0x1E` | `0:DECBR_NZ`, `1:DECBR_GEZ`, `2:INCBR_LT` | **Fused Loop Decrement/Increment & Branch** | Fused counter loop branch |
| `OP_FUSED_MADD` | `0x1F` | `0:MADD_I32`, `1:MSUB_I32`, `2:MADD_F32`, `3:MSUB_F32`, `4:DOT_VEC2` | **Fused Multiply-Accumulate** | `madd`, `msub`, `madd.s` |

---

## Detailed References

| Topic | Reference | Content |
|:---|:---|:---|
| R5900 JIT Machine Code Emission | [r5900-jit-emission.md](./references/r5900-jit-emission.md) | Translating Citrine bytecodes to native R5900, 128-bit MMI instructions, branch delay slot invariants, SPRAM fast frames |

---

## Calling Conventions

- **Return Register**: `$r0` is the designated return value accumulator.
- **Parameters**: Passed in registers `$r1` through `$r15`.
- **Caller Dest**: The calling instruction `Call dst, fn_idx` specifies the register `dst` where the callee's `$r0` will be transferred on `Return`.
- **Register Allocation**: Managed via linear-scan `Citrine::Compiler::RegisterAllocator`. Scratch and intermediate values reside in registers `$r16` through `$r255`.

## Compiling & Disassembling

```bash
# Compile Crystal code to Citrine Bytecode (.cbc)
citrine compile src/main.cr -o build/game.cbc

# Inspect instructions and symbols using Citrine-32 dot-notation disassembly
citrine disasm build/game.cbc
```

## Mandatory Constraints & Rules

- **Branch Delay Slot Preservation**: Every branch emitted by `Citrine::Compiler::MipsEmitter` (`bne`, `beq`, `j`, `jal`) must be followed by a valid instruction or `nop` (`0x00000000`). Never emit a branch inside a delay slot.
- **128-bit Quadword Alignment**: When emitting vector load/store instructions (`lq`/`sq`), verify that the target memory pointer is 16-byte aligned.
- **Zero-Mask Opcode Extraction**: Always decode primary opcode using `raw >> 27` (5 bits). Sub-opcode is extracted with `(raw >> 24) & 0x07`.
