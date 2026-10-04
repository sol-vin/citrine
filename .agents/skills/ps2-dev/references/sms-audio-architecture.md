# SMS (Simple Media System) Audio Architecture Reference

Comprehensive analysis of Eugene Plotnikov's Simple Media System (SMS) audio subsystem, `audsrv` sound server, SPU2 streaming pipeline, and high-performance techniques for PlayStation 2 audio processing.

---

## 1. Architectural Philosophy: EE vs. IOP Decoupling

In the PlayStation 2 architecture, the Emotion Engine (EE, 294.912 MHz) and Input/Output Processor (IOP, 36.864 MHz) have radically different compute profiles:
* **EE (Compute Engine)**: 128-bit SIMD multimedia instructions (MMI), dual 32-bit integer ALUs, FPU, and VU0 Macro/Micro mode. Ideal for floating-point and integer DCT/MDCT, psychoacoustic transforms, and decoding compressed streams (MP3, AC3, Ogg Vorbis, AAC, FLAC).
* **IOP (I/O Controller)**: MIPS R3000A core without FPU. Excellent for DMA channel programming, SPU2 register control, and hardware interrupt handling.
* **The SMS Paradigm**:
  * **Decoding on EE**: Decodes audio packets in parallel with video decoding and IPU color-space conversion.
  * **Streaming over SIF**: Streams decoded raw PCM or ADPCM packets to IOP memory via SIF1 DMA.
  * **Double-Buffering on IOP / SPU2**: IOP transfers 2 KB - 64 KB blocks into SPU2 work RAM via SPU2 DMA Channel 4/7.

```text
+--------------------------------------------------------------------------+
|                        Emotion Engine (EE)                               |
|  - Audio Demuxing (AVI / MKV / Ogg / CDDAFS)                             |
|  - Fast Fixed-Point Decoders (MP3 / AC3 / AAC / Vorbis / PCM)             |
|  - Decodes directly into 64-byte aligned uncached DMA buffers            |
|  - A/V Sync Controller (1ms resolution timer + PTS tracking)             |
+--------------------------------------------------------------------------+
                                     |
                          SIF1 DMA / SIF RPC (ASMS)
                                     |
+--------------------------------------------------------------------------+
|                     Input/Output Processor (IOP)                         |
|  - audsrv / Sound Driver                                                 |
|  - IOP Ring Buffer (64 KB - 128 KB)                                      |
|  - Double-Buffer Manager (Core 0 / Core 1 DMA)                           |
+--------------------------------------------------------------------------+
                                     |
                         SPU2 DMA (Channel 4 / 7)
                                     |
+--------------------------------------------------------------------------+
|                  Sound Processing Unit 2 (SPU2)                          |
|  - 2 MB Sound RAM                                                        |
|  - Double-Buffer Ping-Pong Slots (e.g., 2 x 4KB or 2 x 32KB)             |
|  - 48 Voices (Core 0 Voice 0..23, Core 1 Voice 0..23)                    |
|  - AutoDMA / SPU2 Interrupt / End-of-Transfer Callback                   |
+--------------------------------------------------------------------------+
```

---

## 2. Low-Latency Memory Management: Uncached 64-Byte Alignment

SMS avoids standard `malloc` and cache flushes by using deterministic buffer layout:
* **Uncached Acceleration (`0x30000000 | addr`)**: EE decodes audio directly into uncached memory space, eliminating cache eviction overhead and data-cache flush delays.
* **64-Byte Alignment**: All SIF DMA buffers, sound descriptors, and ring buffers are aligned to 64 bytes (`__attribute__((aligned(64)))`), the exact cache-line and DMA burst size of the Emotion Engine bus.
* **Zero-Copy Design**: Audio data written by the decoder is read directly by DMAC SIF1 without intermediate `memcpy` operations.

---

## 3. Double-Buffered SPU2 Streaming Protocol

To play continuous, multi-minute, or infinite audio streams without underrun or glitch:
1. **SPU2 RAM Buffer Allocation**:
   * Buffer A: Base address $S_A$ (e.g., `0x00010000`, size $N$ bytes).
   * Buffer B: Base address $S_B = S_A + N$ (e.g., `0x00018000`, size $N$ bytes).
2. **Ping-Pong Transfer**:
   * While Voice $V$ is decoding and playing Buffer A, IOP transfers the next chunk into Buffer B using SPU2 DMA (`sceSdVoiceTrans` or `sceSdBlockTrans`).
   * When Voice $V$ reaches the end of Buffer A, hardware loops into Buffer B.
   * IOP receives a transfer-complete callback or polls SPU2 transfer status (`sceSdVoiceTransStatus`), then transfers the subsequent chunk into Buffer A.
3. **Interrupt vs. Polling**:
   * SPU2 hardware generates an interrupt or signals `ENDX` when reaching the loop point.
   * `audsrv` utilizes SBUS Interrupt 15 (`AddSbusIntcHandler(15, SPU_DMAHandler)`) to signal an EE semaphore (`iSignalSema`) immediately when DMA completes.

---

## 4. Audio Preload & A/V Synchronization

* **Audio Preload**: Before unpausing the video or audio playback engine, SMS pre-fills both SPU2 buffer slots and buffers 200–500ms of audio in the IOP ring buffer. This completely eliminates initial audio stutter caused by disc seek latencies.
* **Real-Time Clock (RTC)**: EE Timer 0/1 configured with Bus Clock / 256 or HBLANK gating provides 1ms timebase resolution.
* **Presentation Time Stamps (PTS)**: Audio sample counts dictate the master clock. If video leads audio, video skips rendering or holds frame; if audio leads, the video pipeline accelerates.

---

## 5. Sony SPU2 ADPCM Encoding Rules (SMS Verification)

SMS embedded UI sounds (`g_SMSounds` in `SMS_Sounds.c`) confirm the exact PS2 SPU2 ADPCM bitflags:
* **Block size**: Exactly 16 bytes (2 header bytes + 14 sample bytes = 28 samples).
* **Byte 0**: Filter coefficient index (bits 4–6) and shift amount (bits 0–3).
* **Byte 1**: Loop control flags:
  * `0x00`: Normal intermediate block (one-shot mode).
  * `0x02`: **Loop Repeat / Envelope Sustain**. Must be present on all looping blocks to prevent volume envelope drop to zero.
  * `0x06` (`0x04 | 0x02`): **Loop Start** + Repeat. Marks the entry loop point.
  * `0x03` (`0x01 | 0x02`): **Loop End** + Repeat. Jumps back to the loop start point.
  * `0x01`: Loop End + Release/Mute (one-shot sound terminator).
