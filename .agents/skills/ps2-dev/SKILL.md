---
name: ps2-dev
description: Specialist knowledge for PlayStation 2 development, Emotion Engine (EE MIPS R5900), Graphics Synthesizer (GS), GIF packets, DMA channels, privileged registers, assembly encoding, and hardware constraints. Use when writing, debugging, or generating PS2 machine code, GIF packets, GS display/draw registers, or Citrine PS2 runtime architecture.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: embedded-systems
  triggers: PS2, PlayStation 2, Emotion Engine, R5900, Graphics Synthesizer, GS, GIF, GIFTag, DMA, GS_PMODE, DISPFB, DISPLAY, Citrine ELF, MIPS
  role: specialist
  scope: implementation
  output-format: code
  related-skills: pcsx2-cli, r2-ps2-debug, cpp-pro
---

# PlayStation 2 Development Specialist

Expert guide for low-level PlayStation 2 (PS2) development, targeting the Emotion Engine (EE R5900 128-bit MIPS CPU), Graphics Synthesizer (GS GPU), Graphics Interface (GIF), Direct Memory Access Controller (DMAC), and Scratchpad RAM (SPRAM).

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
| GS Registers & Video Modes | [gs-registers.md](./references/gs-registers.md) | PMODE, DISPFB1/2, DISPLAY1/2, FRAME, ZBUF, XYOFFSET, SCISSOR, TEST |
| GIF & DMA Transfers | [gif-dma.md](./references/gif-dma.md) | GIFTag 128-bit layout, PACKED/A+D mode, D2_CHCR, D2_MADR, synchronization |
| EE MIPS Assembly & Syscalls | [ee-mips.md](./references/ee-mips.md) | R5900 instruction encoding, BIOS syscalls (`_SetGsCrt`, `_GsPutIMR`), ELF layout |

---

## Mandatory Constraints & Rules

### MUST DO
- **Initialize Both Read Circuits or Enable Circuit 1**: PCSX2 displays Read Circuit 1 by default. In `GS_PMODE` (`0x12000000`), always set bit 0 (`EN1 = 1`). Write both `DISPFB1` (`0x12000070`) / `DISPLAY1` (`0x12000080`) and `DISPFB2` (`0x12000090`) / `DISPLAY2` (`0x120000A0`).
- **Use 64-bit Stores for GS Privileged Registers**: Always use `sd` (Store Doubleword) to write 64-bit values to `0x12000000 - 0x12001080`.
- **Set Up Uncached DMA Addresses or Flush D-Cache**: Before initiating GIF DMA (Channel 2), write physical memory addresses or KSEG1 (`0xA0000000 | addr`) / Uncached Accel (`0x30000000 | addr`) into `D2_MADR` (`0x1000A010`).
- **Wait on DMA Channel 2 Completion**: Check bit 8 of `D2_CHCR` (`0x1000A000`). If non-zero, DMA is still running; spin-wait or check `D_STAT` before writing new packets.
- **Provide 2 Vertices for SPRITE Primitives**: Primitive type 6 (SPRITE) requires two vertices: vertex 1 (upper-left) and vertex 2 (lower-right). The final vertex kicks rendering via `XYZ2` (`0x05`).

### MUST NOT DO
- **Do NOT enable Read Circuit 2 while disabling Circuit 1**: Setting `PMODE = 0xFF62` disables Circuit 1 (`EN1=0`), producing a solid black display in PCSX2. Use `0xFF65` (`EN1=1, EN2=0`) or `0xFF67` (`EN1=1, EN2=1`).
- **Do NOT omit `EOP` on the final GIFTag**: Bit 15 of the lower 64 bits of the GIFTag is End-Of-Packet (`EOP`). Omitting `EOP=1` causes the GS to wait indefinitely for subsequent tags, locking up the GIF.
- **Do NOT miscalculate NLOOP in GIFTag**: In PACKED A+D mode (`NREG=1, REGS=0x0E`), each quadword is 1 loop. `NLOOP` must exactly match the number of A+D quadwords (max 32767).
- **Do NOT branch into the delay slot**: MIPS has single-cycle branch delay slots. Always follow branches (`j`, `jal`, `bnez`, `beqz`) with a valid instruction or `nop` (`0x00000000`).
