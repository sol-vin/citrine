# PlayStation 2 Vector Unit (VU0 / VU1) Microcode & Pipeline Guide

Comprehensive reference for programming the PS2 Vector Units (VU0 and VU1), VIF packet formatting, dual-issue VPU execution, and GIF Path 1 rendering transfers.

---

## 1. VU0 vs VU1 Architectural Comparison

| Feature | VU0 (EE Coprocessor 2) | VU1 (Graphics Coprocessor) |
|:---|:---|:---|
| **Primary Role** | Physics, IK, matrix calculations, clipping | Geometry transform, lighting, clipping, raster kick |
| **Micro-Memory (Code)**| 4 KB (512 64-bit microinstructions) | 16 KB (2,048 64-bit microinstructions) |
| **Data Memory (VU Mem)**| 4 KB (256 128-bit quadwords) | 16 KB (1,024 128-bit quadwords) |
| **Operational Modes** | **Macro Mode** (driven by EE COP2 instructions) & **Micro Mode** | **Micro Mode only** (executes independent microprograms) |
| **Input Interface** | EE Core Bus & VIF0 (DMA Channel 0) | VIF1 (DMA Channel 1) |
| **Output Interface** | EE Core & scratchpad | **GIF Path 1 via `XGKICK` instruction** |
| **Special HW E-Units**| Elementary function unit (sin, cos, atan, exp) | Elementary function unit + Direct GIF bus |

---

## 2. Register Architecture

Each Vector Unit features two orthogonal register files:

### Floating-Point Vector Registers (`$vf00` - `$vf31`)
- 32 × 128-bit floating point registers, each containing four 32-bit single-precision IEEE 754 float fields: `(x, y, z, w)`.
- **Special Register `$vf00`**: Hardwired constant register:
  - `$vf00.x = 0.0f`
  - `$vf00.y = 0.0f`
  - `$vf00.z = 0.0f`
  - `$vf00.w = 1.0f`
  - Writing to `$vf00` is discarded. Used constantly as the homogeneous coordinate component `w=1.0` and zero source.

### Integer Control Registers (`$vi00` - `$vi15`)
- 16 × 16-bit integer registers used for loop counters, memory indexing, pointer offsets, and jump targets.
- **Special Register `$vi00`**: Hardwired constant `0`. Writes are ignored.
- **Register `$vi15` (Convention)**: Often held as base pointer or XGKICK transfer pointer.

### Status and Control Registers
- **MAC Flag Register**: Accumulator saturation, underflow, overflow, and sign flags.
- **Clipping Flag Register**: 6-bit frustum boundary flags (`+X, -X, +Y, -Y, +Z, -Z`) set by the `CLIP` instruction.
- **Status Flag Register**: Zero, sign, carry, and overflow flags for integer ops.
- **Q Register**: Holds the quotient result from `FDIV` or square root from `FSQRT` (latency: 7 cycles for div, 13 cycles for sqrt).
- **P Register**: Holds output from elementary math functions (`EEXP`, `ESIN`, `ERCPR`, etc.).

---

## 3. Dual-Issue Instruction Format (64-bit Word)

Every 64-bit VPU microinstruction executes **two independent instructions in parallel** in a single clock cycle:

```text
 63                                32 31                                 0
+------------------------------------+------------------------------------+
|          Upper Instruction         |          Lower Instruction         |
|   (Vector Floating-Point Math)     |     (Integer, Branch, Load/Store)  |
+------------------------------------+------------------------------------+
```

### Upper Execution Unit (Vector Float)
Operates on `$vf` registers across selected destination broadcast lanes (`x, y, z, w`).
- **Basic Arithmetic**: `FADD`, `FSUB`, `FMUL`, `FMADD`, `FMSUB`, `FNMADD`, `FNMSUB`
- **Extremum & Comparison**: `MAX`, `MIN`, `CLIP` (frustum clip test)
- **Outer Product / Matrix Ops**: `OPMULA`, `OPMSUB`
- **Format Conversion**: `FTOD` (float to fixed-point integer), `DTOF` (fixed to float)
- **Divide / Sqrt**: `FDIV Q, vf01.x, vf02.y`, `FSQRT Q, vf01.x`

### Lower Execution Unit (Integer & Control)
Operates on `$vi` registers, memory transfers, and hardware coordination.
- **Integer Math**: `IADD`, `IADDI`, `ISUB`, `IAND`, `IOR`, `INOR`, `IXOR`
- **Memory Load/Store**: `ILW`, `ISW` (integer), `LQ`, `SQ` (128-bit quadword), `LQD`, `SQD` (auto-decrement)
- **Branching**: `BAL vi15, label` (Branch and link), `JR vi15` (Jump register), `B label` (Branch relative)
- **Pipeline Sync**: `WAITQ` (stall until Q quotient is ready), `WAITP` (wait on P unit)
- **Hardware Trigger**: `XGKICK vi_addr` (kick rendering packet from VU Mem to GS)

