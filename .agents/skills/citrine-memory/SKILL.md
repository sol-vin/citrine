---
name: citrine-memory
description: Expert guide for PlayStation 2 memory safety, the 4-tier hybrid console memory architecture, scratchpad RAM usage, canary auditing, leak detection with citrine mem-check, and dynamic debugging with radare2. Use when diagnosing memory leaks, tracking allocations, auditing SPRAM buffers, or fixing use-after-free bugs.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: embedded-systems
  triggers: PS2 memory, scratch pool, make_vm_context, Pointer.malloc, Pointer.free, citrine mem-check, SPRAM canary, 0xDEADBEEF, mark-sweep, leak audit
  role: specialist
  scope: implementation
  output-format: code
  related-skills: citrine-vm, ps2-dev, pcsx2-cli, r2-ps2-debug
---

# Citrine PlayStation 2 Memory Architecture & Safety Guide

Specialist guide for Citrine's 4-tier console memory architecture, leak prevention, and automated memory verification on the PlayStation 2 Emotion Engine.

## The 4-Tier Hybrid Memory Architecture

Citrine eliminates desktop stop-the-world GC pauses on the PS2's 32 MB RAM through a deterministic 4-tier model:

```text
┌─────────────────────────────────────────────────────────────┐
│ 1. Per-Frame Scratch Pool (Ring Buffer, 256 KB @ 0x00400000)│
│    - All short-lived strings, math temps, format buffers.   │
│    - Reset at V-Blank (EndDrawing) in O(1) time. Zero leaks.│
├─────────────────────────────────────────────────────────────┤
│ 2. VM Context Arenas (Scene / Mode Pools, 2–8 MB)           │
│    - make_vm_context(:menu) / make_vm_context(:gameplay)    │
│    - Entire arena wiped in O(1) upon exiting the context.   │
├─────────────────────────────────────────────────────────────┤
│ 3. Explicit Pointer Deallocation (Pointer.free / RAII)      │
│    - Long-lived textures, audio buffers, meshes, and VRAM.  │
│    - Deterministic lifecycle with 8-byte aligned free-list. │
├─────────────────────────────────────────────────────────────┤
│ 4. Idle V-Blank Mark-Sweep (Optional Fallback Safety Net)   │
│    - Runs only during idle VSync wait (when CPU waits on GS)│
│    - Cleans up long-lived cyclic objects with 0 frame drops.│
└─────────────────────────────────────────────────────────────┘
```

## Tier Rules & Allocation Lifecycles

### Tier 1: Per-Frame Scratch Pool
- **Base Address**: `0x00400000`
- **Reclaimed**: Every V-Blank (`Citrine.begin_drawing` / `Citrine.end_drawing`).
- **Allocations**:
  - String interpolation (`"Score: #{score}"`)
  - All `struct` instances
  - Vector math temporaries
- **Cost**: 2 CPU cycles; zero fragmentation; zero leaks.

### Tier 2: VM Context Arenas
- **Syntax**: `Citrine.make_vm_context(:level_1) { ... }`
- **Reclaimed**: When exiting the block, or calling `NativeId::ContextClear`.
- **Allocations**:
  - Level entities and game-state collections.
  - Scene-specific state machines.

### Tier 3: Explicit Pointers
- **Syntax**: `ptr = Pointer(UInt32).malloc(256)`, `ptr.free`
- **Recycling**: Blocks freed with `ptr.free` are inserted into an 8-byte aligned free-list.
- **Safety**: Debug supervisor logs use-after-free reads and writes:
  `[CITRINE MEMORY ERROR] Use-after-free: read from freed object at 0x...`

### Tier 4: Idle V-Blank Mark-Sweep
- **Trigger**: `NativeId::GCCycle` (185) during VSync raster wait (4–8 ms).
- **Semantics**: Conservative root scanning over registers `$r0..$r255`. Unreferenced objects are moved to the Tier 3 free-list.

## SPRAM Canary Protection

- **Virtual Address**: `0x70000000`
- **Canary Value**: `0xDEADBEEF`
- **Verification**: Supervised every frame at V-Blank. If any stack or buffer overrun corrupts the canary, execution halts with a hardware panic.

## Automated Leak Auditing & Debugging

### Command-Line Memory Audit
```bash
citrine mem-check build/game.cbc
```
Verifies:
1. SPRAM Canary integrity (`0xDEADBEEF`).
2. Scratch pool rewind at V-Blank.
3. Zero unclosed allocations in Context Arenas.
4. No double-free or use-after-free pointer violations.

### Dynamic radare2 Inspection
```bash
# Attach r2 to PCSX2 GDB stub on port 28011
citrine debug build/game.cbc --port 28011
```
Useful radare2 commands:
```text
[0x00100000]> px 64 @ 0x70000000     # Audit SPRAM Canary (must be 0xDEADBEEF)
[0x00100000]> dm                     # Display EE virtual memory layout
[0x00100000]> dr                     # View Emotion Engine MIPS GPRs
```

---

## Detailed References

| Topic | Reference | Content |
|:---|:---|:---|
| PS2 Memory Alignment & Forensics | [heap-alignment-forensics.md](./references/heap-alignment-forensics.md) | 16-byte/64-byte/128-byte hardware alignment, uncached memory acceleration (`0x30000000`), allocator canary validation |

---

## Mandatory Constraints & Rules

- **Use Uncached Accelerated Addresses for DMA Staging**: Always route GIF/VIF DMA buffer pointers through KUSEG Uncached Accelerated (`0x30000000 | addr`) to eliminate D-cache flush overhead and prevent stale DRAM reads.
- **Enforce 16-byte Quadword Alignment**: All heap chunks that interact with MMI instructions (`lq`/`sq`) or DMAC channels must be aligned to 16 bytes.
- **Audit SPRAM Canary Every V-Blank**: Never allow stack frames or local scratch buffers to spill past `0x70003FF0`. Canary at `0x70000000` must remain `0xDEADBEEF`.

