---
name: ps2-dev
description: Specialist knowledge for PlayStation 2 development, Emotion Engine (EE MIPS R5900), Graphics Synthesizer (GS), GIF packets, DMA channels, privileged registers, assembly encoding, and hardware constraints. Use when writing, debugging, or generating PS2 machine code, GIF packets, GS display/draw registers, or Citrine PS2 runtime architecture.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: embedded-systems
  triggers: PS2, PlayStation 2, Emotion Engine, R5900, Graphics Synthesizer, GS, GIF, GIFTag, DMA, GS_PMODE, DISPFB, DISPLAY, Citrine ELF, MIPS, VU0, VU1, VIF, XGKICK, MMI, PADDB, PMULLW, SPU2, CLUT, LODK
  role: specialist
  scope: implementation
  output-format: code
  related-skills: pcsx2-cli, r2-ps2-debug, citrine-vm, citrine-memory, cpp-pro
---

# PlayStation 2 Development Specialist

Expert guide for low-level PlayStation 2 (PS2) development, targeting the Emotion Engine (EE R5900 128-bit MIPS CPU), Graphics Synthesizer (GS GPU), Graphics Interface (GIF), Direct Memory Access Controller (DMAC), Vector Units (VU0 & VU1), Sound Processing Unit 2 (SPU2), and Scratchpad RAM (SPRAM).

## Core Architecture Overview

```text
+--------------------------------------------------------------------------+
|                       Emotion Engine (EE) Core                          |
|  - MIPS R5900 (294.912 MHz, 64-bit GPRs with 128-bit SIMD multimedia)   |
|  - 32 MB Main RAM (0x00000000 - 0x01FFFFFF)                              |
|  - 16 KB Scratchpad RAM / SPRAM (0x70000000 - 0x70003FFF)                |
|  - COP0 (System Control), COP1 (FPU), COP2 (VU0 Macro Mode)              |
+--------------------------------------------------------------------------+
                                     |
                                  Internal Data Bus
                                     |
+----------------------+   +-----------------------+   +-------------------+
|     DMAC (10 ch)     |-->|   GIF (Channel 2)     |-->| GS (Graphics Sys) |
| Ch0: VIF0  Ch5: SIF0 |   | Path 1: VU1 (XGkick)  |   | 4 MB Embedded     |
| Ch1: VIF1  Ch6: SIF1 |   | Path 2: VIF1          |   | DRAM (eDRAM)      |
| Ch2: GIF   Ch7: SIF2 |   | Path 3: EE DMA / FIFO |   | 16 Pixel Pipelines|
| Ch3: fromIPU Ch8: fromSPR|                       |   | PCRTC Controller  |
| Ch4: toIPU   Ch9: toSPR  |                       |   | Read Circuits 1&2 |
+----------------------+   +-----------------------+   +-------------------+
```

## Quick Reference: Memory Segments

| Address Range | Segment | Description |
|:---|:---|:---|
| `0x00000000 - 0x01FFFFFF` | `KUSEG` | 32 MB Main RAM (cached or TLB mapped) |
| `0x20000000 - 0x21FFFFFF` | `KUSEG uncached` | Uncached mirror of Main RAM |
| `0x30000000 - 0x31FFFFFF` | `KUSEG uncached accel` | Uncached accelerated mirror (DMA buffers) |
| `0x70000000 - 0x70003FFF` | `SPRAM` | 16 KB Fast Scratchpad RAM (No cache penalty) |
| `0x80000000 - 0x81FFFFFF` | `KSEG0` | Kernel Cached Main RAM mirror |
| `0xA0000000 - 0xA1FFFFFF` | `KSEG1` | Kernel Uncached Main RAM mirror |
| `0x10000000 - 0x1000FFFF` | `Registers` | EE Timers, Interrupt Controller (INTC), DMAC |
| `0x12000000 - 0x12001FFF` | `GS Privileged`| GS Control Registers (PMODE, DISPFB, DISPLAY, CSR) |

---

## Detailed References

Load detailed architectural references based on task:

