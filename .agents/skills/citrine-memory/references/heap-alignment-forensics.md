# Citrine PS2 Memory Alignment, DMA Coherency & Heap Forensics

Comprehensive guide to PlayStation 2 memory alignment boundaries, uncached memory acceleration, and allocator heap forensics for preventing and isolating silent corruptions.

---

## 1. Hardware Memory Alignment Matrix

Every data structure in Citrine's PS2 runtime must respect the physical constraints of the Emotion Engine and its DMA controllers:

| Hardware Domain | Minimum Alignment | Hardware Consequence If Violated |
|:---|:---|:---|
| **CPU Word Access (`lw`, `sw`)** | **4 bytes** | Address Error Exception (immediate crash) |
| **CPU Doubleword (`ld`, `sd`)** | **8 bytes** | Address Error Exception (immediate crash) |
| **MMI Quadword (`lq`, `sq`)** | **16 bytes** | Address Error Exception (immediate crash) |
| **GIF DMA (Channel 2 / `D2_MADR`)**| **16 bytes (1 quadword)** | Transfer ignores lower 4 bits; DMA transfers wrong memory! |
| **VIF DMA (Channel 0/1 / `D0_MADR`)**| **16 bytes (1 quadword)** | Packet corrupted, VIF decode stall |
| **SIF0/1 RPC Buffers (IOP Bridge)**| **64 bytes** | IOP DMA desync, corrupted inter-processor calls |
| **SPU2 Audio Ring Buffers** | **64 bytes (burst size)** | Audio click/pop, corrupted sample blocks |
| **Double-Buffered Ping-Pong Arenas**| **128 bytes (cache line)**| Cache eviction trashing, false sharing between CPU and DMA |

---

## 2. Uncached Accelerated Memory: Eliminating D-Cache Hazards

The EE CPU uses a 2-way write-back 8 KB data cache. When the CPU writes to cached RAM (`0x00000000`), the data stays in L1 cache until evicted.
However, **hardware DMA controllers read physical DRAM directly**, bypassing the CPU L1 cache completely.

### The Virtual Address Mirrors

```text
Physical DRAM: 0x00000000 - 0x01FFFFFF (32 MB)

Cached Access (Default CPU):
  0x00000000 - 0x01FFFFFF (KUSEG Cached)
  -> Reads/writes pass through L1 D-Cache.
  -> Requires explicit `SyncDCache` before DMA transmission!

Uncached Mirror:
  0x20000000 - 0x21FFFFFF (KUSEG Uncached)
  -> Reads/writes bypass cache completely. Slow for frequent CPU reads.

Uncached Accelerated Mirror (DMA Staging Buffers):
  0x30000000 - 0x31FFFFFF (KUSEG Uncached Accelerated)
  -> CPU writes are grouped into 128-bit write-combining buffers and sent directly to RAM.
  -> Eliminates the need for costly `SyncDCache` flushes before DMA kicks!
```

### Citrine DMA Buffer Allocation Rule
When allocating scratch buffers for GIF, VIF, or SIF DMA:
```crystal
# Direct pointer to Uncached Accelerated mirror
def self.to_dma_buffer(ptr : Pointer(UInt8)) : Pointer(UInt8)
  # Strip upper nibble and set bit 28 (0x30000000)
  Pointer(UInt8).new((ptr.address & 0x01FFFFFF) | 0x30000000)
end
```

---

## 3. Allocator Heap Forensics (Handbook Ch. 24)

When memory corruption occurs, the program almost never crashes at the code that wrote out-of-bounds; it crashes hundreds of cycles later when `malloc` or `free` reads a corrupted node pointer.

### Turning the Free-List Walker into a Continuous Validator
Citrine's Tier 3 explicit allocator instruments chunk headers with canary integrity markers:

```c
typedef struct CitrineChunkHeader {
    uint32_t canary_head;   // Always 0xDEADBEEF
    uint32_t size_and_flags;// Chunk size, bit 0 = in_use
    struct CitrineChunkHeader* next_free;
    struct CitrineChunkHeader* prev_free;
} CitrineChunkHeader;
```

### Forensic Rules
1. **Canary Verification on Every `free()`**:
   - Verify `header->canary_head == 0xDEADBEEF`.
   - Verify trailing canary at `header + size - 4 == 0xCAFEBABE`.
   - If corrupted, panic with the exact allocation tag, origin, and corrupted address.
2. **Periodic Heap Walk**:
   - At V-Blank during idle raster wait, walk the Tier 3 free-list.
   - If any link pointer points outside the valid 32 MB heap bounds (`0x00100000 - 0x01FFFFFF`), halt immediately.
3. **No Padding Workarounds**:
   - If an array write crashes the heap, do NOT increase padding to make the crash disappear. Trace the bounding logic to locate the buffer overrun.
