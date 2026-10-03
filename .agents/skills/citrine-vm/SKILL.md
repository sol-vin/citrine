---
name: citrine-vm
description: Authoritative guide for Citrine Virtual Machine architecture, bytecode instruction set, opcode encoding, register allocation, direct-threaded C runtime, and MIPS R5900 JIT emitter on PlayStation 2. Use when writing compiler passes, adding VM instructions, inspecting bytecode (.cbc), implementing native calls, or debugging EE execution.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: virtual-machines
  triggers: Citrine VM, Bytecode, Opcode, NativeId, CBC, RegisterAllocator, ElfBuilder, MipsEmitter, direct-threaded, virtual registers
  role: specialist
  scope: implementation
  output-format: code
  related-skills: ps2-dev, pcsx2-cli, r2-ps2-debug, cpp-pro
---

# Citrine Virtual Machine Architecture & Bytecode Specification

Specialist guide for the Citrine Virtual Machine (Citrine VM), targeting the Sony PlayStation 2 Emotion Engine (EE MIPS R5900 @ 294 MHz).

## Core Architecture Overview

Citrine VM executes fixed-width 32-bit instructions using a flat 256-register file (`$r0`..`$r255`) per call frame.

```text
+--------------------------------------------------------------------------+
|                     Citrine Virtual Machine Architecture                 |
|  - 32-bit Little-Endian Fixed-Width Instruction Words                    |
|  - Flat 256 Virtual Registers per Frame ($r0..$r255)                     |
|  - Direct-Threaded C Engine (GCC computed gotos: &&DO_OP)                |
|  - Direct MIPS R5900 JIT / Machine Code Emitter (Citrine::ElfBuilder)    |
|  - Fixed 256-level Activation Frame Call Stack (zero dynamic stack GC)   |
+--------------------------------------------------------------------------+
```

## Instruction Formats (32-bit)

Instructions use three encodings, always 4-byte aligned:

```text
1. ABC Format (3-Register Arithmetic & Logic):
 31       24 23       16 15        8 7         0
+-----------+-----------+-----------+-----------+
|  Opcode   |  Dst Reg  |   Reg A   |   Reg B   |
+-----------+-----------+-----------+-----------+

2. AB_IMM Format (Immediate Loading & Native Calls):
 31       24 23       16 15                    0
+-----------+-----------+-----------------------+
|  Opcode   |  Dst Reg  |    Immediate UInt16   |
+-----------+-----------+-----------------------+

3. BRANCH Format (Relative Conditional & Unconditional Jumps):
 31       24 23       16 15                    0
+-----------+-----------+-----------------------+
|  Opcode   | Cond Reg  |    Signed Int16 PC    |
+-----------+-----------+-----------------------+
```

## Opcode Table (Citrine::Opcode)

