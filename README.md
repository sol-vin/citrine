# Citrine: Crystal Virtual Machine & Toolkit for PlayStation 2

[![Citrine CI](https://github.com/sol-vin/citrine/actions/workflows/ci.yml/badge.svg)](https://github.com/sol-vin/citrine/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Crystal](https://img.shields.io/badge/Crystal->=1.10.0-black?logo=crystal)](https://crystal-lang.org/)

**Citrine** brings the expressive elegance, safety, and joy of the **Crystal programming language** to homebrew game development on the **Sony PlayStation 2 (PS2)**.

Rather than forcing developers to install a massive MIPS cross-compilation toolchain or fight the Emotion Engine's non-standard R5900 core, Citrine uses a **custom, hardware-tailored Virtual Machine (`citrine-vm`)** and a **high-performance Raylib-style C runtime (`citrine-rt`)**.

Games are compiled into compact **Citrine ByteCode (`.cbc`)** in **under 50 milliseconds**, executed on a pre-compiled PS2 runner ELF (`citrine_runner.elf`), and **hot-reloaded live on the console in real time**.

---

## Architecture Overview

```
+-------------------------------------------------------------+
|                      Crystal Game Code                      |
|                  (Raylib-Style Game Logic)                  |
+-------------------------------------------------------------+
                              |
                     [citrine compile]
                     (Crystal::Parser)
                              |
       +----------------------+----------------------+
       |                                             |
       v                                             v
+---------------+                             +---------------+
|   game.cbc    |                             |  game.cbcsym  |
|  (Bytecode)   |                             | (Source Map)  |
+---------------+                             +---------------+
       |                                             |
       |  (PCSX2 host: / PS2Link Network)            |
       v                                             v
+-------------------------------------------------------------+
|               PlayStation 2 (Emotion Engine)                |
|                                                             |
|  [Citrine-VM Core]                                          |
|    * 128-bit QWORD Values (Single sq/lq cycle)             |
|    * 1,024 Register Window pinned in 16KB SPRAM (0x70000000)|
|    * Computed goto Direct-Threaded Dispatch                 |
|    * Zero-GC Memory (Frame Bump Arena + Level Arena)        |
|                                                             |
|  [citrine-rt (PS2 Native Engine)]                           |
|    * GS 2D Primitives, Textures, and Sprites (GIF-DMA)      |
|    * DualShock 2 Controller Polling & Rumble (libpad)       |
|    * SPU2 Sound Effects & BGM Streaming (audsrv)            |
|    * On-Screen Crash Screen & Diagnostic HUD Overlay        |
+-------------------------------------------------------------+
                               ^
                               | (TCP GDB Port 1234)
                      [cradare2 Debugger]
```

---

## Why a Custom VM for PlayStation 2?

1. **128-Bit QWORD Values**:
   The Emotion Engine CPU natively processes 128-bit Quadwords. Citrine’s fundamental `Value` is a 16-byte aligned tagged union. Register copies execute in a single CPU cycle via the EE's native `lq` (Load Quadword) and `sq` (Store Quadword) instructions.
2. **Zero Cache Latency in 16KB SPRAM**:
   The EE CPU has an 8KB D-cache that easily thrashes. Citrine avoids this by pinning the active **1,024 VM virtual registers directly into the 16KB Scratchpad RAM (SPRAM at `0x70000000`)**, guaranteeing 0-cycle cache latency.
3. **Zero-GC Memory Design**:
   Traditional tracing garbage collectors cause frame stutters. Citrine uses a tiered zero-GC architecture:
   - **Value Types**: `Vector2`, `Color`, integers, floats, and handles reside on the SPRAM register stack.
   - **Frame Bump Arena**: Temporary strings and tables are allocated in a bump arena that resets to zero every frame at `Citrine.end_drawing`.
   - **Level Arena**: Long-lived assets are allocated per level and freed in bulk on scene transition.
   - **Result**: Locked 60 FPS deterministic gameplay.
4. **No Cross-Compiler Needed**:
   Game creators only need the `crystal` compiler. You do not need Docker, PS2SDK, or MIPS GCC installed on your PC to make PS2 games!

---

## CLI Toolkit (`citrine`)

Install the shard or build the CLI:

```bash
shards build citrine
```

### Commands

| Command | Description |
| :--- | :--- |
| `citrine new <project_name>` | Scaffold a new PS2 game project with template code and assets |
| `citrine compile <file.cr> [-o <out.cbc>]` | Compile Crystal source into `.cbc` bytecode and `.cbcsym` source map |
| `citrine run <file.cr> [--watch]` | Compile and boot game in PCSX2 with live hot-reloading |
| `citrine disasm <file.cbc>` | Disassemble bytecode into human-readable assembly with source lines |
| `citrine monitor [--port <port>]` | Connect live telemetry monitor to PS2 / PCSX2 GDB stub |
| `citrine version` | Display Citrine version |

---

## Writing Games in Crystal

Here is a complete, working game written in Crystal for the PS2:

```crystal
require "citrine"

Citrine.init_window(640, 448, "My PS2 Game")
Citrine.set_target_fps(60)

pos = Vector2.new(320.0, 224.0)
speed = 4.0

Citrine.main_loop do
  # DualShock 2 D-Pad & Analog input
  if Citrine.button_down?(Button::Right)
    pos.x += speed
  elsif Citrine.button_down?(Button::Left)
    pos.x -= speed
  end

  if Citrine.button_down?(Button::Down)
    pos.y += speed
  elsif Citrine.button_down?(Button::Up)
    pos.y -= speed
  end

  # Rendering
  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  Citrine.draw_rectangle(pos.x, pos.y, 40, 40, Color::Red)
  Citrine.draw_circle(pos.x + 20.0, pos.y + 20.0, 10.0, Color::Yellow)
  Citrine.draw_text("Hello from Crystal on PlayStation 2!", 30, 30, 16, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
```

---

## Safety Guarantees & Resource Auditing

Every time you compile code with `citrine compile`, the **Hardware Budget Checker** statically audits your code:

```
[Citrine] Compiling main.cr -> game.cbc...
[Citrine] Success: game.cbc generated (618 bytes) in 3.9 ms.

=== PS2 Hardware Resource Audit ===
Total Functions:       1
Peak SPRAM Frame:      58 / 1024 registers (__main__)
Bytecode Size:         618 bytes

Budget Status: PASSED (Hardware limits verified).
```

- **SPRAM Budget**: Warns if any function requests $> 128$ registers; errors if $> 1024$.
- **VRAM Estimator**: Audits resident texture footprints against the GS 4MB eDRAM pool (~550KB resident texture budget).
- **SPRAM Stack Canary**: Detects register overruns at runtime before memory corruption can occur.
- **Infinite Loop Watchdog**: Traps runaway loops executing $> 5,000,000$ instructions without yielding.
- **On-Screen Crash Handler (PS2 BSOD)**: Upon an exception or panic, freezes gameplay and displays a styled crash screen with the exact Crystal source file, line number, and SPRAM register state.

---

## Diagnostics & cradare2 Debugging

### In-Engine Profiler HUD
Toggle the diagnostic HUD anytime with `Citrine.debug_overlay = true` or `Button::Select`:
- Real-time FPS & frame pacing (59.94 FPS / 16.6ms).
- EE CPU split-meter (VM bytecode execution time vs. native C engine time).
- GS GPU draw rasterization time.
- SPRAM active registers count / 1,024 slots.
- Frame Arena usage bytes.

### radare2 & cradare2 Integration
Citrine seamlessly bridges with [`cradare2`](https://github.com/sol-vin/cradare2):
- **Source Maps (`.cbcsym`)**: Maps every bytecode instruction to its originating Crystal file, line, and function.
- **TCP GDB Client**: Connects to PCSX2's GDB stub (`127.0.0.1:1234`) or PS2Link to inspect the Emotion Engine MIPS core, read 16-byte SPRAM `Value` registers, and perform source-level stepping.
- **Disassembler Script (`r2-citrine`)**: Auto-generates radare2 flags and memory map definitions for PS2 memory spaces (`0x70000000` SPRAM, GS framebuffers).

---

## Examples

Check the `examples/` directory:
- [`01_hello_pad`](examples/01_hello_pad/main.cr): DualShock 2 gamepad input handling, color cycling, and GS 2D rendering.
- [`02_shapes_and_text`](examples/02_shapes_and_text/main.cr): 2D primitives, colors, text, and interactive profiler HUD overlay.
- [`03_entity_fibers`](examples/03_entity_fibers/main.cr): Entity AI patrol logic with cooperative coroutines/fibers.
- [`04_safety_and_panic`](examples/04_safety_and_panic/main.cr): Demonstrates hardware safety guards and the on-screen crash screen.
- [`05_hello_world`](examples/05_hello_world/main.cr): Classic DVD-style bouncing logo benchmark.
- [`06_dvd_bounce`](examples/06_dvd_bounce/main.cr): High-performance multi-logo DVD bounce stress test.
- [`07_primitives_2d_3d`](examples/07_primitives_2d_3d/main.cr): Combined 2D rasterization and 3D wireframe rendering.
- [`08_controller_tester`](examples/08_controller_tester/main.cr): Full DualShock 2 hardware pad diagnostic suite (pressure buttons, analog sticks, vibration motors).
- [`09_concurrency_showcase`](examples/09_concurrency_showcase/main.cr): CSP channels, wait groups, and fiber scheduling.
- [`10_cd_player`](examples/10_cd_player/main.cr): Night Tempo - Moonrise CD-DA multi-track optical playback and SPU2 audio.
- [`11_macro_ecs_showcase`](examples/11_macro_ecs_showcase/main.cr): High-performance macro-driven Entity Component System.
- [`12_immediate_ui`](examples/12_immediate_ui/main.cr): Immediate-mode GUI controls, sliders, and button widgets.
- [`13_physics_and_particles`](examples/13_physics_and_particles/main.cr): Particle systems and 2D physics integration.
- [`14_creative_coding`](examples/14_creative_coding/main.cr): Procedural generative art and mathematical visualizations.
- [`15_rigid_body_physics`](examples/15_rigid_body_physics/main.cr): 3D rigid body dynamics and collision detection.
- [`16_shaders_and_postfx`](examples/16_shaders_and_postfx/main.cr): GS rasterization effects and post-processing filters.
- [`17_inline_assembly`](examples/17_inline_assembly/main.cr): First-class MIPS R5900 inline assembly (`asm`), COP0 cycle counter profiling, VU0 Macro Mode SIMD, and CD-DA optical audio streaming.

---

## Testing

Run the full automated test suite:

```bash
crystal spec
```

All 16 test suites verify parser fidelity, opcode generation, register allocation, budget auditing, disassembly roundtripping, and cradare2 integration.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
