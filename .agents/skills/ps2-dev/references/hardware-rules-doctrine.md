# PlayStation 2 Engineering Doctrine: Hardware Contracts & Failure Modes

Synthesized from real-world PS2 commercial porting scar tissue and the *Ninja Dynamics Lessons Learned Handbook*. Essential rules for writing code that runs correctly on real hardware and avoids emulator illusions.

---

## 1. The Real-Hardware Mental Model

The PS2 is not a unified computer; it is a **loosely coupled cluster of asymmetric processors connected by direct buses and DMA channels**:
- **Emotion Engine (EE)**: Fast dual-issue 294 MHz MIPS R5900 with 128-bit SIMD, but poor cache miss latency and zero branch prediction.
- **I/O Processor (IOP)**: 36 MHz MIPS R3000 controlling optical drive, memory cards, pads, and sound.
- **Graphics Synthesizer (GS)**: Pure parallel rasterizer with 4 MB eDRAM; zero transformation hardware, no programmable pixel shaders.
- **Vector Units (VU0 & VU1)**: The true PS2 GPU. VU1 must do all 3D matrix transforms, vertex lighting, and polygon clipping.

---

## 2. Hardware vs Emulator (PCSX2) Traps

| Area | Real Hardware Reality | PCSX2 Emulator Illusion | Safe Engineering Rule |
|:---|:---|:---|:---|
| **Memory Alignment** | Misaligned `lw`, `sw`, `lq`, `sq` causes instant **Address Error Bus Exception**. | PCSX2 silently splits unaligned accesses and continues running. | Always enforce 4-byte alignment for words, 16-byte alignment for quadwords, and 64-byte alignment for DMA buffers. |
| **Data Cache (D-Cache)** | EE Core writes to write-back D-cache. DMA reads physical RAM. Real EE transmits **stale RAM data** unless cache is flushed! | PCSX2 shares host process memory directly; DMA sees CPU writes immediately without flushing. | **Always call `SyncDCache`** or write through uncached memory (`0x20000000` / `0x30000000`) before starting any DMA transfer. |
| **CLUT Palette Swizzle** | Unswizzled 8-bit texture palettes in CSM1 display corrupted colors. | Software renderer or auto-fixes in PCSX2 may mask incorrect CLUT indexing. | Verify palette swizzle bit twiddling on hardware or with strict GS dump validation. |
| **Raster Depth Precision** | GS uses integer 24-bit/16-bit Z with fixed subpixel precision. Coplanar geometry produces severe Z-fighting. | High-precision floating point depth buffers in hardware backends may hide coplanar artifacts. | Add explicit Z-bias or disable Z-write (`ZTE=0`) for coplanar overlays, decals, and HUD quads. |
| **DMA Completion Timing** | DMA transfers take real bus cycles. Overwriting buffers while DMA is active produces screen tearing or corruption. | Fast-boot or single-threaded emulation may finish DMA transfers instantaneously. | Always wait on channel completion (`D2_CHCR.STR == 0` or wait for interrupt) before reusing buffer memory. |

---

## 3. DMA Ownership & Publication Doctrine (Handbook Ch. 30)

Every byte transferred to hardware passes through three strict lifecycle phases:
1. **Construction**: CPU/compiler writes packet data into buffer memory. The buffer is owned exclusively by the producer.
2. **Publication**: CPU flushes D-cache (`SyncDCache`) and starts the DMA transfer (`CHCR.STR = 1`). Ownership transfers entirely to the hardware DMA controller. **The CPU must not touch, modify, or deallocate this buffer.**
3. **Completion**: DMA controller fires interrupt or clears `STR` bit. Ownership returns to the CPU.

> [!CRITICAL]
> **Drain Before Teardown**:
> Never tear down or reallocate a GS framebuffer, texture page, or display list while the previous draw or display kick is still in flight. Drain the pipeline first (`D_STAT` wait or `FLUSHA`).

---

## 4. Memory Alignment as an Asset Wire Format (Handbook Ch. 34)

Memory alignment is not an optimization; it is a **wire protocol contract**:
- **16-byte Quadword Alignment**: Mandatory for all EE `LQ`/`SQ` instructions, GIF DMA packets, and VIF unpack buffers.
- **64-byte Cache Line Alignment**: Mandatory for IOP SIF RPC buffers, sound ring buffers, and DMA burst streams to prevent cache evictions and false sharing.
- **128-byte Alignment**: Recommended for ping-pong double buffers to isolate CPU cache lines completely from DMA read channels.

---

## 5. Heap Forensics & Allocator Defense (Handbook Ch. 24)

When memory corruption occurs, the crash almost never happens at the site of the bug; it crashes later inside `malloc`, `free`, or a virtual table dispatch.

### Allocator Validation Protocol
1. **Turn the Walker into a Validator**:
   - Every free-list operation should walk the chunk boundary canaries (`0xDEADBEEF`).
   - If any chunk header has a corrupted size or pointer, halt immediately with an informative register and address dump.
2. **Zero-Tolerance for Padding Hacks**:
   - Never add "safety padding" to fix a mysterious memory crash. Padding simply moves the overwrite to a different, harder-to-find victim. Track down the out-of-bounds index or stack overflow.
3. **Canary Guarding**:
   - Guard SPRAM (`0x70000000`) and arena boundaries with verifiable canary constants checked at every V-Blank.
