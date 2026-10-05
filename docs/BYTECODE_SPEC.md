# Citrine Virtual Machine & Bytecode Specification (Citrine-32 ISA)

**Version**: 2.0 (Citrine-32 ISA)  
**Target Hardware**: Sony PlayStation 2 (Emotion Engine MIPS R5900 @ 294.912 MHz)  
**Binary Container**: `.cbc` (`CBC2` Container Format)

---

## 1. Architectural Highlights: The Citrine-32 ISA

The Citrine Virtual Machine ISA compresses all execution semantics into **exactly 32 primary opcodes** (`0x00` through `0x1F`), preserving 100% of Citrine's capabilities, PlayStation 2 hardware subsystem access, and compiler AST transformations while unlocking massive frame-time reductions on the Sony PlayStation 2 Emotion Engine.

### 1.1 Emotion Engine MIPS R5900 Hardware Advantages
- **Zero-Mask Opcode Extraction**: Placing the 5-bit primary opcode in the most significant bits (`[31:27]`) allows the EE R5900 core to extract the opcode with a single logical shift right (`srl $t0, $instr, 27`), filling the upper 27 bits with zeros and eliminating `andi` mask instructions.
- **Cache-Locked 32-Entry Primary Dispatch**: The 32-entry function pointer dispatch table occupies exactly **128 bytes** ($32 \times 4\text{ bytes}$), locking completely into **2 L1 D-Cache lines** (64 bytes each) on the Emotion Engine. This guarantees zero RDRAM cache misses during primary instruction dispatch.
- **Zero Register Spill**: Citrine preserves a flat 256 virtual registers (`$r0`..`$r255`, 16-byte QWORD aligned each) per execution frame. SPRAM (16 KB @ `0x70000000`) houses up to 4 simultaneous active call frames with zero bus contention.
- **Peephole Instruction Fusions**:
  - Compare-and-Branch (`OP_BRANCH_CMP`): Eliminates condition flag registers and redundant branches.
  - Loop Decrement & Branch (`OP_LOOP_DEC_BR`): Combines counter decrement and loop condition evaluation into 1 cycle.
  - Fused Multiply-Accumulate (`OP_FUSED_MADD`): Accelerates 2D vector dot products and matrix transformations.

---

## 2. Container Binary Format (`CBC2`)

Citrine compiled bytecode files (`.cbc`) are binary containers structured in four sequential sections:

```text
+-------------------------------------------------------+
| File Header (18 bytes)                                |
+-------------------------------------------------------+
| String Pool (Length-prefixed UTF-8 strings)           |
+-------------------------------------------------------+
| Constant Pool (Tagged Values: Int, Float, Vec2, Color)|
+-------------------------------------------------------+
| Function Symbol Table (Signatures, Arity, PC Offsets) |
+-------------------------------------------------------+
| Instruction Stream (32-bit Citrine-32 Words)          |
+-------------------------------------------------------+
```

### 2.1 Header Structure (18 bytes)

| Offset | Type | Field | Description |
|---|---|---|---|
| `0x00` | `char[4]` | `magic` | Identifier: `CBC2` (`0x43`, `0x42`, `0x43`, `0x32`) |
| `0x04` | `uint16` | `version` | Bytecode version (`2`) |
| `0x06` | `uint32` | `num_functions` | Total count of functions in symbol table |
| `0x0A` | `uint32` | `num_constants` | Total count of constant pool entries |
| `0x0E` | `uint32` | `num_strings` | Total count of string pool entries |

All multi-byte numeric values are stored in **Little-Endian** byte order.

---

## 3. Instruction Word Encodings (32-bit)

Every instruction occupies exactly 4 bytes (32 bits).

```text
 31     27 26   24 23       16 15        8 7         0
+---------+-------+-----------+-----------+-----------+
| Primary | SubOp |  Dst Reg  |   Reg A   |   Reg B   |  Format ABC
+---------+-------+-----------+-----------+-----------+
| Primary | SubOp |  Dst Reg  |    Immediate UInt16   |  Format AB_IMM / BRANCH_Z
+---------+-------+-----------+-----------------------+
| Primary | SubOp |  Dst Reg  |   Reg A   |  Offset8  |  Format BRANCH_CMP
+---------+-------+-----------+-----------+-----------+
| Primary | SubOp |         Signed 24-bit Offset      |  Format JUMP24
+---------+-------+-----------------------------------+
```