| Opcode | Hex | Format | Semantics | MIPS R5900 Translation |
|---|---|---|---|---|
| `Nop` | 0x00 | ABC | No operation | `nop` |
| `Move` | 0x01 | ABC | `R[dst] = R[a]` | `move $dst, $a` |
| `LoadNil` | 0x02 | ABC | `R[dst] = Nil` | `move $dst, $zero` |
| `LoadBool` | 0x03 | ABC | `R[dst] = (b != 0)` | `ori $dst, $zero, b` |
| `LoadInt` | 0x04 | AB_IMM | `R[dst] = imm16` | `addiu $dst, $zero, imm16` |
| `LoadConst`| 0x05 | AB_IMM | `R[dst] = ConstPool[imm]`| Load address from `.rodata` |
| `Add` | 0x0A | ABC | `R[dst] = R[a] + R[b]` | `addu $dst, $a, $b` (or StringConcat) |
| `Sub` | 0x0B | ABC | `R[dst] = R[a] - R[b]` | `subu $dst, $a, $b` |
| `Mul` | 0x0C | ABC | `R[dst] = R[a] * R[b]` | `mult $a, $b; mflo $dst` |
| `Div` | 0x0D | ABC | `R[dst] = R[a] / R[b]` | `div $a, $b; mflo $dst` |
| `Mod` | 0x0E | ABC | `R[dst] = R[a] % R[b]` | `div $a, $b; mfhi $dst` |
| `Neg` | 0x0F | ABC | `R[dst] = -R[a]` | `subu $dst, $zero, $a` |
| `BitAnd` | 0x10 | ABC | `R[dst] = R[a] & R[b]` | `and $dst, $a, $b` |
| `BitOr` | 0x11 | ABC | `R[dst] = R[a] \| R[b]`| `or $dst, $a, $b` |
| `BitXor` | 0x12 | ABC | `R[dst] = R[a] ^ R[b]` | `xor $dst, $a, $b` |
| `ShiftLeft`| 0x13 | ABC | `R[dst] = R[a] << R[b]`| `sllv $dst, $a, $b` |
| `ShiftRight`| 0x1B | ABC | `R[dst] = R[a] >> R[b]`| `srav $dst, $a, $b` |
| `BitNot` | 0x1C | ABC | `R[dst] = ~R[a]` | `nor $dst, $a, $zero` |
| `Vec2New` | 0x14 | ABC | `R[dst] = Vector2(R[a], R[b])` | Allocates Vec2 primitive |
| `Vec2GetX`| 0x15 | ABC | `R[dst] = R[a].x` | Float load from slot |
| `Vec2GetY`| 0x16 | ABC | `R[dst] = R[a].y` | Float load from slot |
| `Vec2SetX`| 0x17 | ABC | `R[dst].x = R[a]` | Float store to slot |
| `Vec2SetY`| 0x18 | ABC | `R[dst].y = R[a]` | Float store to slot |
| `Vec2Add` | 0x19 | ABC | `R[dst] = R[a] + R[b]` | Vec2 component-wise add |
| `ColorNew`| 0x1A | ABC | `R[dst] = RGBA(R[a..a+3])`| Packs RGBA into 32-bit word |
| `Eq` | 0x1E | ABC | `R[dst] = (R[a] == R[b])`| Content comparison |
| `Ne` | 0x1F | ABC | `R[dst] = (R[a] != R[b])`| Content comparison |
| `Lt` | 0x20 | ABC | `R[dst] = (R[a] < R[b])` | `slt $dst, $a, $b` |
| `Le` | 0x21 | ABC | `R[dst] = (R[a] <= R[b])`| `slt $dst, $b, $a; xori $dst, 1` |
| `Gt` | 0x22 | ABC | `R[dst] = (R[a] > R[b])` | `slt $dst, $b, $a` |
| `Ge` | 0x23 | ABC | `R[dst] = (R[a] >= R[b])`| `slt $dst, $a, $b; xori $dst, 1` |
| `Jump` | 0x28 | BRANCH | `PC += 1 + offset` | `j / b label` |
| `JumpIfTrue`| 0x29 | BRANCH | If `R[cond]`, jump | `bne $cond, $zero, label` |
| `JumpIfFalse`| 0x2A | BRANCH | If `!R[cond]`, jump | `beq $cond, $zero, label` |
| `Call` | 0x32 | AB_IMM | Call function `imm` | `jal target; nop` |
| `Return` | 0x33 | ABC | Return `R[src]` to caller| `move $v0, $src; jr $ra; nop` |
| `CallNative`| 0x34 | AB_IMM | Call native service `imm`| Invoke host / hardware driver |
| `SpawnFiber`| 0x3C | AB_IMM | Allocate new fiber | Coroutine context initialization |
| `Yield` | 0x3D | ABC | Suspend current fiber | Switch to scheduler |
| `ResumeFiber`| 0x3E | ABC | Resume fiber `R[a]` | Switch execution to fiber |
| `Halt` | 0x46 | ABC | Park EE CPU / stop VM | Terminate execution |

## Calling Conventions

- **Return Register**: `$r0` is the designated return value accumulator.
- **Parameters**: Passed in registers `$r1` through `$r15`.
- **Caller Dest**: The calling instruction `Call dst, fn_idx` specifies the register `dst` where the callee's `$r0` will be transferred on `Return`.
- **Register Allocation**: Managed via linear-scan `Citrine::Compiler::RegisterAllocator`. Scratch and intermediate values reside in registers `$r16` through `$r255`.

## Compiling & Disassembling

```bash
# Compile Crystal code to Citrine Bytecode (.cbc)
citrine compile src/main.cr -o build/game.cbc

# Inspect instructions and symbols
citrine disasm build/game.cbc
```