| Topic | Reference | Content |
|:---|:---|:---|
| PS2 Engineering Doctrine | [hardware-rules-doctrine.md](./references/hardware-rules-doctrine.md) | Real-world hardware contracts, DMA ownership (construction/publication/completion), cache coherency, asset alignment wire format, heap forensics |
| Vector Units (VU0 / VU1) | [vu-microcode.md](./references/vu-microcode.md) | VU0/VU1 microcode, dual-issue upper/lower execution, VIF packets (UNPACK/MPG), XGKICK Path 1, VCL clipping |
| GS Textures & Pipeline | [gs-textures-pipeline.md](./references/gs-textures-pipeline.md) | 4 MB eDRAM layout, PSMCT32/PSMT8 formats, CSM1 32-entry CLUT swizzle algorithm, signed S7.4 LODK calculation, dual GS contexts |
| EE 128-bit MMI Instructions | [ee-mmi-instructions.md](./references/ee-mmi-instructions.md) | R5900 128-bit SIMD multimedia instructions (PADDB/W, PMULLW, PPAC5, PEXT5), quadword LQ/SQ, pipeline latencies |
| SPU2 Audio Hardware | [spu2-hardware.md](./references/spu2-hardware.md) | 48-voice sound core architecture, ADPCM 16-byte block encoding, voice registers, AutoDMA Ch4 streaming, ring buffer wire ABI |
| PS2Tek Full Hardware Internals | [ps2tek-reference.md](./references/ps2tek-reference.md) | Complete PS2 hardware architecture: EE/IOP memory & I/O maps, MIPS R5900 instruction decoding (SPECIAL, MMI, COP0/1/2), TLB & cache coherency, GS registers & render hacks, DMAC 10 channels & chain tags, GIF 3 paths & FIFO, VIF/VU0/VU1 SIMD, IPU decoder, CDVD optical N/S commands, SPU2 AutoDMA, SIO2 DualShock 2 protocol, SIF RPC subsystems, BIOS boot flow, EE syscall table, and core IOP IRX modules |
| SMS Audio Architecture & Streaming | [sms-audio-architecture.md](./references/sms-audio-architecture.md) | Eugene Plotnikov's SMS audio pipeline, `audsrv` sound server, SPU2 double-buffered DMA streaming, SIF RPC, uncached 64-byte alignment, A/V sync |
| GS Registers & Video Modes | [gs-registers.md](./references/gs-registers.md) | PMODE, DISPFB1/2, DISPLAY1/2, FRAME, ZBUF, XYOFFSET, SCISSOR, TEST |
| GIF & DMA Transfers | [gif-dma.md](./references/gif-dma.md) | GIFTag 128-bit layout, PACKED/A+D mode, D2_CHCR, D2_MADR, synchronization |
| EE MIPS Assembly & Syscalls | [ee-mips.md](./references/ee-mips.md) | R5900 instruction encoding, BIOS syscalls (`_SetGsCrt`, `_GsPutIMR`), ELF layout |

---

## Mandatory Constraints & Rules

### MUST DO
- **Initialize Both Read Circuits or Enable Circuit 1**: PCSX2 displays Read Circuit 1 by default. In `GS_PMODE` (`0x12000000`), always set bit 0 (`EN1 = 1`). Write both `DISPFB1` (`0x12000070`) / `DISPLAY1` (`0x12000080`) and `DISPFB2` (`0x12000090`) / `DISPLAY2` (`0x120000A0`).
- **Flush D-Cache Before DMA Transfers**: The CPU writes through the L1 D-Cache, but DMA reads physical RAM directly. Always call `SyncDCache` or use uncached accelerated memory (`0x30000000 | addr`) before writing to `D2_MADR`.
- **Enforce Strict Memory Alignment**: Standard words require 4-byte alignment; quadwords (`LQ`/`SQ`) require 16-byte alignment; DMA bursts and audio ring buffers require 64-byte alignment. Misalignment triggers hardware Address Error Bus exceptions.
- **Swizzle CSM1 8-bit Textures**: When loading 256-color palettes in `CSM1` mode, always apply the 32-entry bit twiddle (`(i & ~0x18) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)`) to avoid corrupted intermediate colors.
- **Insert `WAITQ` Before Reading Q in VU**: Vector Unit `FDIV` takes 7 cycles and `FSQRT` takes 13 cycles. Always issue `WAITQ` in the lower slot before accessing Q.
- **Provide 2 Vertices for SPRITE Primitives**: Primitive type 6 (SPRITE) requires two vertices: vertex 1 (upper-left) and vertex 2 (lower-right). The final vertex kicks rendering via `XYZ2` (`0x05`).

### MUST NOT DO
- **Do NOT enable Read Circuit 2 while disabling Circuit 1**: Setting `PMODE = 0xFF62` disables Circuit 1 (`EN1=0`), producing a solid black display in PCSX2. Use `0xFF65` (`EN1=1, EN2=0`) or `0xFF67` (`EN1=1, EN2=1`).
- **Do NOT omit `EOP` on the final GIFTag**: Bit 15 of the lower 64 bits of the GIFTag is End-Of-Packet (`EOP`). Omitting `EOP=1` causes the GS to wait indefinitely for subsequent tags, locking up the GIF.
- **Do NOT write to `$vf00` in VU**: `$vf00` is hardwired to `(0, 0, 0, 1)`. Writes are silently discarded.
- **Do NOT modify DMA buffers in flight**: Once DMA `STR` bit is set, the CPU must not touch, reallocate, or tear down the buffer until the transfer completes.
- **Do NOT branch into the delay slot**: MIPS has single-cycle branch delay slots. Always follow branches (`j`, `jal`, `bnez`, `beqz`) with a valid instruction or `nop` (`0x00000000`). Never place another branch in a delay slot.