### 3.1 Field Breakdown
- **Primary Opcode (`[31:27]`, 5 bits)**: Primary instruction category (`0x00` through `0x1F`).
- **Sub-Opcode (`[26:24]`, 3 bits)**: Sub-operation variant (`0` through `7`).
- **Dst / Cond Register (`[23:16]`, 8 bits)**: Target or test virtual register (`$r0`..`$r255`).
- **Source Reg A (`[15:8]`, 8 bits)**: First source operand register (`$r0`..`$r255`).
- **Source Reg B / Offset8 (`[7:0]`, 8 bits)**: Second source register or signed 8-bit branch offset.
- **Immediate UInt16 (`[15:0]`, 16 bits)**: Signed/unsigned immediate or constant pool index.
- **Jump Offset24 (`[23:0]`, 24 bits)**: Signed 24-bit relative PC jump offset ($\pm 8\text{M}$ instructions / 32 MB reach).

---

## 4. The 32 Primary Opcodes & Sub-Opcode Matrix

| Primary Opcode | Hex | Sub-Opcodes (`0..7`) | Description |
|---|---|---|---|
| `OP_SYS` | `0x00` | `0:NOP`, `1:HALT`, `2:BREAK`, `3:SYNC`, `4:FLUSH_I`, `5:FLUSH_D`, `6:WD_RESET`, `7:PROF_MARK` | System control, VM termination, hardware sync, profiling |
| `OP_MOVE` | `0x01` | `0:MOVE32`, `1:MOVE64`, `2:MOVE128`, `3:CMOVZ`, `4:CMOVN`, `5:SWAP` | Register copy, wide SIMD transfer, conditional moves, swap |
| `OP_LOAD_CONST` | `0x02` | `0..7`: Constant type tag | Load pre-compiled constant from `.cbc` pool at index `imm16` |
| `OP_LOAD_IMM` | `0x03` | `0:NIL`, `1:BOOL`, `2:INT16`, `3:UINT16`, `4:UPPER16`, `5:ZERO`, `6:MINUS1` | Load immediate constant directly into register |
| `OP_LOAD_MEM` | `0x04` | `0:LB`, `1:LBU`, `2:LH`, `3:LHU`, `4:LW`, `5:LWC1`, `6:LD`, `7:LQ` | Load byte/half/word/float/quad from address `R[a] + imm8` |
| `OP_STORE_MEM` | `0x05` | `0:SB`, `1:SH`, `2:SW`, `3:SWC1`, `4:SD`, `5:SQ` | Store byte/half/word/float/quad to address `R[a] + imm8` |
| `OP_ADD` | `0x06` | `0:I32`, `1:U32`, `2:SAT`, `3:STR_CONCAT`, `4:IMM8` | Integer addition, saturating add, string concat, add immediate |
| `OP_SUB` | `0x07` | `0:I32`, `1:U32`, `2:SAT`, `3:NEG`, `4:IMM8` | Integer subtraction, negation, sub immediate |
| `OP_MUL` | `0x08` | `0:LO`, `1:HI`, `2:UHI`, `3:SAT`, `4:IMM8` | Integer multiplication, high product, multiply immediate |
| `OP_DIV_MOD` | `0x09` | `0:DIV_S32`, `1:MOD_S32`, `2:DIV_U32`, `3:MOD_U32` | Signed & unsigned division and modulo (zero guarded) |
| `OP_BITWISE` | `0x0A` | `0:AND`, `1:OR`, `2:XOR`, `3:NOR`, `4:AND_NOT`, `5:XNOR` | Bitwise logical operations |
| `OP_SHIFT` | `0x0B` | `0:SLL`, `1:SRL`, `2:SRA`, `3:ROTL`, `4:ROTR`, `5:CLZ` | Logical/arithmetic bit shifts, rotates, count leading zeros |
| `OP_COMPARE` | `0x0C` | `0:EQ`, `1:NE`, `2:LT`, `3:LE`, `4:GT`, `5:GE`, `6:STR_EQ`, `7:PTR_EQ` | Register relational comparisons, string equality, pointer equality |
| `OP_TEST` | `0x0D` | `0:NIL`, `1:NOT_NIL`, `2:ZERO`, `3:NOT_ZERO`, `4:TRUTHY`, `5:FALSY`, `6:TAG`, `7:BIT` | Fast boolean and type tests without branch |
| `OP_FLOAT_ALU` | `0x0E` | `0:ADD`, `1:SUB`, `2:MUL`, `3:DIV`, `4:NEG`, `5:ABS`, `6:SQRT`, `7:CVT` | Single-precision IEEE-754 floating point arithmetic |
| `OP_JUMP` | `0x0F` | `0:REL24`, `1:REL16`, `2:REG`, `3:TABLE` | Unconditional relative jump ($\pm 8\text{M}$ reach), indirect jump, switch |
| `OP_BRANCH_Z` | `0x10` | `0:TRUTHY`, `1:FALSY`, `2:ZERO`, `3:NONZERO`, `4:POS`, `5:NEG` | Conditional branch based on register zero/truthiness |
| `OP_BRANCH_CMP` | `0x11` | `0:BEQ`, `1:BNE`, `2:BLT`, `3:BLE`, `4:BGT`, `5:BGE` | **Fused Compare-and-Branch**: compare `R[dst]` and `R[a]`, branch `offset8` |
| `OP_CALL` | `0x12` | `0:DIRECT`, `1:INDIRECT`, `2:TAIL_DIRECT`, `3:TAIL_INDIRECT` | Function invocation, tail call elimination |
| `OP_RETURN` | `0x13` | `0:VAL`, `1:NIL`, `2:VOID`, `3:MULTI` | Return value from function frame |
| `OP_CALL_NATIVE`| `0x14` | `0:KERNEL`, `1:GS`, `2:AUDIO`, `3:PAD`, `4:VIDEO`, `5:HUD`, `6:IO`, `7:USER` | Domain-partitioned native hardware trampoline |
| `OP_VEC2_MATH` | `0x15` | `0:NEW`, `1:ADD`, `2:SUB`, `3:MUL`, `4:DIV`, `5:SCALE`, `6:DOT`, `7:CROSS` | Vector2 constructor, arithmetic, dot product, cross product |
| `OP_VEC2_PROP` | `0x16` | `0:GET_X`, `1:GET_Y`, `2:SET_X`, `3:SET_Y`, `4:LEN`, `5:LENSQ`, `6:NORM`, `7:LERP` | Vector2 member access, magnitude, normalization, lerp |
| `OP_COLOR_OP` | `0x17` | `0:RGBA32`, `1:RGBA16`, `2:UNPACK`, `3:LERP`, `4:MODULATE`, `5:PREMUL` | Packed RGBA color constructors, blending, modulation |
| `OP_SIMD_MMI` | `0x18` | `0:PADDB`, `1:PADDW`, `2:PSUBW`, `3:PMULTH`, `4:PMAXW`, `5:PMINW`, `6:PEXTW`, `7:PPACW` | Emotion Engine MMI 128-bit SIMD vector instructions |
| `OP_COLLECTION` | `0x19` | `0:AGET`, `1:ASET`, `2:ALEN`, `3:APUSH`, `4:APOP`, `5:FGET`, `6:FSET`, `7:HGET` | Array indexing, push/pop, struct field access, hash table lookup |
| `OP_FIBER_OP` | `0x1A` | `0:SPAWN`, `1:YIELD`, `2:RESUME`, `3:STATUS`, `4:KILL`, `5:ID`, `6:SLEEP` | Cooperative fiber lifecycle management and scheduling |
| `OP_CHANNEL_OP` | `0x1B` | `0:CREATE`, `1:SEND`, `2:RECV`, `3:TRY_RECV`, `4:COUNT`, `5:CAP`, `6:CLOSE` | CSP synchronization channel ring buffer operations |
| `OP_PS2_HW` | `0x1C` | `0:GIF`, `1:VIF1`, `2:WAIT`, `3:VSYNC`, `4:SWAP`, `5:KEYON`, `6:PAD` | PS2 hardware registers: DMA GIF packet, VSync, VRAM flip |
| `OP_INLINE_ASM` | `0x1D` | `0:MFC0`, `1:MTC0`, `2:VU0`, `3:SPRAM`, `4:PERF_START`, `5:PERF_STOP` | Emotion Engine privileged COP0/COP2 registers and timers |
| `OP_LOOP_DEC_BR`| `0x1E` | `0:DECBR_NZ`, `1:DECBR_GEZ`, `2:INCBR_LT` | **Fused Loop Decrement/Increment & Branch**: counter step and branch |
| `OP_FUSED_MADD` | `0x1F` | `0:MADD_I32`, `1:MSUB_I32`, `2:MADD_F32`, `3:MSUB_F32`, `4:DOT_VEC2` | **Fused Multiply-Accumulate**: `R[dst] = R[dst] +/- (R[a] * R[b])` |