```assembly
; Example dual-issue syntax:
; [Upper Instruction]               | [Lower Instruction]
FMADD.xyzw vf04, vf01, vf02, vf03   | LQ.xyzw vf05, 1(vi02)
WAITQ                               | IADDI vi02, vi02, 1
FMULq.xyz vf06, vf04, Q             | SQ.xyzw vf06, 0(vi03)
NOP                                 | XGKICK vi03
```

---

## 4. VIF Packet Protocol & Data Loading

The Vector Interface (VIF) unpacks DMA streams into VU local memory.

### Key VIF Commands
- `UNPACK`: Transfers and decompresses data into VU Data Memory (`0x0000 - 0x3FFF`):
  - Format options: `S-32`, `S-16`, `S-8`, `V2-32`, `V2-16`, `V3-32`, `V4-32`, `V4-16`, `V4-8`
  - Supports automatic sign/zero-extension and masking.
- `MPG`: Loads microcode words directly into VU Micro-Memory (`0x0000 - 0x3FFF`).
- `MSCAL / MSCNT`: Initiates microcode execution at a specified program counter address.
- `FLUSHE / FLUSH / FLUSHA`: Waits for the VU microprogram and/or GIF to finish executing before resuming DMA stream.
- `DIRECT`: Forwards following quadwords directly through GIF Path 2 to the GS.

### Double-Buffering Protocol (VU Mem1)
To achieve zero-stall geometry throughput, divide VU1's 16 KB data memory into two 8 KB ping-pong buffers:

```text
VU1 Data Memory (16 KB / 1024 Quadwords)
+-----------------------------------------------------------+
| Buffer 0 (0x0000 - 0x01FF, 512 QW) : Transformed by VU1   |
+-----------------------------------------------------------+
| Buffer 1 (0x0200 - 0x03FF, 512 QW) : Loaded via VIF1 DMA  |
+-----------------------------------------------------------+
```
1. VIF1 unpacks vertex batch into Buffer 1.
2. Microprogram transforms Buffer 0 and issues `XGKICK` to GS.
3. Microprogram calls `XTOP vi01` to obtain the base address of the next buffer, swapping Buffer 0 and Buffer 1 seamlessly.

---

## 5. Frustum Clipping & The VCL Pipeline

Clipping vertices on the Emotion Engine CPU wastes critical clock cycles. The standard PS2 pipeline delegates geometric clipping to VU1:

1. **Clip Flag Generation**:
   ```assembly
   CLIP.xyz vf01, vf02   ; Test transformed vertex vf01 against w-boundary vf02
   ```
   This sets the 6-bit hardware clip flags in the VU Clipping Register.
2. **Batch Triage**:
   - If no clip flags are set for all 3 vertices of a triangle, pass directly to `XGKICK`.
   - If all 3 vertices fail the same plane (e.g. all `-Z`), trivially reject the primitive.
   - If triangle intersects the frustum boundary, execute software polygon clipping (Sutherland-Hodgman) within VU1 microcode to generate new interpolated vertices.
3. **Lessons Learned (Handbook Ch. 22)**:
   - **Output cap is an input contract**: Never allow polygon clipping to spill beyond the allocated output buffer in VU Mem. Set strict input vertex caps per batch (typically 32 to 64 vertices max).
   - **Preserve batch integrity**: If clipped geometry overflows the active buffer, spill within VU1 memory or commit the unclipped prefix first rather than aborting.

---

## 6. Mandatory Constraints & Hardware Rules

### MUST DO
- **Precede `XGKICK` with Valid GIFTag**: The data pointed to by `vi_addr` in `XGKICK vi_addr` MUST start with a valid 128-bit `GIFTag`.
- **Insert `WAITQ` Before Using Q**: `FDIV` requires 7 cycles and `FSQRT` requires 13 cycles. Always issue `WAITQ` in the lower unit before reading the Q register with `FMULq` or `FADDq`.
- **Align Microcode Jumps**: Branch targets in VU microcode (`B`, `BAL`, `JR`) must target valid 64-bit aligned instructions. Branches have a 1-instruction branch delay slot.
- **Clear Upper Bits on Scratchpad/VU Pointers**: When copying buffers from EE to VU, ensure quadword alignment (16-byte aligned addresses).

### MUST NOT DO
- **Do NOT execute `XGKICK` while GIF Path 1 is busy**: Check that previous Path 1 transfer is complete or manage double-buffered kick synchronizations to prevent GS FIFO stalls.
- **Do NOT write to `$vf00`**: `$vf00` is read-only constant `(0, 0, 0, 1)`. Writes will not produce errors but will silently drop values.
- **Do NOT read register immediately written in pipeline hazard**: Upper unit multiply-add operations have 4-cycle latency; reading the result on cycle 1 causes a hardware stall. Interleave independent operations.
