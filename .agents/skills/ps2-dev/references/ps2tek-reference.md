# PS2Tek Complete Hardware Internals Reference

Comprehensive hardware specification extracted from ps2tek (psi-rockin) covering the PlayStation 2 Emotion Engine (EE R5900), System Coprocessor (COP0), Floating-Point Unit (COP1), Vector Unit 0 Macro Mode (COP2), Graphics Interface (GIF), Direct Memory Access Controller (DMAC), Timers, Graphics Synthesizer (GS), Vector Interface (VIF), Vector Units (VU0/VU1), Image Processing Unit (IPU), SPU2 Sound Processing Unit, Input/Output Processor (IOP), Subsystem Interface (SIF), and BIOS / IOP Kernel Modules.

---

## Table of Contents
1. [PS2 System Overview](#1-ps2-system-overview)
2. [Memory Maps](#2-memory-maps)
3. [Complete I/O Register Maps](#3-complete-io-register-maps)
4. [Emotion Engine (EE R5900 Core)](#4-emotion-engine-ee-r5900-core)
   - [Architecture & Registers](#ee-architecture--registers)
   - [Instruction Decoding Tables](#ee-instruction-decoding-tables)
   - [RDRAM Initialization](#ee-rdram-initialization)
   - [COP0 System Control & Exceptions](#ee-cop0-system-control--exceptions)
   - [Memory Management & TLB](#ee-memory-management--tlb)
   - [Cache Architecture & Coherency](#ee-cache-architecture--coherency)
   - [COP0 Timers](#ee-cop0-timers)
   - [COP1 Floating-Point Unit (FPU)](#ee-cop1-floating-point-unit-fpu)
5. [EE Hardware Timers](#5-ee-hardware-timers)
6. [Graphics Interface (GIF)](#6-graphics-interface-gif)
   - [GIF Control Registers & Arbitration](#gif-control-registers--arbitration)
   - [GIFtag Format & Descriptors](#giftag-format--descriptors)
   - [Data Formats (PACKED, REGLIST, IMAGE)](#gif-data-formats)
   - [PATH3 Masking & FIFO Quirks](#gif-path3-masking--fifo-quirks)
7. [DMA Controller (DMAC)](#7-dma-controller-dmac)
   - [Channels & Channel Registers](#dmac-channels--channel-registers)
   - [Global Controls & Arbitration](#dmac-global-controls--arbitration)
   - [Chain Mode & DMAtag Format](#dmac-chain-mode--dmatag-format)
   - [MFIFO Scratchpad Streaming & Interrupts](#dmac-mfifo-scratchpad-streaming--interrupts)
8. [Graphics Synthesizer (GS)](#8-graphics-synthesizer-gs)
   - [Register Maps (Internal & Privileged)](#gs-register-maps)
   - [Drawing Primitives & Vertex Kick](#gs-drawing-primitives--vertex-kick)
   - [Frame & Z-Buffer Masking](#gs-frame--z-buffer-masking)
   - [VRAM Transfers (BITBLTBUF, TRXPOS, HWREG)](#gs-vram-transfers)
   - [Textures, CLUT & Texel Sampling](#gs-textures-clut--texel-sampling)
   - [Fog & Alpha Blending](#gs-fog--alpha-blending)
   - [Pixel Tests (Alpha, Destination Alpha, Depth)](#gs-pixel-tests)
   - [Advanced PS2 Rendering Techniques](#gs-advanced-ps2-rendering-techniques)
9. [Vector Interface (VIF)](#9-vector-interface-vif)
   - [VIF Registers & Command Decoding](#vif-registers--command-decoding)
   - [VIF UNPACK Matrix & Format Variants](#vif-unpack-matrix--format-variants)
10. [Vector Units (VU0 & VU1)](#10-vector-units-vu0--vu1)
    - [Architecture & Register Sets](#vu-architecture--register-sets)
    - [Processor Flags (MAC, Clip, Status Sticky Bits)](#vu-processor-flags)
    - [Dual-Issue Encoding & Pipeline Latencies](#vu-dual-issue-encoding--pipeline-latencies)
11. [Image Processing Unit (IPU)](#11-image-processing-unit-ipu)
12. [EE Interrupt Controller (INTC)](#12-ee-interrupt-controller-intc)
13. [IOP Hardware and Peripherals](#13-iop-hardware-and-peripherals)
    - [CDVD Optical Drive (Ports, N/S Commands, Disc Types)](#cdvd-optical-drive)
    - [Sound Processing Unit 2 (SPU2 & AutoDMA)](#sound-processing-unit-2-spu2--autodma)
    - [Serial Interface (SIO2, Controllers, Memory Cards)](#serial-interface-sio2-controllers-memory-cards)
    - [IOP Interrupts & DMA](#iop-interrupts--dma)
    - [IOP Timers & Console Hooks](#iop-timers--console-hooks)
14. [Subsystem Interface (SIF)](#14-subsystem-interface-sif)
    - [Hardware Registers & Mailboxes](#sif-hardware-registers--mailboxes)
    - [SIF RPC Architecture & Packet Protocol](#sif-rpc-architecture--packet-protocol)
    - [Standard System Servers](#sif-standard-system-servers)
15. [BIOS & Operating System Architecture](#15-bios--operating-system-architecture)
    - [ROMDIR Filesystem Structure](#bios-romdir-filesystem-structure)
    - [EE/IOP Boot Flow](#bios-eeiop-boot-flow)
    - [EE Threading & Cooperative Scheduler](#bios-ee-threading--cooperative-scheduler)
    - [EE Syscall Table](#bios-ee-syscall-table)
    - [PlayStation 1 Backward Compatibility (PS1DRV, TBIN)](#bios-playstation-1-backward-compatibility)
    - [IOP Dynamic Module Linking (Export / Import Tables)](#bios-iop-dynamic-module-linking)
    - [Core IOP Modules Reference](#bios-core-iop-modules-reference)

---

## 1. PS2 System Overview

The PlayStation 2 is a heterogeneous multi-processor architecture comprising two primary processing domains connected via the Subsystem Interface (SIF):

* **Emotion Engine (EE)**: Main CPU clocked at **294.912 MHz**. A custom 64-bit MIPS III/IV core (R5900) featuring 128-bit SIMD MultiMedia Instructions (MMI), dual-issue superscalar execution, 16 KB instruction cache, 8 KB data cache, 16 KB Scratchpad RAM (SPRAM), COP0 (System Control / MMU / TLB), COP1 (Single-Precision FPU), and COP2 (Vector Unit 0 in Macro Mode).
* **DMAC (EE)**: 10-channel DMA controller transferring data at bus clock (**147.456 MHz**, 128-bit quadwords). Connects EE, VIF0, VIF1, GIF, IPU, SIF, and SPRAM.
* **Vector Units (VU0 & VU1)**: Custom 294.912 MHz SIMD vector DSPs with 32 128-bit vector registers (`vf00`..`vf31`) and 16 16-bit integer registers (`vi00`..`vi15`). VU0 operates in Macro Mode (COP2 on EE) or Micro Mode. VU1 operates in Micro Mode and drives GIF PATH1 directly via `XGKICK`.
* **Graphics Interface (GIF)**: Arbitrates geometry and texture streams across three independent paths (PATH1: VU1, PATH2: VIF1, PATH3: EE DMAC Ch2) and delivers data to the Graphics Synthesizer.
* **Graphics Synthesizer (GS)**: 147.456 MHz fixed-function rasterizer with 4 MB embedded DRAM (eDRAM), 16 pixel pipelines, free alpha blending and depth testing, achieving a peak fillrate of 1.2 gigapixels/second.
* **Image Processing Unit (IPU)**: Dedicated hardware MPEG-1/MPEG-2 macroblock video decoder.
* **Input/Output Processor (IOP)**: MIPS R3000A core clocked at **36.864 MHz** (underclocked to 33.8688 MHz in PS1 mode) with 2 MB RAM. Manages storage, optical drives, audio, controllers, and serial buses.
* **CDVD Controller**: Reads CD-ROM, DVD-ROM (single and dual layer), CD-DA, and handles MagicGate authentication.
* **Sound Processing Unit 2 (SPU2)**: 48 voices across two 24-voice cores (Core 0 and Core 1) with 2 MB dedicated Sound RAM, hardware ADPCM decoding, and AutoDMA PCM streaming.
* **SIO2**: Serial interface managing DualShock/DualShock 2 controllers and flash memory cards.

---

## 2. Memory Maps

### EE Virtual / Physical Memory Map
* MIPS Segments:
  * `KUSEG`: `0x00000000 - 0x7FFFFFFF` (User, TLB-mapped)
  * `KSEG0`: `0x80000000 - 0x9FFFFFFF` (Kernel, directly-mapped, cached: `paddr = vaddr & 0x1FFFFFFF`)
  * `KSEG1`: `0xA0000000 - 0xBFFFFFFF` (Kernel, directly-mapped, uncached: `paddr = vaddr & 0x1FFFFFFF`)
  * `KSSEG`: `0xC0000000 - 0xDFFFFFFF` (Supervisor, TLB-mapped)
  * `KSEG3`: `0xE0000000 - 0xFFFFFFFF` (Kernel, TLB-mapped)

| Virtual Address | Physical Address | Size | Description |
|:---|:---|:---|:---|
| `0x00000000` | `0x00000000` | 32 MB | Main RDRAM (First 1 MB reserved for kernel) |
| `0x20000000` | `0x00000000` | 32 MB | Main RDRAM, uncached mirror |
| `0x30100000` | `0x00100000` | 31 MB | Main RDRAM, uncached accelerated (DMA / FIFO buffers) |
| `0x10000000` | `0x10000000` | 64 KB | EE I/O Registers (Timers, DMAC, IPU, GIF, INTC) |
| `0x11000000` | `0x11000000` | 4 KB | VU0 Micro Code Memory |
| `0x11004000` | `0x11004000` | 4 KB | VU0 Data Memory |
| `0x11008000` | `0x11008000` | 16 KB | VU1 Micro Code Memory |
| `0x1100C000` | `0x1100C000` | 16 KB | VU1 Data Memory |
| `0x12000000` | `0x12000000` | 8 KB | GS Privileged Registers (PMODE, DISPFB, DISPLAY, CSR) |
| `0x1C000000` | `0x1C000000` | 2 MB | IOP Main RAM direct mapping from EE |
| `0x1FC00000` | `0x1FC00000` | 4 MB | BIOS ROM (rom0 uncached) |
| `0x9FC00000` | `0x1FC00000` | 4 MB | BIOS ROM (rom09 cached) |
| `0xBFC00000` | `0x1FC00000` | 4 MB | BIOS ROM (rom0b uncached bootstrap) |
| `0x70000000` | — | 16 KB | Scratchpad RAM (SPRAM) - virtual addressing only |

*Note: TOOL development units feature 128 MB RDRAM.*

### IOP Physical Memory Map

| Physical Address | Size | Description |
|:---|:---|:---|
| `0x00000000` | 2 MB | IOP Main RAM |
| `0x1D000000` | — | SIF Registers |
| `0x1F800000` | 64 KB | IOP I/O Registers (Timers, SIO2, INTC, CDVD) |
| `0x1F900000` | 1 KB | SPU2 Registers (Core 0 and Core 1) |
| `0x1FC00000` | 4 MB | BIOS (rom0) - Shared with EE |
| `0xFFFE0000` | 0.5 KB | Cache Control (KSEG2) |

### Additional Hardware Memory
* **GS VRAM**: 4 MB embedded DRAM (eDRAM) partitioned into framebuffers, textures, and Z-buffer.
* **SPU2 Work RAM**: 2 MB dedicated Sound RAM.
* **Memory Card**: 8 MB standard flash memory card (expandable on third-party cards).

---

## 3. Complete I/O Register Maps

### EE I/O Register Map (`0x10000000` - `0x12001FFF`)

#### EE Timers
* `0x10000000` (+ `N * 0x800`): `TN_COUNT` (16-bit Counter, N=0..3)
* `0x10000010` (+ `N * 0x800`): `TN_MODE` (16-bit Control / Status)
* `0x10000020` (+ `N * 0x800`): `TN_COMP` (16-bit Compare Target)
* `0x10000030` (+ `N * 0x800`): `TN_HOLD` (16-bit SBUS Hold, T0 & T1 only)

#### Image Processing Unit (IPU)
* `0x10002000` (8 bytes): `IPU_CMD` - Send Command (W) / Read Result (R)
* `0x10002010` (4 bytes): `IPU_CTRL` - Control / Status
* `0x10002020` (4 bytes): `IPU_BP` - Bitstream Pointer & FIFO Counts
* `0x10002030` (8 bytes): `IPU_TOP` - Top 32 bits of Bitstream
* `0x10007000` (16 bytes): Out FIFO (Read)
* `0x10007010` (16 bytes): In FIFO (Write)

#### Graphics Interface (GIF)
* `0x10003000` (4 bytes): `GIF_CTRL` - Control register (Reset, Stop)
* `0x10003010` (4 bytes): `GIF_MODE` - Mode setting (Mask PATH3, Intermittent)
* `0x10003020` (4 bytes): `GIF_STAT` - Status (Active Path, Queued Paths, FIFO count)
* `0x10003040` (4 bytes): `GIF_TAG0` - Bits 0-31 of tag
* `0x10003050` (4 bytes): `GIF_TAG1` - Bits 32-63 of tag
* `0x10003060` (4 bytes): `GIF_TAG2` - Bits 64-95 of tag
* `0x10003070` (4 bytes): `GIF_TAG3` - Bits 96-127 of tag
* `0x10003080` (4 bytes): `GIF_CNT` - Loop transfer counter
* `0x10003090` (4 bytes): `GIF_P3CNT` - PATH3 transfer counter when interrupted
* `0x100030A0` (4 bytes): `GIF_P3TAG` - Bits 0-31 of interrupted PATH3 tag
* `0x10006000` (16 bytes): `GIF_FIFO` - 16-quadword FIFO entry

#### EE DMAC Channels & Control
* `0x10008000`: Channel 0 - VIF0
* `0x10009000`: Channel 1 - VIF1
* `0x1000A000`: Channel 2 - GIF (PATH3)
* `0x1000B000`: Channel 3 - IPU_FROM
* `0x1000B400`: Channel 4 - IPU_TO
* `0x1000C000`: Channel 5 - SIF0 (from IOP)
* `0x1000C400`: Channel 6 - SIF1 (to IOP)
* `0x1000C800`: Channel 7 - SIF2 (bidirectional / PSX mode)
* `0x1000D000`: Channel 8 - SPR_FROM (Scratchpad to RAM)
* `0x1000D400`: Channel 9 - SPR_TO (RAM to Scratchpad)
* `0x1000E000` (4 bytes): `D_CTRL` - DMAC master control & cycle stealing
* `0x1000E010` (4 bytes): `D_STAT` - Interrupt status and channel mask
* `0x1000E020` (4 bytes): `D_PCR` - Priority control & COP0 condition
* `0x1000E030` (4 bytes): `D_SQWC` - Skip quadword control
* `0x1000E040` (4 bytes): `D_RBSR` - MFIFO ringbuffer size
* `0x1000E050` (4 bytes): `D_RBOR` - MFIFO ringbuffer offset
* `0x1000E060` (4 bytes): `D_STADR` - Stall address
* `0x1000F520` (4 bytes): `D_ENABLER` - DMAC disable status (Read)
* `0x1000F590` (4 bytes): `D_ENABLEW` - DMAC disable control (Write)

#### EE INTC, SIF & Privileged GS Registers
* `0x1000F000` (4 bytes): `INTC_STAT` - Interrupt status (Write 1 to clear)
* `0x1000F010` (4 bytes): `INTC_MASK` - Interrupt mask (Write 1 to toggle)
* `0x1000F180` (1 byte): `KPUTCHAR` - Hardware console debug character output
* `0x1000F200` (4 bytes): `SIF_MSCOM` - EE to IOP communication register
* `0x1000F210` (4 bytes): `SIF_SMCOM` - IOP to EE communication register
* `0x1000F220` (4 bytes): `SIF_MSFLAG` - EE to IOP semaphore flags
* `0x1000F230` (4 bytes): `SIF_SMFLAG` - IOP to EE semaphore flags
* `0x1000F240` (4 bytes): `SIF_CTRL` - SIF master control register
* `0x1000F430` (4 bytes): `MCH_DRD` - RDRAM configuration data
* `0x1000F440` (4 bytes): `MCH_RICM` - RDRAM initialization command register
* `0x12000000` (8 bytes): `GS_PMODE` - PCRTC display modes & circuit enable
* `0x12000070` (8 bytes): `GS_DISPFB1` - Display buffer base output circuit 1
* `0x12000080` (8 bytes): `GS_DISPLAY1` - Output circuit 1 timing and dimensions
* `0x12000090` (8 bytes): `GS_DISPFB2` - Display buffer base output circuit 2
* `0x120000A0` (8 bytes): `GS_DISPLAY2` - Output circuit 2 timing and dimensions
* `0x120000E0` (8 bytes): `GS_BGCOLOR` - Background border color
* `0x12001000` (8 bytes): `GS_CSR` - GS Control & Status Register
* `0x12001010` (8 bytes): `GS_IMR` - GS Interrupt Mask Register
* `0x12001040` (8 bytes): `GS_BUSDIR` - Host-local data transfer direction

---

### IOP I/O Register Map (`0x1D000000`, `0x1F400000` - `0x1F9007FF`)

#### IOP SIF Registers
* `0x1D000000` (4 bytes): `SIF_MSCOM` (Read EE receive buffer)
* `0x1D000010` (4 bytes): `SIF_SMCOM` (Write IOP receive buffer)
* `0x1D000020` (4 bytes): `SIF_MSFLAG` (Read/clear EE flags)
* `0x1D000030` (4 bytes): `SIF_SMFLAG` (Write IOP flags)
* `0x1D000040` (4 bytes): `SIF_CTRL`

#### CDVD Drive Registers
* `0x1F402004` (1 byte): Current N command (R/W)
* `0x1F402005` (1 byte): N command status (R) / N command parameter write (W)
* `0x1F402006` (1 byte): CDVD error register (R)
* `0x1F402007` (1 byte): BREAK command register (W)
* `0x1F402008` (1 byte): `CDVD I_STAT` - Interrupt status / acknowledge
* `0x1F40200A` (1 byte): CDVD drive status
* `0x1F40200B` (1 byte): Sticky drive status
* `0x1F40200F` (1 byte): CDVD disc type detection
* `0x1F402016` (1 byte): Current S command (R/W)
* `0x1F402017` (1 byte): S command status (R) / S command parameters (W)
* `0x1F402018` (1 byte): S command result buffer (R)

#### IOP Interrupt Control
* `0x1F801070` (4 bytes): `I_STAT` - Interrupt status (Write 0 to acknowledge)
* `0x1F801074` (4 bytes): `I_MASK` - Interrupt mask
* `0x1F801078` (1 byte): `I_CTRL` - Global interrupt enable (Read returns and clears bit 0)

#### IOP DMA Channels
* `0x1F801080`: Channel 0 - MDECin
* `0x1F801090`: Channel 1 - MDECout
* `0x1F8010A0`: Channel 2 - SIF2 (GPU in PSX mode)
* `0x1F8010B0`: Channel 3 - CDVD
* `0x1F8010C0`: Channel 4 - SPU2 Core 0
* `0x1F8010D0`: Channel 5 - PIO
* `0x1F8010E0`: Channel 6 - OTC (Ordering Table Clear)
* `0x1F801500`: Channel 7 - SPU2 Core 1
* `0x1F801510`: Channel 8 - DEV9 (HDD / Network adapter)
* `0x1F801520`: Channel 9 - SIF0 (IOP to EE, Chain Tag mode)
* `0x1F801530`: Channel 10 - SIF1 (EE to IOP, Chain Tag mode)
* `0x1F801540`: Channel 11 - SIO2in
* `0x1F801550`: Channel 12 - SIO2out
* `0x1F8010F0`: `DPCR` - DMA Priority Control 1
* `0x1F8010F4`: `DICR` - DMA Interrupt Control 1
* `0x1F801570`: `DPCR2` - DMA Priority Control 2
* `0x1F801574`: `DICR2` - DMA Interrupt Control 2
* `0x1F801578`: `DMACEN` - Global DMA Enable
* `0x1F80157C`: `DMACINTEN` - Global DMA Interrupt Control

#### SIO2 Controller & Memory Card Interface
* `0x1F808200` - `0x1F80823F`: `SIO2_SEND3` - Command parameter buffer array (16 commands)
* `0x1F808240` - `0x1F80825F`: `SIO2_SEND1` / `SIO2_SEND2` - Port 1 / Port 2 control
* `0x1F808260` (1 byte): `SIO2_FIFOIN` - Data Write FIFO
* `0x1F808264` (1 byte): `SIO2_FIFOOUT` - Data Read FIFO
* `0x1F808268` (4 bytes): `SIO2_CTRL` - Control register (Bit 0 starts transfer, bits 2-3 reset)
* `0x1F80826C` (4 bytes): `SIO2_RECV1` - Peripheral connection status
* `0x1F808270` (4 bytes): `SIO2_RECV2`
* `0x1F808274` (4 bytes): `SIO2_RECV3`
* `0x1F808280` (4 bytes): `SIO2_ISTAT` - Interrupt status

#### SPU2 Sound Processor
* `0x1F900000` - `0x1F90017F`: Core 0 Voice 0..23 Registers
* `0x1F900190` (4 bytes): Core 0 Key ON
* `0x1F900194` (4 bytes): Core 0 Key OFF
* `0x1F90019A` (2 bytes): Core 0 Attributes
* `0x1F9001A8` (4 bytes): Core 0 DMA Transfer Start Address (TSA)
* `0x1F9001AC` (2 bytes): Core 0 Internal FIFO
* `0x1F9001B0` (2 bytes): Core 0 AutoDMA Status / Control (`SPU_ADMA_CTRL`)
* `0x1F9001C0` - `0x1F9002DF`: Core 0 Voice Start / Loop / Next addresses
* `0x1F900340` (4 bytes): Core 0 `ENDX` Voice End Flags
* `0x1F900344` (2 bytes): Core 0 Status Register
* `0x1F900400` - `0x1F900744`: Core 1 Registers (Identical layout to Core 0)
* `0x1F900760` (2 bytes): Master Volume Left (`0x0000` - `0x3FFF`)
* `0x1F900762` (2 bytes): Master Volume Right
* `0x1F900764` (2 bytes): Effect Volume Left
* `0x1F900766` (2 bytes): Effect Volume Right
* `0x1F900768` (2 bytes): Core 1 External Input Volume Left
* `0x1F90076A` (2 bytes): Core 1 External Input Volume Right

---

## 4. Emotion Engine (EE R5900 Core)

### EE Architecture & Registers
* **Pipeline**: Dual-issue superscalar, issuing one integer/MMI/branch instruction and one floating-point/vector instruction per cycle under ideal conditions.
* **GPRs**: 32 General-Purpose Registers, each **128-bit wide**. The upper 64 bits are preserved across 64-bit operations and utilized by 128-bit MMI SIMD instructions (`LQ`, `SQ`, `PADDW`, `POR`, etc.).
  * `zero` ($0): Hardwired to 0.
  * `at` ($1): Assembler temporary.
  * `v0`-`v1` ($2-$3): Function return values.
  * `a0`-`a3` ($4-$7): Function arguments 1-4.
  * `t0`-`t7` ($8-$15): Temporaries (`t0`-`t3` serve as arguments 5-8).
  * `s0`-`s7` ($16-$23): Callee-saved registers.
  * `t8`-`t9` ($24-$25): Temporaries.
  * `k0`-`k1` ($26-$27): Reserved for kernel exception handlers.
  * `gp` ($28): Global pointer.
  * `sp` ($29): Stack pointer (must remain 16-byte aligned).
  * `fp` ($30): Frame pointer.
  * `ra` ($31): Return address.
* **Special Registers**:
  * `PC` (32-bit): Program counter.
  * `HI` / `LO` (64-bit): Multiply / divide accumulator pipeline 0.
  * `HI1` / `LO1` (64-bit): Multiply / divide accumulator pipeline 1 (used by `MULT1`, `DIV1`, `MADD1`).
  * `SA` (32-bit): Shift amount register used by `QFSRV`.

---

### EE Instruction Decoding Tables

#### Primary Opcode (Bits 31-26)
```text
31---------26---------------------------------------------------0
|  opcode   |
------6----------------------------------------------------------
     |--000--|--001--|--010--|--011--|--100--|--101--|--110--|--111--|
  lo
 000 | SPEC  | REGIM |   J   |  JAL  |  BEQ  |  BNE  | BLEZ  | BGTZ  |
 001 | ADDI  | ADDIU | SLTI  | SLTIU | ANDI  |  ORI  | XORI  |  LUI  |
 010 | COP0  | COP1  | COP2  |  ---  | BEQL  | BNEL  | BLEZL | BGTZL |
 011 | DADDI | DADDIU|  LDL  |  LDR  |  MMI  |  ---  |  LQ   |  SQ   |
 100 |  LB   |  LH   |  LWL  |  LW   |  LBU  |  LHU  |  LWR  |  LWU  |
 101 |  SB   |  SH   |  SWL  |  SW   |  SDL  |  SDR  |  SWR  | CACHE |
 110 |  ---  | LWC1  |  ---  | PREF  |  ---  |  ---  | LQC2  |  LD   |
 111 |  ---  | SWC1  |  ---  |  ---  |  ---  |  ---  | SQC2  |  SD   |
  hi |-------|-------|-------|-------|-------|-------|-------|-------|
```

#### SPECIAL Function (Bits 5-0 when Opcode = `000000b`)
```text
     |--000--|--001--|--010--|--011--|--100--|--101--|--110--|--111--|
  lo
 000 |  SLL  |  ---  |  SRL  |  SRA  | SLLV  |  ---  | SRLV  | SRAV  |
 001 |  JR   | JALR  | MOVZ  | MOVN  |SYSCALL| BREAK |  ---  | SYNC  |
 010 | MFHI  | MTHI  | MFLO  | MTLO  | DSLLV |  ---  | DSRLV | DSRAV |
 011 | MULT  | MULTU |  DIV  | DIVU  |  ---  |  ---  |  ---  |  ---  |
 100 |  ADD  | ADDU  |  SUB  | SUBU  |  AND  |  OR   |  XOR  |  NOR  |
 101 | MFSA  | MTSA  |  SLT  | SLTU  | DADD  | DADDU | DSUB  | DSUBU |
 110 |  TGE  | TGEU  |  TLT  | TLTU  |  TEQ  |  ---  |  TNE  |  ---  |
 111 | DSLL  |  ---  | DSRL  | DSRA  | DSLL32|  ---  | DSRL32| DSRA32|
  hi |-------|-------|-------|-------|-------|-------|-------|-------|
```

#### MMI Sub-Table (Bits 5-0 when Opcode = `011100b`)
```text
     |--000--|--001--|--010--|--011--|--100--|--101--|--110--|--111--|
  lo
 000 | MADD  | MADDU |  ---  |  ---  | PLZCW |  ---  |  ---  |  ---  |
 001 | MMI0  | MMI2  |  ---  |  ---  |  ---  |  ---  |  ---  |  ---  |
 010 | MFHI1 | MTHI1 | MFLO1 | MTLO1 |  ---  |  ---  |  ---  |  ---  |
 011 | MULT1 | MULTU1| DIV1  | DIVU1 |  ---  |  ---  |  ---  |  ---  |
 100 | MADD1 | MADDU1|  ---  |  ---  |  ---  |  ---  |  ---  |  ---  |
 101 | MMI1  | MMI3  |  ---  |  ---  |  ---  |  ---  |  ---  |  ---  |
 110 | PMFHL | PMTHL |  ---  |  ---  | PSLLH |  ---  | PSRLH | PSRAH |
 111 |  ---  |  ---  |  ---  |  ---  | PSLLW |  ---  | PSRLW | PSRAW |
  hi |-------|-------|-------|-------|-------|-------|-------|-------|
```

* **MMI0**: `PADDW`, `PSUBW`, `PCGTW`, `PMAXW`, `PADDH`, `PSUBH`, `PCGTH`, `PMAXH`, `PADDB`, `PSUBB`, `PCGTB`, `PADDSW`, `PSUBSW`, `PEXTLW`, `PPACW`, `PADDSH`, `PSUBSH`, `PEXTLH`, `PPACH`, `PADDSB`, `PSUBSB`, `PEXTLB`, `PPACB`, `PEXT5`, `PPAC5`.
* **MMI1**: `PABSW`, `PCEQW`, `PMINW`, `PADSBH`, `PABSH`, `PCEQH`, `PMINH`, `PCEQB`, `PADDUW`, `PSUBUW`, `PEXTUW`, `PADDUH`, `PSUBUH`, `PEXTUH`, `PADDUB`, `PSUBUB`, `PEXTUB`, `QFSRV`.
* **MMI2**: `PMADDW`, `PSLLVW`, `PSRLVW`, `PMSUBW`, `PMFHI`, `PMFLO`, `PINTH`, `PMULTW`, `PDIVW`, `PCPYLD`, `PMADDH`, `PHMADH`, `PAND`, `PXOR`, `PMSUBH`, `PHMSBH`, `PEXEH`, `PREVH`, `PMULTH`, `PDIVBW`, `PEXEW`, `PROT3W`.
* **MMI3**: `PMADDUW`, `PSRAVW`, `PMTHI`, `PMTLO`, `PINTEH`, `PMULTUW`, `PDIVUW`, `PCPYUD`, `POR`, `PNOR`, `PEXCH`, `PCPYH`, `PEXCW`.

---

### EE RDRAM Initialization

During cold boot, the BIOS initializes RDRAM timing and devices via `MCH_DRD` (`0x1000F430`) and `MCH_RICM` (`0x1000F440`):

```cpp
// Emulator logic for RDRAM initialization handshake:
uint32_t rdram_read(uint32_t addr) {
    if (addr == 0x1000F430) return 0;
    if (addr == 0x1000F440) {
        uint8_t SOP = (MCH_RICM >> 6) & 0xF;
        uint8_t SA  = (MCH_RICM >> 16) & 0xFFF;
        if (!SOP) {
            switch (SA) {
                case 0x21: if (rdram_sdevid < 2) { rdram_sdevid++; return 0x1F; } return 0;
                case 0x23: return 0x0D0D;
                case 0x24: return 0x0090;
                case 0x40: return MCH_RICM & 0x1F;
            }
        }
        return 0;
    }
}
void rdram_write(uint32_t addr, uint32_t data) {
    if (addr == 0x1000F430) {
        uint8_t SA  = (data >> 16) & 0xFFF;
        uint8_t SBC = (data >> 6) & 0xF;
        if (SA == 0x21 && SBC == 0x1 && ((MCH_DRD >> 7) & 1) == 0) rdram_sdevid = 0;
        MCH_RICM = data & ~0x80000000;
    } else if (addr == 0x1000F440) {
        MCH_DRD = data;
    }
}
```

---

### EE COP0 System Control & Exceptions

#### COP0 Register Map
* `$0` Index: TLB entry index for `TLBR` / `TLBWI` (0-47).
* `$1` Random: Decrements every instruction, bounds `[Wired, 47]`. Used by `TLBWR`.
* `$2` EntryLo0: Even page TLB entry.
* `$3` EntryLo1: Odd page TLB entry.
* `$4` Context: Bad virtual page pointer.
* `$5` PageMask: Page size mask (4 KB to 16 MB).
* `$6` Wired: Boundary for `Random`.
* `$8` BadVAddr: Virtual address that triggered an exception.
* `$9` Count: Hardware timer incrementing every EE cycle (294.912 MHz).
* `$10` EntryHi: Virtual page number / 2 (`VPN2`) and `ASID`.
* `$11` Compare: Timer target. Writing acknowledges timer interrupt.
* `$12` Status: Interrupt masks, operating mode, exception levels.
* `$13` Cause: Exception reason, pending IRQs, branch delay status.
* `$14` EPC: Exception program counter (Level 1).
* `$15` PRid: Processor revision (`0x000059xx`).
* `$16` Config: L1 cache configurations.
* `$23` BadPAddr: Physical address triggering bus error.
* `$24` Debug: EJTAG debug register.
* `$25` Perf: Performance counter control.
* `$28` TagLo / `$29` TagHi: Cache tag access registers.
* `$30` ErrorEPC: Error program counter (Level 2).

#### Exception Handling Vectors
| Exception Name | Normal Vector | Bootstrap Vector (`Status.BEV=1`) | Level |
|:---|:---|:---|:---|
| Reset / NMI | `0xBFC00000` | `0xBFC00000` | Level 2 |
| TLB Refill | `0x80000000` | `0xBFC00200` | Level 1 |
| Performance Counter | `0x80000080` | `0xBFC00280` | Level 2 |
| Debug | `0x80000100` | `0xBFC00300` | Level 2 |
| General Exceptions | `0x80000180` | `0xBFC00380` | Level 1 |
| Interrupts (`INT0`..`INT5`)| `0x80000200` | `0xBFC00400` | Level 1 |

* **Branch Delay Slot Handling**: If an exception occurs in a branch delay slot, `Cause.BD` (or `Cause.BD2`) is asserted, and `EPC` (or `ErrorEPC`) points to the preceding branch instruction, ensuring the branch re-executes cleanly upon `ERET`.
* **Interrupt Masking**: Interrupts are only enabled when `Status.IE && Status.EIE && !Status.EXL && !Status.ERL`.

---

### EE Memory Management & TLB

* **TLB Entries**: 48 fully associative dual-page entries mapping even and odd virtual pages.
* **Page Sizes (`PageMask` register bits 24:13)**:
  * `0x000`: 4 KB
  * `0x003`: 16 KB
  * `0x00F`: 64 KB
  * `0x03F`: 256 KB
  * `0x0FF`: 1 MB
  * `0x3FF`: 4 MB
  * `0xFFF`: 16 MB
* **EntryLo Bits**:
  * Bit 0 (`G`): Global page (ignores `ASID`). Both `EntryLo0` and `EntryLo1` must have `G=1` for global mapping.
  * Bit 1 (`V`): Page valid.
  * Bit 2 (`D`): Dirty bit (1 = writable; 0 = write generates TLB Modified exception).
  * Bits 5:3 (`C`): Cache mode (`2` = Uncached, `3` = Cached, `7` = Uncached Accelerated).
  * Bits 25:6 (`PFN`): Physical Frame Number.
  * Bit 31 (`S`): Scratchpad mapping flag (only valid on `EntryLo0`). Maps virtual page directly to 16 KB SPRAM (`0x70000000`).

---

### EE Cache Architecture & Coherency

* **Instruction Cache (icache)**: 16 KB, 2-way set associative, 128 cache lines, 64 bytes (4 quadwords) per way. Indexed by virtual address bits 13:6.
* **Data Cache (dcache)**: 8 KB, 2-way set associative, 64 cache lines, 64 bytes per way. Indexed by virtual address bits 12:6.
* **Tags**:
  * icache tag: `[V | R | PFN]` (Valid, Least Recently Filled replacement bit, Physical Frame Number).
  * dcache tag: `[D | V | R | L | PFN]` (Dirty, Valid, LRF, Locked).
* **Way Locking**: In the data cache, setting the `Locked` (`L`) bit prevents that way from ever being evicted, forcing all refills into the opposite way.
* **Refill Latency**: Refilling a cache line transfers 4 quadwords (64 bytes). Minimum refill penalty is 8 EE cycles (4 bus cycles); RDRAM access incurs ~40 EE cycles.
* **Cache Coherency & Known Game Quirks**:
  * DMAC cannot access the L1 cache. Coherency must be manually maintained via `FlushCache` syscall (`0x64`).
  * *Dead or Alive 2*: Re-uses a single buffer for sending and receiving data to IOP sound modules. Without cache emulation, IOP overwrites the buffer, preventing boot.
  * *Ice Age 2*: Returns a pointer to a stack array for IOP transmission and immediately flushes the cache. Corruption occurs only in cache while main memory data remains pristine.
  * *WRC 4*: Decompressor unpacks an ELF that overlaps its own code in memory. Requires icache emulation to avoid self-destruction.

---

### EE COP0 Timers

* **`COP0.Count` ($9)**: 32-bit free-running hardware counter incremented every EE cycle at 294.912 MHz.
* **`COP0.Compare` ($11)**: When `Count == Compare`, COP0 asserts interrupt request `INT5` (`Cause` bit 15). Writing to `Compare` clears the pending interrupt.

---

### EE COP1 Floating-Point Unit (FPU)

* **Architecture**: Single-precision FPU supporting IEEE 754-compliant 32-bit floats.
* **Registers**: 32 FPRs (`f0`..`f31`), `FCR0` (Revision), `FCR31` (Control & Status).
* **Crucial Differences from IEEE 754**:
  1. **No NaNs or Infinities**: Exponent `0xFF` is evaluated as a normal number with extreme magnitude.
  2. **No Denormals**: Exponent `0x00` forces the fractional value to be immediately truncated to zero.
  3. **Forced Round-Towards-Zero**: Rounding mode is hardwired to truncation towards zero.

---

## 5. EE Hardware Timers

The EE features four 16-bit hardware timers (`T0`..`T3`). T3 is reserved by the BIOS for alarms (`SetAlarm`).

* **Base Addresses**: `0x10000000 + N * 0x800` (N=0..3).
* **Registers**:
  * `TN_COUNT`: 16-bit counter value.
  * `TN_MODE`: Clock select, gate control, compare interrupt enable, overflow enable.
    * Bits 1:0 (`Clock`): `0` = Bus Clock (~147.456 MHz), `1` = Bus Clock / 16, `2` = Bus Clock / 256, `3` = HBLANK.
    * Bit 2 (`Gate Enable`), Bit 3 (`Gate Type`: `0` = HBLANK, `1` = VBLANK).
    * Bits 5:4 (`Gate Mode`): Count while inactive (`0`), Reset on low->high (`1`), Reset on high->low (`2`), Reset on both edges (`3`).
    * Bit 6: Clear counter when `COUNT == COMP`.
    * Bit 7: Timer Enable.
    * Bit 8: Compare interrupt enable.
    * Bit 9: Overflow interrupt enable (`0xFFFF -> 0x0000`).
    * Bit 10: Compare interrupt flag (Write 1 to clear).
    * Bit 11: Overflow interrupt flag (Write 1 to clear).
  * `TN_COMP`: 16-bit compare value.
  * `TN_HOLD`: Holds counter value upon SBUS interrupt (T0 & T1 only).
* **Video Timings**:
  * **PAL**: 312 scanlines per frame (VBOFF: 286, VBON: 26). 9,436 BUSCLK cycles per scanline.
  * **NTSC**: 262 scanlines per frame (VBOFF: 240, VBON: 22). 9,370 BUSCLK cycles per scanline.

---

## 6. Graphics Interface (GIF)

### GIF Control Registers & Arbitration
Arbitrates three paths to the GS:
* **PATH1**: Driven by VU1 via `XGKICK` instruction (Highest priority).
* **PATH2**: Driven by VIF1 via `DIRECT` / `DIRECTHL` commands (Medium priority).
* **PATH3**: Driven by EE DMAC Channel 2 (Lowest priority, buffered via 16-quadword FIFO).

* `0x10003000` `GIF_CTRL`: Bit 0 = Reset GIF; Bit 3 = Temporary stop (1=pause, 0=resume).
* `0x10003010` `GIF_MODE`: Bit 0 = Mask PATH3; Bit 2 = Intermittent mode.
* `0x10003020` `GIF_STAT`:
  * Bit 0: PATH3 masked by `GIF_MODE`.
  * Bit 1: PATH3 masked by VIF1 `MSKPATH3`.
  * Bits 11:10: Active path (`0` = Idle, `1` = PATH1, `2` = PATH2, `3` = PATH3).
  * Bits 28:24: Quadwords currently in GIF FIFO (max 16).

---

### GIFtag Format & Descriptors

A GIF packet consists of primitives prefixed by a 128-bit `GIFtag`:

```text
Bits 14:0   : NLOOP  - Data units per register descriptor
Bit 15      : EOP    - End Of Packet flag (1 = Last packet in transfer)
Bit 46      : PRE    - Enable PRIM field override
Bits 57:47  : PRIM   - Primitive data passed directly to GS PRIM register if PRE=1
Bits 59:58  : FLG    - Format: 00b=PACKED, 01b=REGLIST, 10b/11b=IMAGE
Bits 63:60  : NREGS  - Number of register descriptors (0 = 16 descriptors)
Bits 127:64 : REGS   - 16 4-bit register descriptors processed in little-endian order
```

---

### GIF Data Formats

1. **PACKED Format (`FLG = 00b`)**:
   * Data unit: Quadwords (16 bytes). Total quadwords = `NLOOP * NREGS`.
   * Descriptors:
     * `0x0` `PRIM`: Primitive attributes.
     * `0x1` `RGBAQ`: Writes RGBA (Q unchanged).
     * `0x2` `STQ`: 32-bit IEEE float S, T, and Q parameters.
     * `0x3` `UV`: 14-bit unsigned fixed-point texel coordinates (4-bit fractional).
     * `0x4` `XYZF2` / `XYZF3`: Signed 16-bit X, Y (4-bit fractional), 24-bit Z, 8-bit Fog. Bit 111 = Disable drawing (XYZF3).
     * `0x5` `XYZ2` / `XYZ3`: Signed 16-bit X, Y (4-bit fractional), 32-bit Z. Bit 111 = Disable drawing (XYZ3).
     * `0xA` `FOG`: Fog factor in bits 107:100.
     * `0xE` `A+D`: Lower 64 bits = data; upper 64 bits (bits 71:64) = GS register address.
     * `0xF` `NOP`: No operation.
2. **REGLIST Format (`FLG = 01b`)**:
   * Data unit: Doublewords (64 bits). Two writes per quadword.
3. **IMAGE Format (`FLG = 10b` / `11b`)**:
   * Direct pixel stream into `GS_HWREG` for VRAM texture uploading. Total quadwords = `NLOOP`.

---

### GIF PATH3 Masking & FIFO Quirks
PATH3 features an internal 16-quadword FIFO. When `GIF_MODE` or VIF1 masks PATH3, data accumulates in this FIFO until unmasked. Emulating PATH3 masking without the FIFO hangs games like *Wallace and Gromit in Project Zoo* and *GTA: San Andreas*.

---

## 7. DMA Controller (DMAC)

### DMAC Channels & Channel Registers
Each channel occupies a `0x100` byte block:
* `+0x00` `Dn_CHCR`: Channel control.
  * Bit 0 (`DIR`): `0` = To memory, `1` = From memory.
  * Bits 3:2 (`MOD`): `0` = Normal, `1` = Chain, `2` = Interleave.
  * Bit 6 (`TTE`): Transfer DMAtag header before data.
  * Bit 7 (`TIE`): Trigger IRQ when tag's IRQ bit is set.
  * Bit 8 (`STR`): `1` = Channel busy / Start transfer.
  * Bits 31:16 (`TAG`): Lower 16 bits of current DMAtag.
* `+0x10` `Dn_MADR`: Memory Address (must be 16-byte aligned). Updates dynamically during transfer!
* `+0x20` `Dn_QWC`: Quadword Count (1-65535).
* `+0x30` `Dn_TADR`: Tag Address (used in Chain Mode).
* `+0x40` `Dn_ASR0` / `+0x50` `Dn_ASR1`: Address Stack Registers for nested DMA tags.
* `+0x80` `Dn_SADR`: Scratchpad memory address (SPR channels only).

---

### DMAC Chain Mode & DMAtag Format

A DMAtag is a 128-bit structure read from `TADR`:
```text
Bits 15:0   : QWC   - Quadwords to transfer in this chunk
Bits 27:26  : PCE   - Priority control enable (3 = D_PCR.31 active)
Bits 30:28  : ID    - Tag ID
Bit 31      : IRQ   - Interrupt request bit
Bits 62:32  : ADDR  - Memory address for data payload (Bits 3:0 must be 0)
Bit 63      : SPR   - 0 = Main RAM, 1 = Scratchpad RAM
Bits 127:64 : Extra - Transferred directly if Dn_CHCR.TTE = 1
```

#### Source Chain Tag IDs:
* `0` `refe`: Transfer from `DMAtag.ADDR`. Increment `TADR += 16`. Transfer ends after this tag (`tag_end = true`).
* `1` `cnt`: Transfer from `TADR + 16`. `TADR` advances past data payload.
* `2` `next`: Transfer from `TADR + 16`. Next `TADR` loaded from `DMAtag.ADDR`.
* `3` `ref`: Transfer from `DMAtag.ADDR`. Next tag read from `TADR + 16`.
* `4` `refs`: Transfer from `DMAtag.ADDR`. Next tag read from `TADR + 16` (Stalls until destination ready).
* `5` `call`: Pushes return tag address to `ASR0` (or `ASR1`), sets `TADR = DMAtag.ADDR`.
* `6` `ret`: Pops `TADR` from `ASR1` (or `ASR0`). Ends if stack empty.
* `7` `end`: Transfer from `TADR + 16`. Ends transfer (`tag_end = true`).

---

### DMAC MFIFO Scratchpad Streaming & Interrupts
* **Memory FIFO (MFIFO)**: Automatically drains data pushed from Scratchpad (`SPR_FROM`) into a circular ring buffer in RDRAM defined by `D_RBSR` (size) and `D_RBOR` (base).
* Either VIF1 or GIF serves as the drain channel, streaming geometry without stalling the EE core during heavy rendering.
* **Interrupt Priority**: `INT0` (INTC) has strict hardware priority over `INT1` (DMAC).

---

## 8. Graphics Synthesizer (GS)

### GS Register Maps
* **Internal Registers (Accessible via GIF A+D or REGLIST)**:
  * `0x00` `PRIM`, `0x01` `RGBAQ`, `0x02` `ST`, `0x03` `UV`, `0x04` `XYZF2`, `0x05` `XYZ2`
  * `0x06` `TEX0_1`, `0x07` `TEX0_2`, `0x08` `CLAMP_1`, `0x09` `CLAMP_2`, `0x0A` `FOG`
  * `0x0C` `XYZF3`, `0x0D` `XYZ3`, `0x14` `TEX1_1`, `0x15` `TEX1_2`, `0x18` `XYOFFSET_1`
  * `0x1A` `PRMODECONT`, `0x1B` `PRMODE`, `0x1C` `TEXCLUT`, `0x3F` `TEXFLUSH`
  * `0x40` `SCISSOR_1`, `0x42` `ALPHA_1`, `0x46` `COLCLAMP`, `0x47` `TEST_1`
  * `0x4C` `FRAME_1`, `0x4E` `ZBUF_1`, `0x50` `BITBLTBUF`, `0x51` `TRXPOS`, `0x52` `TRXREG`, `0x53` `TRXDIR`, `0x54` `HWREG`
* **Privileged Registers (Accessible via EE 64-bit Stores)**:
  * `0x12000000` `PMODE`: PCRTC configuration. Bit 0 = `EN1` (Circuit 1 enable), Bit 1 = `EN2` (Circuit 2 enable). Always set `0xFF65` or `0xFF67`!
  * `0x12000070` `DISPFB1` / `0x12000080` `DISPLAY1`: Buffer pointer, pixel format, and video dimensions for display output 1.
  * `0x12001000` `CSR`: System status, VBLANK interrupt flag, GS reset.
  * `0x12001010` `IMR`: Interrupt mask.

---

### GS Drawing Primitives & Vertex Kick
* **Primitive Types (`PRIM` bits 2:0)**:
  * `0`: Point
  * `1`: Line
  * `2`: LineStrip
  * `3`: Triangle
  * `4`: TriangleStrip
  * `5`: TriangleFan
  * `6`: Sprite (2 vertices: vertex 1 = upper-left, vertex 2 = lower-right)
* **Kicks**:
  * Writing to `XYZ2` or `XYZF2` generates a vertex kick and (if vertex count satisfied) kicks drawing.
  * Writing to `XYZ3` or `XYZF3` generates a vertex kick but suppresses drawing (used for polygon culling).

---

### GS Frame & Z-Buffer Masking
* `FRAME_1/2`: Base pointer in units of 2048 words, buffer width in pixels / 64, color format (`PSMCT32`, `PSMCT24`, `PSMCT16`, `PSMCT16S`).
* **Framebuffer Mask**: Bits 63:32 restrict writeback:
  $$\text{final\_color} = (\text{new\_color} \ \& \ \sim\text{mask}) \mid (\text{frame\_color} \ \& \ \text{mask})$$
* `ZBUF_1/2`: Base pointer in units of 2048 words, Z format (`PSMZ32`, `PSMZ24`, `PSMZ16`). Bit 32 masks Z-buffer updates.

---

### GS VRAM Transfers
* `BITBLTBUF`: Source/Destination base pointers, widths, and formats.
* `TRXPOS`: Source $(X, Y)$ and Destination $(X, Y)$ coordinates.
* `TRXREG`: Transmission width and height in pixels.
* `TRXDIR`: `0` = Host to VRAM (GIF->VRAM), `1` = VRAM to Host, `2` = VRAM to VRAM.

---

### GS Textures, CLUT & Texel Sampling
* Texture formats: `PSMCT32`, `PSMCT24`, `PSMCT16`, `PSMT8` (8-bit paletted, 256 colors), `PSMT4` (4-bit paletted, 16 colors).
* **CLUT Management (`TEX0`)**: Specifies CLUT base pointer, storage format, and cache mode. In CSM2 mode, CLUT entry offset must be 0.
* **`TEXFLUSH` (`0x3F`)**: Must be written to invalidate the GS texture cache whenever new texture data, updated CLUTs, or dynamic render targets are bound.

---

### GS Fog & Alpha Blending

#### Alpha Blending Formula
$$\text{Output} = \left(\frac{(A - B) \times C}{128}\right) + D$$
Values configured via `ALPHA_1/2` register:
* `A`, `B`, `D`: `0` = Source RGB, `1` = Framebuffer RGB, `2` = 0.
* `C`: `0` = Source Alpha, `1` = Framebuffer Alpha, `2` = Fixed Alpha (`FIX`).

#### Fog Formula
$$\text{Output} = \left(\frac{F \times \text{Input}}{256}\right) + \left(\frac{(255 - F) \times \text{FOGCOL}}{256}\right)$$

---

### GS Pixel Tests
`TEST_1/2` manages three pipeline tests:
1. **Alpha Test**: Compares pixel alpha against `AREF` using `NEVER`, `ALWAYS`, `LESS`, `LEQUAL`, `EQUAL`, `GEQUAL`, `GREATER`, `NEQUAL`. Supports 4 failure processing modes (discard all, update frame only, update Z only, update RGB only).
2. **Destination Alpha Test**: Passes if destination alpha bit in framebuffer is 0 or 1.
3. **Depth Test (Z-Test)**: Compares pixel Z against Z-buffer value (`ALWAYS`, `GEQUAL`, `GREATER`).

---

### GS Advanced PS2 Rendering Techniques
* **Fast Screen Draw**: Renders full-screen quads as a grid of 64x32 sprites to maximize eDRAM page-hit rates and prevent horizontal DRAM page breaks.
* **Double Half Clear**: Clears half the screen height with double Z-buffer width to exploit free depth fillrates.
* **Interleaved Clear**: Sets `ZBP = FBP` and clears with 32x32 sprites, interleaving color and depth clears within the same cache lines.
* **VIS Clear**: Stacks framebuffer pages vertically into a 64x2048 or 32x4096 single sprite strip to avoid all horizontal page breaks (*Superman Returns*).
* **Channel Shuffle**: Exploits 32-bit RGBA channels as 8-bit palette indices via 8x2 sprites with `FBMASK` to perform post-processing color grading without shader hardware.

---

## 9. Vector Interface (VIF)

VIF0 and VIF1 unpack compressed geometry data and upload microprograms into VU memory:
* `VIFn_STAT`: VPS status, microprogram execution flag (`VEW`), FIFO counts.
* `VIFn_CYCLE`: Write cycle length (`WL`) and cycle length (`CL`) for sparse data expansion.
* `VIFn_MODE`: Addition decompression mode.
* **UNPACK Matrix**:
  * `S-32`, `S-16`, `S-8`: Scalar expansion to all components $(X, Y, Z, W)$.
  * `V2-32`, `V2-16`, `V2-8`: Vector 2 expansion to $(X, Y)$.
  * `V3-32`, `V3-16`, `V3-8`: Vector 3 expansion to $(X, Y, Z)$.
  * `V4-32`, `V4-16`, `V4-8`, `V4-5`: Full 4-component vector expansion $(X, Y, Z, W)$.

---

## 10. Vector Units (VU0 & VU1)

### VU Architecture & Register Sets
* 32 Vector Floating-Point Registers (`vf00`..`vf31`), each with 4 32-bit float fields: $\{X, Y, Z, W\}$. `vf00` is hardwired to $\{0.0, 0.0, 0.0, 1.0\}$.
* 16 Integer Registers (`vi00`..`vi15`). `vi00` is hardwired to 0.
* Special Registers: `ACC` (Accumulator), `Q` (FDIV result), `P` (EFU result).

### VU Processor Flags
* **MAC Flags (16-bit)**: $\{O_x, O_y, O_z, O_w, U_x, U_y, U_z, U_w, S_x, S_y, S_z, S_w, Z_x, Z_y, Z_z, Z_w\}$. Modified in writeback stage; reading induces a 4-cycle pipeline hazard delay.
* **Clip Flags (24-bit)**: Result of `CLIP` operations ($\pm X, \pm Y, \pm Z$).
* **Status Flags**: Sticky flags (`ZS`, `SS`, `US`, `OS`, `IS`, `DS`) that retain latched conditions until cleared.

### VU Dual-Issue Encoding & Pipeline Latencies
Every 64-bit doubleword instruction issues an upper (FMAC float calculation) and lower (integer / branch / memory) instruction simultaneously.
* **Upper Control Bits**:
  * `I-bit`: Loads immediate into `I` register from lower word.
  * `E-bit`: End of microprogram execution (takes effect after branch delay slot).
  * `M-bit`: Ends VU0 interlock for EE core synchronization.
  * `D-bit` / `T-bit`: Debug breaks and halts.
* **Latencies**:
  * FMAC operations: 4 cycles (RAW hazard induces up to 3 stall cycles).
  * Integer operations: 1 cycle (hardware bypass).
  * `DIV` / `SQRT`: 7 cycles latency (stalls entire VU if another FDIV instruction issued).
  * `RSQRT`: 13 cycles latency.
  * EFU operations (VU1 only): `ESIN` (29 cycles), `EEXP` (44 cycles), `EATAN` (54 cycles).

---

## 11. Image Processing Unit (IPU)

Dedicated hardware macroblock decoder for MPEG-1 and MPEG-2 bitstreams:
* `IPU_CMD` (`0x10002000`): Dispatches decoding operations:
  * `0x0` `BCLR`: Clears input FIFO and sets bitstream pointer.
  * `0x1` `IDEC`: Decodes MPEG slice.
  * `0x2` `BDEC`: Decodes macroblock.
  * `0x3` `VDEC`: Variable-length decoding (VLC).
  * `0x4` `FDEC`: Fixed-length decoding.
  * `0x7` `CSC`: Color-space conversion (YUV to RGB32/RGB16).
  * `0x8` `PACK`: 32-bit to 16-bit or 4-bit color packing.
* DMA streaming: Input fed through `IPU_TO` (Ch 4); output pulled via `IPU_FROM` (Ch 3).

---

## 12. EE Interrupt Controller (INTC)

Manages `INT0` signals delivered to the EE core (`COP0.Cause` bit 10):
* `0x1000F000` `INTC_STAT`: Status (1 = IRQ active; write 1 to clear).
* `0x1000F010` `INTC_MASK`: Mask (Write 1 to toggle enable).
* **IRQ Lines**:
  * `0`: GS Interrupt
  * `1`: SBUS (IOP communication)
  * `2`: VBLANK Start
  * `3`: VBLANK End
  * `4`: VIF0
  * `5`: VIF1
  * `6`: VU0
  * `7`: VU1
  * `8`: IPU
  * `9`: Timer 0
  * `10`: Timer 1
  * `11`: Timer 2
  * `12`: Timer 3
  * `13`: SFIFO
  * `14`: VU0 Watchdog

---

## 13. IOP Hardware and Peripherals

### CDVD Optical Drive

#### Hardware I/O Ports
* `0x1F402004`: Current N Command (R/W).
* `0x1F402005`: N Command Status (R) / Parameter FIFO (W). CDVDMAN verifies bit 6=1 (Ready) and bit 7=0 (Idle).
* `0x1F402006`: Error code.
* `0x1F402007`: Send `BREAK` command.
* `0x1F402008`: `CDVD I_STAT` (Interrupt status / acknowledge).
* `0x1F40200A`: Drive status (Tray open, spindle spinning, reading, paused, seeking, error).
* `0x1F40200F`: Disc type detection:
  * `0x00`: No disc
  * `0x01`: Detecting
  * `0x10`: PSX CD
  * `0x11`: PSX CDDA
  * `0x12`: PS2 CD
  * `0x13`: PS2 CDDA
  * `0x14`: PS2 DVD
  * `0xFD`: CD-DA Music Disc
  * `0xFE`: DVD-Video Disc
  * `0xFF`: Illegal Disc
* `0x1F402016`: Current S Command.
* `0x1F402017`: S Command Status (R) / Parameter FIFO (W).
* `0x1F402018`: S Command Result FIFO.

#### N Commands (Asynchronous Optical Commands)
* `0x02` `Standby`: Sets read position to sector 0 and pauses drive.
* `0x03` `Stop`: Returns read head to lead-in and stops spindle.
* `0x04` `Pause`: Pauses playback / read streaming.
* `0x05` `Seek`: Seeks optical pickup to 32-bit sector position.
* `0x06` `ReadCd`: Reads CD sectors (block size: `1` = 2328 bytes, `2` = 2340 bytes, default = 2048 bytes).
* `0x08` `ReadDvd`: Reads DVD sectors (2064-byte blocks with headers).
* `0x09` `GetToc`: Reads Table of Contents into memory.

#### Optical Read & Seek Timings
* Spindle spin-up latency: 333 ms.
* Fast seek ($\Delta < 4371$ CD sectors): ~30 ms. Full seek: ~100 ms.
* Sector timing:
  $$\text{block\_timing} = \frac{\text{IOP\_CLOCK} \times \text{block\_size}}{\text{read\_speed}}$$
  where $\text{IOP\_CLOCK} = 36,864,000 \text{ Hz}$, CD 24x speed = $24 \times 153,600 \text{ B/s}$.

---

### Sound Processing Unit 2 (SPU2 & AutoDMA)

* **Memory**: 2 MB Sound RAM.
* **AutoDMA (`SPU_ADMA_CTRL` `0x1F9001B0`)**: Streams raw 16-bit signed stereo PCM audio directly into SPU2 work RAM without compression, bypassing ADPCM voice logic.
* **`MEMIN` Double Buffering**:
  * Core 0 Left: `0x2000` (Buffer 0), `0x2100` (Buffer 1).
  * Core 0 Right: `0x2200` (Buffer 0), `0x2300` (Buffer 1).
  * Core 1 Left: `0x2400` (Buffer 0), `0x2500` (Buffer 1).
  * Core 1 Right: `0x2600` (Buffer 0), `0x2700` (Buffer 1).
  * Total block size = 1024 bytes (512 bytes Left + 512 bytes Right).
* **Voice Pitch Calculation**:
  $$\text{Pitch Register} = \frac{\text{Sample Rate} \times 4096}{48000}$$
* **Hardware ADPCM Flags (Byte 1 of 16-byte block)**:
  * `0x00`: One-shot intermediate.
  * `0x02`: Loop Repeat / Envelope Sustain (Must be set on all continuous blocks).
  * `0x06`: Loop Start (`0x04 | 0x02`).
  * `0x03`: Loop End (`0x01 | 0x02`).
  * `0x01`: One-shot end (Triggers release and mute).

---

### Serial Interface (SIO2, Controllers, Memory Cards)

#### SIO2 Communication Flow
1. Write `CTRL | 0x0C` to `SIO2_CTRL`.
2. Populate `SEND1` / `SEND2` and command headers into `SEND3`.
3. Write payload data to `FIFOIN` and trigger SIO2 DMA.
4. Set bit 0 in `SIO2_CTRL` to execute. Wait for SIO2 interrupt.
5. Inspect `RECV1` (`0x1100` = Connected, `0x1D100` = Disconnected).

#### DualShock 2 Packet Protocol (Command `0x42`)
* Header: `0x01`, `0x42`, `0x00`.
* Reply Byte 1: Mode (`0x41` = Digital, `0x73` = Analog, `0x79` = DualShock 2 with pressure).
* Byte 3-4: Digital buttons (Active Low, 0 = Pressed, 1 = Released):
  * Select, L3, R3, Start, Up, Right, Down, Left, L2, R2, L1, R1, Triangle, Circle, Cross, Square.
* Bytes 5-8: Analog sticks ($RX, RY, LX, LY \in [0, 255]$, centered at 128).
* Bytes 9-20: 12-byte analog pressure values ($0 = \text{no pressure}, 255 = \text{max pressure}$) for Right, Left, Up, Down, Triangle, Circle, Cross, Square, L1, R1, L2, R2.

#### Memory Card Superblock Layout
First page (page 0) of card:
* Bytes 0-27: `"Sony PS2 Memory Card Format "`
* Bytes 28-39: Version (`"1.2.0.0"`)
* Bytes 40-41: Page size (512 bytes)
* Bytes 42-43: Pages per cluster (2)
* Bytes 44-45: Pages per erase block (16)
* Bytes 48-51: Total clusters (8,192 for 8 MB card)
* Bytes 80-207: Indirect FAT cluster table
* Bytes 208-335: Bad block table

---

### IOP Interrupts & DMA

* `0x1F801070` `I_STAT`: Interrupt status (Bit 0 = VBLANK Start, Bit 2 = CDVD, Bit 3 = DMA, Bit 9 = SPU2, Bit 17 = SIO2).
* `0x1F801074` `I_MASK`: Interrupt enable mask.
* `0x1F801078` `I_CTRL`: Global interrupt enable (Read returns and clears bit 0).
* **IOP DMA Channels**:
  * Ch 0/1: MDEC in/out
  * Ch 2: SIF2 (GPU in PS1 mode)
  * Ch 3: CDVD
  * Ch 4: SPU2 Core 0
  * Ch 7: SPU2 Core 1
  * Ch 8: DEV9
  * Ch 9: SIF0 (IOP to EE via TADR)
  * Ch 10: SIF1 (EE to IOP)
  * Ch 11/12: SIO2 in/out

---

### IOP Timers & Console Hooks
* Timers 0..2 are 16-bit; Timers 3..5 are 32-bit.
* **Console TTY Output Hooks**: PCSX2 and emulators trap IOP console strings by monitoring PC addresses `0x12C48`, `0x1420C`, and `0x1430C` where `$a1` holds string pointer and `$a2` holds length.

---

## 14. Subsystem Interface (SIF)

### SIF Hardware Registers & Mailboxes
* `SIF_MSCOM` (`EE: 0x1000F200` / `IOP: 0x1D000000`): Written by EE to pass its SIF0 DMA receive address.
* `SIF_SMCOM` (`EE: 0x1000F210` / `IOP: 0x1D000010`): Written by IOP to pass its SIF1 DMA receive address.
* `SIF_MSFLAG` / `SIF_SMFLAG`: Handshake flags:
  * `0x10000`: SIF hardware initialized.
  * `0x20000`: SIFCMD protocol active.
  * `0x40000`: IOP kernel boot completed (`EESYNC`).

---

### SIF RPC Architecture & Packet Protocol
The SIF communication stack operates across three tiers:
1. **SIF DMA**: Physical quadword transfer across FIFOs (`SIF0` and `SIF1`).
2. **SIF CMD**: Packet protocol handling command dispatch and interrupt callbacks.
3. **SIF RPC**: High-level synchronous / asynchronous Remote Procedure Call client-server model (`SifBindRpc`, `SifCallRpc`).

#### SIF RPC Commands:
* `0x80000000` `Change SADDR`: Reconfigures receive buffer.
* `0x80000001` `Set SREG`: Sets software handshake register.
* `0x80000002` `SIFCMD Init`: Initializes protocol buffers.
* `0x80000003` `Reboot IOP`: Sends reset string (e.g., `"rom0:UDNL cdrom0:\\MODULES\\IOPRP243.IMG;1"`).
* `0x80000008` `Request End`: Signals RPC completion.
* `0x80000009` `Bind`: Binds client to server ID.
* `0x8000000A` `Call`: Invokes remote server function with payload buffer.

---

### SIF Standard System Servers
* `0x80000001`: `FILEIO` (File operations)
* `0x80000003`: `FILEIO` (IOP Heap Allocation)
* `0x80000006`: `LOADFILE` (ELF and IRX module loader)
* `0x80000100`: `PADMAN` (Controller driver)
* `0x80000400`: `MCSERV` (Memory card operations)
* `0x80000592`: `CDVDFSV` (CDVD initialization)
* `0x80000593`: `CDVDFSV` (CDVD synchronous S commands)
* `0x80000595`: `CDVDFSV` (CDVD asynchronous N commands)
* `0x80000597`: `CDVDFSV` (SearchFile)
* `0x8000059A`: `CDVDFSV` (Disk Ready check)
* `0x80000701`: `SDRDRV` (LIBSD Remote sound driver)

---

## 15. BIOS & Operating System Architecture

### BIOS ROMDIR Filesystem Structure
The 4 MB BIOS ROM (`rom0`) is indexed by a flat `ROMDIR` table starting at the `"RESET"` symbol:
```c
struct romdir_entry {
    char name[10];           // Null-terminated file name
    unsigned short ext_info; // Size of extended info in EXTINFO
    unsigned int file_size;  // File size in bytes
};
```

---

### BIOS EE/IOP Boot Flow
1. Both EE and IOP start at reset vector `0xBFC00000`.
2. CPU checks `COP0.PRid`: if $\ge \text{0x59}$, CPU is EE; otherwise IOP.
3. **EE Path**: Calibrates CPU clock, initializes memory controller (`MCH_DRD`/`RICM`), clears TLB, loads EE kernel to `0x80000000`, establishes `EENULL` idle thread at `0x00081FC0`, initializes SIF DMA, and invokes `EELOAD` $\rightarrow$ `OSDSYS`.
4. **IOP Path**: Initializes hardware peripherals, loads `IOPBOOT`, parses `IOPBTCONF`, boots `SYSMEM` and `LOADCORE`, loads all system IRX modules, and establishes SIF listener loop.

---

### BIOS EE Threading & Cooperative Scheduler
* Supports up to 256 threads, 256 semaphores, and 128 priority levels (`0` = highest).
* **Scheduling**: Invoked strictly via syscalls. Rescheduling scans the priority linked list from level 0 upwards and dispatches the first `READY` thread.
* **Context Structure**: User thread context saves 32 128-bit GPRs, 32 32-bit FPRs, `SA`, `FCR31`, `HI`/`LO`, `HI1`/`LO1`, and `PC`.

---

### BIOS EE Syscall Table

| Syscall | Function Signature | Description |
|:---|:---|:---|
| `0x01` | `void ResetEE(int reset_flags)` | Resets DMAC, VU0/1, VIF0/1, GIF, IPU |
| `0x02` | `void SetGsCrt(bool interlace, int mode, bool frame)` | Configures PCRTC video display |
| `0x04` | `void Exit(int status)` | Exits to OSDSYS browser |
| `0x06` | `void LoadExecPS2(char* path, int argc, char** argv)` | Destroys state and loads new ELF |
| `0x07` | `void ExecPS2(void* entry, void* gp, int argc, char** argv)` | Spawns priority 0 thread at entry |
| `0x10` | `int AddIntcHandler(int cause, int (*fn)(int), int next, void* arg, int flag)` | Registers `INT0` interrupt handler |
| `0x11` | `int RemoveIntcHandler(int cause, int handler_id)` | Removes `INT0` handler |
| `0x12` | `int AddDmacHandler(int channel, int (*fn)(int), int next, void* arg, int flag)`| Registers `INT1` DMAC handler |
| `0x13` | `int RemoveDmacHandler(int channel, int handler_id)` | Removes `INT1` handler |
| `0x14` | `bool _EnableIntc(int bit)` | Enables INTC interrupt line |
| `0x15` | `bool _DisableIntc(int bit)` | Disables INTC interrupt line |
| `0x16` | `bool _EnableDmac(int bit)` | Enables DMAC channel interrupt |
| `0x17` | `bool _DisableDmac(int bit)` | Disables DMAC channel interrupt |
| `0x20` | `int CreateThread(ThreadParam* t)` | Allocates thread in `DORMANT` state |
| `0x21` | `void DeleteThread(int tid)` | Frees dormant thread |
| `0x22` | `void StartThread(int tid, void* arg)` | Transitions thread to `READY` & reschedules |
| `0x23` | `void ExitThread()` | Removes current thread and reschedules |
| `0x24` | `void ExitDeleteThread()` | Deletes current thread and reschedules |
| `0x25` | `void TerminateThread(int tid)` | Forces thread into `DORMANT` state |
| `0x29` | `int ChangeThreadPriority(int tid, int prio)` | Modifies thread priority and reschedules |
| `0x2B` | `void RotateThreadReadyQueue(int prio)` | Round-robin rotates priority queue |
| `0x2D` | `void ReleaseWaitThread(int tid)` | Wakes thread from semaphore wait state |
| `0x2F` | `int GetThreadId()` | Returns caller's thread ID |
| `0x32` | `void SleepThread()` | Puts caller into `WAIT` state |
| `0x33` | `void WakeupThread(int tid)` | Wakes sleeping thread |
| `0x40` | `int CreateSema(SemaParam* s)` | Creates synchronization semaphore |
| `0x41` | `int DeleteSema(int sid)` | Deletes semaphore and wakes waiters |
| `0x42` | `int SignalSema(int sid)` | Increments semaphore count or wakes thread |
| `0x44` | `void WaitSema(int sid)` | Decrements semaphore or puts thread to `WAIT` |
| `0x45` | `int PollSema(int sid)` | Non-blocking semaphore test |
| `0x64` | `void FlushCache(int mode)` | `0` = Writeback D-cache; `1` = Invalidate D-cache; `2` = Invalidate I-cache |
| `0x70` | `uint64_t GsGetIMR()` | Reads GS `IMR` privileged register |
| `0x71` | `void GsPutIMR(uint64_t val)` | Writes GS `IMR` privileged register |
| `0x73` | `void SetVSyncFlag(int* flag, u64* csr)` | Registers VSYNC status hooks |
| `0x74` | `void SetSyscall(int index, void* handler)` | Overwrites kernel syscall dispatch table entry |
| `0x76` | `int SifDmaStat(unsigned int id)` | Polls SIF DMA completion status |
| `0x77` | `unsigned int SifSetDma(SifDmaTransfer* t, int len)` | Dispatches low-level SIF1 DMA transfer |
| `0x78` | `void SifSetDChain()` | Initializes SIF0 chain mode |
| `0x7F` | `int GetMemorySize()` | Returns total installed RDRAM in bytes |

---

### BIOS PlayStation 1 Backward Compatibility

* **EE Emulation Loop (`PS1DRV`)**: The Emotion Engine executes `PS1DRV` which acts as a software translation layer, intercepting PS1 GPU commands from the PGIF registers and rasterizing them onto the Graphics Synthesizer.
* **IOP Hardware Downgrade**:
  * IOP core underclocked from 36.864 MHz to **33.8688 MHz**.
  * SPU2 outputs audio at **44.1 kHz** instead of 48.0 kHz.
  * SPU2 register map translated back to `0x1F801C00`.
* **Timing & Compatibility Hacks**:
  * `Render Polygon Delay` / `Render Rectangle Delay`: Artificial spinloops to match slower PS1 GPU fillrates.
  * `Force CDROM Speed`: Locks drive speed to 1x or 2x for sensitive streaming titles.
  * `VBLANK Delay`: Expands scanline count to widen VBLANK intervals.

---

### BIOS IOP Dynamic Module Linking

IOP device drivers are compiled as relocatable ELF executables (`.irx`). Modules publish services via **Export Tables** and consume services via **Import Tables**:

```c
struct export_table {
    unsigned int magic;        // Must equal 0x41C00000
    struct export_table* next; // Managed by LOADCORE
    unsigned short version;    // e.g., 0x0102 for v1.02
    unsigned short mode;
    char name[8];              // Module name (null-terminated)
    void* exports[0];          // Function pointer jump table
};

struct import_table {
    unsigned int magic;        // Must equal 0x41E00000
    struct import_table* next;
    unsigned short version;
    unsigned short mode;
    char name[8];
    void* imports[0];          // Pairs of: jr $ra; addiu $zero, $zero, X
};
```

* **LOADCORE Linking Mechanism**: When a module is loaded, `LOADCORE` matches its import tables against registered export tables. It reads the function index $X$ from `addiu $zero, $zero, X` and overwrites the preceding `jr $ra` with a direct jump (`j <export_address>`), eliminating call overhead without exposing ASCII symbol names in production binaries.

---

### BIOS Core IOP Modules Reference

1. **`IOPBOOT`**: Raw binary bootstrap located at `0xBFC4A000` (SCPH-39001). Reads `IOPBTCONF`, initializes base RAM, loads `SYSMEM` and `LOADCORE`.
2. **`SYSMEM`**: Kernel heap allocator managing memory as linked lists of 256-byte aligned blocks (`AllocSysMemory`, `FreeSysMemory`).
3. **`LOADCORE`**: Dynamic module linker and ELF loader (`RegisterLibraryEntries`, `FlushIcache`, `FlushDcache`).
4. **`EXCEPMAN`**: Hardware exception vector dispatcher (`RegisterExceptionHandler`).
5. **`INTRMAN`**: Hardware interrupt management (`RegisterIntrHandler`, `EnableIntr`, `CpuDisableIntr`).
6. **`SSBUSC`**: Subsystem bus controller programming timings for external devices, DEV9, and ROM.
7. **`DMACMAN`**: Programming interface for the 13 IOP DMA channels (`DmaRequestTransfer`, `DmaStartTransfer`).
8. **`TIMRMAN`**: Hardware timer manager allocating and configuring Timers 0..5 (`AllocHardTimer`, `SetTimerMode`).
9. **`SYSCLIB`**: Standard C runtime functions (`memcpy`, `strcmp`, `sprintf`, `setjmp`).
10. **`HEAPLIB`**: Variable-sized heap allocation library (`CreateHeap`, `AllocHeapMemory`).
11. **`THREADMAN`**:
    * `THBASE`: Thread management (`CreateThread`, `StartThread`, `SleepThread`, `WakeupThread`).
    * `THEVENT`: 32-bit Event Flags (`CreateEventFlag`, `SetEventFlag`, `WaitEventFlag`).
    * `THSEMAP`: Counting Semaphores (`CreateSema`, `SignalSema`, `WaitSema`).
    * `THMSGBX`: Inter-thread message queues (`CreateMbx`, `SendMbx`, `ReceiveMbx`).
    * `THFPOOL` / `THVPOOL`: Fixed and variable-size memory allocation pools.
12. **`VBLANK`**: Vertical blank interrupt manager (`WaitVblankStart`, `RegisterVblankHandler`).
13. **`IOMAN`**: Standard POSIX-like file descriptor abstraction (`open`, `read`, `write`, `close`, `lseek`, `ioctl`, `AddDrv`).
14. **`MODLOAD`**: Kernel module loader (`LoadStartModule`, `LoadModuleBufferAddress`, `ReBootStart`).
15. **`ROMDRV`**: Device driver mapping `rom0:` and `rom1:` ROM filesystems into `IOMAN`.
16. **`STDIO`**: Standard I/O formatting and terminal redirection (`printf`, `puts`, `fdprintf`).
17. **`SIFMAN`**: Low-level DMA buffer driver for SIF0/SIF1 (`sceSifSetDma`, `sceSifDmaStat`).
18. **`SIFCMD`**: Remote Procedure Call and packet command dispatcher (`sceSifRegisterRpc`, `sceSifCallRpc`, `sceSifBindRpc`).
19. **`CDVDMAN` / `CDVDFSV`**: Optical drive hardware manager and SIF RPC server handling disc reads, seeks, and media detection.
20. **`PADMAN` / `SIO2MAN`**: DualShock controller communication driver and SIO2 serial port arbiter.
21. **`LIBSD`**: Low-level sound library driving SPU2 voices, Core attributes, pitch, and AutoDMA transfers.