---

## 5. Domain-Partitioned Native Services (`OP_CALL_NATIVE`)

In Citrine-32, `OP_CALL_NATIVE` (`0x14`) uses its 3-bit sub-opcode to partition hardware calls into **8 dedicated functional domains**, allowing hardware-level dispatch filtering:

- **Domain 0 (`SUBOP_NAT_KERNEL`)**: `InitWindow` (1), `CloseWindow` (2), `WindowOpen` (3), `SetTargetFPS` (4), `GetFPS` (5), `GetDeltaTime` (6), `Sleep` (65), `Panic` (99).
- **Domain 1 (`SUBOP_NAT_GS`)**: `BeginDrawing` (10), `EndDrawing` (11), `ClearBackground` (12), `DrawRectangle` (20), `DrawCircle` (21), `DrawLine` (22), `DrawTriangle` (23), `DrawText` (24), `DrawCube` (27), `DrawMesh` (34), `Citrine GL` (101..111).
- **Domain 2 (`SUBOP_NAT_AUDIO`)**: `LoadSound` (35), `PlaySound` (36), `StopSound` (37), `CD-DA Audio` (220..225).
- **Domain 3 (`SUBOP_NAT_PAD`)**: `ButtonDown` (40), `ButtonPressed` (41), `ButtonReleased` (42), `GetAnalog` (43), `SetRumble` (44).
- **Domain 4 (`SUBOP_NAT_VIDEO`)**: `LoadVideo` (90), `PlayVideo` (91), `DrawVideoFrame` (92), `VideoFinished` (93), `PauseVideo` (94), `StopVideo` (95).
- **Domain 5 (`SUBOP_NAT_HUD`)**: `DrawStats` (60), `Log` (70), `SetLogLevel` (71).
- **Domain 6 (`SUBOP_NAT_IO`)**: Arrays (120..133), MemoryIO (140..148), Heap Objects & Fields (150..152).
- **Domain 7 (`SUBOP_NAT_USER`)**: User C FFI callbacks and Coprocessor hooks (210..219).

---

## 6. Memory Architecture & Scratchpad RAM (SPRAM)

```text
0x00000000 - 0x000FFFFF: PS2 EE Kernel / Bios (1 MB)
0x00100000 - 0x001FFFFF: Citrine ELF .text & .rodata (ROM executable)
0x00200000 - 0x003FFFFF: Citrine Static Buffers & Display Lists
0x00400000 - 0x0043FFFF: Tier 1 Scratch Pool (256 KB, rewound every V-Blank)
0x00440000 - 0x01FFFFFF: Tier 2 Context Arenas & Tier 3 Explicit Heap
0x70000000 - 0x70003FFF: 16 KB On-Chip Scratchpad RAM (SPRAM)
  - 0x70000000: Canary Sentinel (0xDEADBEEF)
  - 0x70000004: Frame Counter & Timers
  - 0x70000010: SIO2 Controller State Buffers
  - 0x70000040: Active Call Frame Virtual Registers ($r0..$r255, 4 KB per frame)
```
