# PlayStation 2 GIF & DMA Transfers

Complete specification for constructing Graphics Interface (GIF) packets and controlling Direct Memory Access (DMA Channel 2) on the PlayStation 2 Emotion Engine.

---

## 1. 128-bit GIFTag Specification

Every packet sent to the GS begins with a 128-bit (Quadword) GIFTag:

```text
Quadword:
+------------------------------------+------------------------------------+
|               High 64 Bits         |               Low 64 Bits          |
| REGS (bits 64..127, 16 x 4-bit)    | NREG | FLG | PRIM | PRE | EOP |NLOOP|
+------------------------------------+------------------------------------+
```

### Low 64 Bits Bitfield

| Bits | Field | Description |
|:---|:---|:---|
| `0..14` | `NLOOP` | Number of loops (sequences of register updates). Max 32767 (`0x7FFF`). |
| `15` | `EOP` | End Of Packet flag. Set to `1` on the final tag in a batch. |
| `16..45`| Reserved | Must be zero. |
| `46` | `PRE` | Pre-PRIM enable. If 1, use PRIM field in bits 47..57. |
| `47..57`| `PRIM` | Primitive setting to apply if `PRE=1`. |
| `58..59`| `FLG` | Data format: `0b00` = PACKED, `0b01` = REGLIST, `0b10` = IMAGE. |
| `60..63`| `NREG` | Number of registers to write per loop (1 to 16, encoded as 1..16; `1` for A+D). |

### High 64 Bits (`REGS`)
Contains up to 16 4-bit register identifiers:
- In **PACKED A+D mode**:
  - `NREG = 1` (Bits 60..63 = 1)
  - `REG0 = 0x0E` (Bits 64..67 = `0x0E` -> High 64 bits = `0x0E_u64`)
  - Each loop consumes exactly **one 128-bit Quadword**:
    - Low 64 bits: Data to write to GS register
    - High 64 bits: Target GS register address (`0x00` = PRIM, `0x01` = RGBAQ, `0x05` = XYZ2, `0x4C` = FRAME, etc.)

---

## 2. DMA Channel 2 (GIF) Control Registers

GIF DMA is managed by DMAC Channel 2 located in EE physical I/O space at `0x1000A000`:

| Register | Address | Description |
|:---|:---|:---|
| `D2_CHCR` | `0x1000A000` | Channel Control Register (Mode, direction, start) |
| `D2_MADR` | `0x1000A010` | Memory Address Register (Source buffer in EE RAM) |
| `D2_QWC` | `0x1000A020` | Quadword Count Register (Number of 16-byte units) |
| `D2_TADR` | `0x1000A030` | Tag Address Register (for source-chain DMA) |

### `D2_CHCR` Bitfield
```text
Bit 0: DIR       - Direction: 0 = To Memory, 1 = From Memory (EE to GS, always 1)
Bits 2..3: MOD   - Mode: 0b00 = Normal Mode, 0b01 = Chain Mode, 0b10 = Interleaved
Bit 8: STR       - Start/Status: Write 1 to start transfer. Hardware clears to 0 when finished.
```
*Standard Start Command for Normal Mode (EE -> GS)*:
`D2_CHCR = 0x101` (STR=1, DIR=1).

---

## 3. Physical & Uncached Memory Addressing for DMA

The DMAC operates purely on **physical memory addresses**. The CPU data cache may hold unwritten packet data unless flushed or bypassed.

### Memory Windows:
- **KUSEG Cached**: `0x00100000` (CPU cached).
- **KUSEG Uncached Accelerated**: `0x30100000` (`addr | 0x30000000`). Bypasses cache and uses write-combining buffer.
- **KSEG1 Uncached**: `0xA0100000` (`addr | 0xA0000000`). Pure uncached access.

> [!TIP]
> If building GIF packets in cached memory, either call the BIOS cache flush syscall (`_SyncDCache` / `syscall 0x64`) or map `D2_MADR` to uncached memory (`addr & 0x0FFFFFFF`).

---

## 4. Canonical MIPS Assembly for DMA Dispatch

### Step 1: Wait for DMA Channel 2 Idle
```mips
dma02_wait:
    lui   $t8, 0x1000
    ori   $t8, $t8, 0xa000     # $t8 = 0x1000A000 (D2_CHCR)
wait_loop:
    lw    $t9, 0($t8)
    andi  $t9, $t9, 0x100      # Check STR bit (bit 8)
    bnez  $t9, wait_loop
    nop
    jr    $ra
    nop
```

### Step 2: Dispatch DMA Packet
```mips
    # Ensure previous transfer is done
    jal   dma02_wait
    nop

    # Set up D2_MADR and D2_QWC
    lui   $t8, 0x1000
    ori   $t8, $t8, 0xa000     # D2_CHCR base
    lui   $t7, (packet_addr >> 16)
    ori   $t7, $t7, (packet_addr & 0xFFFF)
    sw    $t7, 0x10($t8)       # D2_MADR = packet physical address
    ori   $t6, $zero, qword_count
    sw    $t6, 0x20($t8)       # D2_QWC = packet size // 16
    ori   $t6, $zero, 0x101    # STR=1, DIR=1
    sw    $t6, 0x00($t8)       # D2_CHCR = start DMA transfer

    # Wait for completion before returning or overwriting buffer
    jal   dma02_wait
    nop
```
