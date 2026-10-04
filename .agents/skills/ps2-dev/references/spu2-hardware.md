# PlayStation 2 SPU2 Audio Hardware & Streaming Architecture

Complete technical reference for the Sony PlayStation 2 Sound Processing Unit 2 (SPU2), voice registers, ADPCM sample playback, and double-buffered audio streaming.

---

## 1. SPU2 Hardware Architecture Overview

The SPU2 provides 48 hardware voices split evenly across two identical sound cores:

```text
+--------------------------------------------------------------------------+
|                        SPU2 Sound Processor                              |
|  - 2 MB Dedicated Sound RAM (SPU RAM)                                   |
|  - 44.1 kHz Output Sampling Rate (16-bit Stereo PCM)                     |
|  - Hardware ADPCM Decoder (Compressed 4-bit to 16-bit PCM)               |
+--------------------------------------------------------------------------+
       |                                                 |
+---------------------------------+   +---------------------------------+
|      Core 0 (Voices 0..23)      |   |      Core 1 (Voices 24..47)     |
| - Key On / Key Off registers    |   | - Key On / Key Off registers    |
| - ADSR Envelope Generator       |   | - ADSR Envelope Generator       |
| - Pitch Modulation (PMON)       |   | - Pitch Modulation (PMON)       |
| - Noise Generator               |   | - AutoDMA Stream Input (Ch 4)   |
| - Hardware Reverb Work Area     |   | - Hardware Reverb Work Area     |
+---------------------------------+   +---------------------------------+
```

- **Processing Clock**: 44.1 kHz output rate.
- **Dynamic Memory Bus**: 2 MB SPU2 RAM is accessed by both cores, reverb engines, and DMA Channel 4 on a shared time-slice schedule.

---

## 2. Voice Registers & Configuration

Each voice has its own set of memory mapped registers:

| Register | Width | Description & Formula |
|:---|:---|:---|
| `VPITCH` | 16-bit | Pitch multiplier: $f_{\text{out}} = 44100 \times \left(\frac{\text{VPITCH}}{4096}\right) \text{ Hz}$<br>• `0x1000` = 44.1 kHz (1.0×)<br>• `0x0800` = 22.05 kHz (0.5×) |
| `VVOLL`  | 16-bit | Left channel volume (Bits 0..14 volume, Bit 15 phase inversion) |
| `VVOLR`  | 16-bit | Right channel volume |
| `VADDR`  | 16-bit | Start address of ADPCM sample in Sound RAM (`address >> 3`) |
| `ADSR1`  | 16-bit | Attack Rate (AR), Decay Rate (DR), Sustain Level (SL) |
| `ADSR2`  | 16-bit | Sustain Rate (SR), Release Rate (RR), Mode flags |
| `LOOP`   | 16-bit | Loop start address in Sound RAM |

---

## 3. Sony ADPCM Audio Block Format

Sound RAM stores compressed 4-bit Sony ADPCM samples:
- **Block Size**: 16 bytes.
- **Decompressed Samples**: 28 × 16-bit linear PCM samples per block (compress factor 3.5:1).

```text
Byte 0: Shift & Filter
  - Bits [3:0]: Range/Shift exponent (0 to 12)
  - Bits [7:4]: Filter index (0 to 4 coefficient sets)
Byte 1: Flag Byte
  - Bit 0: Loop Start (marks loop restart point)
  - Bit 1: Loop Repeating (set if currently in loop)
  - Bit 2: Loop End (triggers loop rewind or voice termination)
Bytes 2..15: 28 × 4-bit compressed nibbles (interleaved LSB/MSB)
```

---

## 4. Playback Control: Key On & Key Off

Sound generation is triggered per-core via bitmasks:

- **Key On (`KON0` / `KON1`)**:
  - Writing `1` to bit $n$ kicks voice $n$ into its Attack phase, resetting the ADPCM decoder state and beginning playback at `VADDR`.
- **Key Off (`KOFF0` / `KOFF1`)**:
  - Writing `1` to bit $n$ moves voice $n$ into its Release phase (`RR`). When the envelope reaches zero, the voice turns off.
- **End-Of-Sound (`ENDX0` / `ENDX1`)**:
  - Read-only bitmask indicating which voices have hit an ADPCM block with `Loop End = 1` without loop continuation.

---

## 5. Streaming Audio Architecture & Ring Buffer Wire ABI (Handbook Ch. 28)

For background music (BGM) and long voice dialogue, samples cannot fit in 2 MB SPU RAM. They must stream continuously from EE/IOP memory via **AutoDMA** (IOP DMA Channel 4).

### Ring Buffer Wire ABI Rules
1. **Double-Buffered SPU RAM Ring**:
   - Allocate a double-buffered ring in SPU2 RAM (e.g. 8 KB = two 4 KB ping-pong banks).
   - Bank A: `0x0000 - 0x0FFF` (played while Bank B is loaded).
   - Bank B: `0x1000 - 0x1FFF` (played while Bank A is loaded).
2. **Transfer Alignment**:
   - Every streaming transfer block must be a multiple of **16 bytes** (ADPCM block) and **64 bytes** (DMA burst size).
3. **Interrupt Coordination**:
   - Do NOT poll SPU2 registers in an EE tight loop. Use IOP timer or SPU2 interrupt (`IRQ`) when the play pointer crosses the bank boundary.
4. **Deploy Format & Wire Agreement**:
   - The ring buffer transfer layout, packet headers, and channel interleaving form an immutable wire ABI between EE and IOP. Never change the streaming structure without recompiling both EE runner and IOP IRX modules simultaneously.
