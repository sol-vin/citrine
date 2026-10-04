# PCSX2 vs Real PlayStation 2 Hardware Discrepancies & Traps

Guide for identifying emulator illusions, false-positive test passes, and subtle behavioral divergence between PCSX2 and physical PS2 hardware.

---

## 1. Emulator False-Positive Matrix

| Phenomenon | PCSX2 Emulator Behavior | Physical Hardware Reality | Detection / Diagnostic |
|:---|:---|:---|:---|
| **Misaligned Memory Access** | Silently performs unaligned word/quadword access without error. | MIPS R5900 raises **Address Error Exception** (Level 1 Trap), immediately crashing the process. | Audit all pointer casts; run `citrine mem-check`; enforce `alignas(16)` on quadwords. |
| **D-Cache Coherency & DMA** | Host memory is unified; DMA reads CPU stores immediately even if D-cache was not flushed. | DMA controller bypasses L1 D-Cache; reads **stale DRAM values**, causing corrupt rendering or packet parse hangs. | Always call `SyncDCache` or allocate DMA buffers in uncached memory (`0x20000000` / `0x30000000`). |
| **Uninitialized Memory** | Host OS or emulator memory may be zero-filled or predictable. | Main RAM contains random noise or boot residue; uninitialized registers contain garbage. | Explicitly zero memory structures; audit with `memset`. |
| **CLUT Palette Swizzle** | In certain renderer backends, linear palettes may be auto-corrected or masked by bilinear filtering. | Unswizzled 8-bit CSM1 palettes display **severely distorted intermediate color bands**. | Test in software renderer (`GSdx -renderer 11`) and verify swizzle math. |
| **DMA Completion Timing** | DMA often completes in 0 simulated cycles or in a single thread tick. | Real DMA takes thousands of bus cycles; modifying buffers mid-transfer causes tearing or crash. | Wait on DMA channel completion bit (`D2_CHCR.STR == 0`) before touching buffer memory. |
| **Interlaced Video Output** | Host display progressive scan converts FIELD mode without scanline flickering. | Physical CRT displays alternate odd/even fields; 1-pixel high lines flicker noticeably without anti-flicker filter. | Use half-pixel vertical offsets or 576p/480p progressive mode where applicable. |

---

## 2. Emulog.txt Diagnostic Signatures

Watch for these warning signatures in `$HOME\Documents\PCSX2\logs\emulog.txt`:

### DMA & GIF Warnings
```text
GIF: Unknown PACKED mode format ...
-> Indicates missing EOP (End-Of-Packet) flag on preceding GIFTag or invalid NLOOP count.
```
```text
DMAC: Channel 2 transfer stalled / FIFO full
-> Indicates GS is blocked waiting for primitive vertex data or invalid register address in PACKED A+D mode.
```

### Video CRTC Mode Mismatches
```text
Set GS CRTC configuration. NTSC 640x448 @ 59.940 Interlaced (FIELD)
-> Confirm resolution and refresh rate match expected video standard.
```

### IOP / SIF RPC Stalls
```text
SIF: RPC bind timeout on client ...
-> Indicates IOP IRX module failed to load or SIF RPC server crashed on IOP core.
```

---

## 3. Strict Emulation Verification Protocol

When validating PS2 code prior to hardware deployment:
1. **Run in Software Renderer Mode**:
   - Software rendering in PCSX2 emulates the GS rasterizer at cycle accuracy and reveals palette or Z-buffer errors masked by Vulkan/Direct3D upscaling.
2. **Enable EE Exception Traps**:
   - In PCSX2 advanced EE settings, ensure EE FPU / Bus exceptions are not masked.
3. **Verify Static Allocations**:
   - Verify that all DMA structures are aligned to 16 bytes (quadwords) and all SIF RPC buffers to 64 bytes.
