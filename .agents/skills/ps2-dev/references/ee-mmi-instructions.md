# Emotion Engine (EE MIPS R5900) 128-bit MMI & Core Instruction Reference

Technical reference for the Emotion Engine (EE) CPU 128-bit Multimedia Instructions (MMI), quadword load/stores, pipeline latency, and register file organization.

---

## 1. EE Register File Architecture (128-bit Quadwords)

The Emotion Engine Core contains 32 General-Purpose Registers (`$0` to `$31`), each widened to **128 bits** (1 quadword).

```text
127                             96 95                              64 63                              32 31                               0
+---------------------------------+---------------------------------+---------------------------------+---------------------------------+
|          Word 3 (Bits 96..127)  |          Word 2 (Bits 64..95)   |          Word 1 (Bits 32..63)   |          Word 0 (Bits 0..31)    |
+---------------------------------+---------------------------------+---------------------------------+---------------------------------+
| Half 7 | Half 6 | Half 5 | Half 4 | Half 3 | Half 2 | Half 1 | Half 0 |
| Byte15 | Byte14 | Byte13 | Byte12 | Byte11 | Byte10 | Byte9  | Byte8  | Byte7  | Byte6  | Byte5  | Byte4  | Byte3  | Byte2  | Byte1  | Byte0  |
```

- Standard MIPS I/II/III instructions operate on the lower 32 or 64 bits.
- MMI instructions operate in parallel across all 4 words, 8 halfwords, or 16 bytes simultaneously in a single clock cycle!

---

## 2. 128-bit Load & Store Instructions

| Mnemonic | Operands | Operation | Constraint |
|:---|:---|:---|:---|
| `LQ` | `$rt, offset($base)` | Loads 128 bits into `$rt` from memory | **Must be 16-byte aligned** (lower 4 bits zero) |
| `SQ` | `$rt, offset($base)` | Stores 128 bits from `$rt` into memory | **Must be 16-byte aligned** (lower 4 bits zero) |
| `LQC2`| `$vt, offset($base)` | Loads 128 bits into COP2 (VU0) vector reg | Must be 16-byte aligned |
| `SQC2`| `$vt, offset($base)` | Stores 128 bits from COP2 vector reg | Must be 16-byte aligned |

> [!CAUTION]
> Misaligned `LQ` or `SQ` instructions cause an **Address Error Exception** on real hardware. Unaligned accesses must be read using standard word loads (`LWL`/`LWR`) or aligned buffers.

---

## 3. Parallel Arithmetic Instructions (MMI)

### Parallel Add & Subtract
- **Byte (16 elements in parallel)**:
  - `PADDB $rd, $rs, $rt`: Parallel add 16 × 8-bit bytes (wraparound modulo 256).
  - `PADDSB $rd, $rs, $rt`: Parallel signed saturate add 16 × 8-bit bytes (clamps between -128 and 127).
  - `PADDUSB $rd, $rs, $rt`: Parallel unsigned saturate add 16 × 8-bit bytes (clamps between 0 and 255). Perfect for pixel blending!
  - `PSUBB / PSUBSB / PSUBUSB`: Parallel subtract bytes.
- **Halfword (8 elements in parallel)**:
  - `PADDH`, `PADDSH`, `PADDUSH` (clamps 0..65535)
  - `PSUBH`, `PSUBSH`, `PSUBUSH`
- **Word (4 elements in parallel)**:
  - `PADDW`: Parallel add 4 × 32-bit words (32-bit integers, vectors).
  - `PADDSW`, `PADDUSW`: Saturating word additions.
  - `PSUBW`, `PSUBSW`, `PSUBUSW`: Parallel subtract words.

### Parallel Multiply & Multiply-Add
- `PMULTH $rd, $rs, $rt`: Multiplies 8 × 16-bit halfwords, storing 32-bit products in accumulator registers (`$LO` and `$HI`).
- `PMULLW $rd, $rs, $rt`: Multiplies 4 × 32-bit words, returning the lower 32-bit products in `$rd`.
- `PMADDW / PMSUBW`: Parallel multiply and add/subtract into 128-bit accumulators.

---

## 4. Parallel Min, Max & Comparisons

Execute 4 or 8 parallel tests in a single instruction without branching:

- `PMAXW $rd, $rs, $rt`: $rd_i = \max(rs_i, rt_i)$ for $i \in [0..3]$ (signed 32-bit words).
- `PMINW $rd, $rs, $rt`: $rd_i = \min(rs_i, rt_i)$ for $i \in [0..3]$.
- `PMAXH / PMINH`: Parallel min/max for 8 × 16-bit signed halfwords.
- `PCGTW $rd, $rs, $rt`: Parallel compare greater than. Sets $rd_i = \text{0xFFFFFFFF}$ if $rs_i > rt_i$, else 0.
- `PCEQW $rd, $rs, $rt`: Parallel compare equal. Sets $rd_i = \text{0xFFFFFFFF}$ if $rs_i == rt_i$, else 0.
- `PCGTB / PCEQB`: Parallel greater than and equal for 16 × 8-bit bytes.

---

## 5. Parallel Packing, Unpacking & Formatting

Essential for color space conversion, texture pixel packing, and SIMD lane shuffling:

### Color Conversion: `PPAC5` and `PEXT5`
- `PPAC5 $rd, $rt`: Packs 4 × 32-bit RGBA components into two 16-bit `RGBA 5:5:5:1` words!
  - Takes bits [15:11] of each word and concatenates them into a 16-bit PS2 16-bit frame/texture format.
- `PEXT5 $rd, $rt`: Unpacks 16-bit `5:5:5:1` pixel format into expanded 32-bit words.

### General Interleaving & Permutations
- `PPACW $rd, $rs, $rt`: Packs alternating 32-bit words from `$rs` and `$rt` into 16-bit halfwords.
- `PEXTW $rd, $rs, $rt`: Interleaves the lower words of `$rs` and `$rt` into expanded 64-bit lanes.
- `PEXTH $rd, $rs, $rt`: Interleaves halfwords from `$rs` and `$rt`.
- `PINTH $rd, $rs, $rt`: Interleaves upper and lower halfwords.
- `PLZCW $rd, $rs`: Parallel leading zero count for 32-bit words (vital for fast normalization and floating point math).

---

## 6. Pipeline Timings & Branch Delay Slot Discipline

| Instruction Group | Issue Rate | Latency | Result Unit |
|:---|:---|:---|:---|
| Basic ALU (`ADDU`, `SUBU`, `AND`, `OR`) | 1 cycle | 1 cycle | ALU 0 / ALU 1 |
| MMI Add/Sub (`PADDW`, `PADDB`, `PMAXW`) | 1 cycle | 2 cycles | Multimedia Unit |
| MMI Multiply (`PMULLW`) | 1 cycle | 3 cycles | Multimedia Multiplier |
| Memory Load (`LQ`, `LW`) | 1 cycle | 3 cycles | Load/Store Unit |
| Branch (`BEQ`, `BNE`, `BGTZ`, `JAL`) | 1 cycle | 2 cycles (delay slot)| Jump / Branch Unit |

### Branch Delay Slot Rule
MIPS R5900 utilizes single-cycle branch delay slots:
```assembly
    bne $t0, $zero, .target_label
    nop                         ; Always fill delay slot with a valid instruction or NOP
```
> [!CAUTION]
> Never place a branch (`bne`, `beq`, `j`, `jal`) or a privileged instruction in the branch delay slot of another branch. This generates undefined CPU behavior and hardware panics.
