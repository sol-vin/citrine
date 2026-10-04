# Citrine Architecture & Code Invariants

## 1. Engine Purity & Anti-Cheating Doctrine
- **Absolute General-Purpose Invariant**: Core Citrine compiler (`src/citrine/compiler/`), bytecode VM interpreter (`src/citrine/iso/phase_extractor.cr`), MIPS code generator (`src/citrine/iso/text_segment_builder.cr`, `mips_emitter.cr`), and ISO runner (`elf_builder.cr`) MUST remain 100% general-purpose.
- **NEVER Sniff Example Strings or Titles**: NEVER scan bytecode strings or constants for specific example names (e.g. `BouncingLogo`, `06 DVD Bounce`, `Controller Tester`, `CD-DA Album Player`, `theme.vag`).
- **NEVER Hardcode Example-Specific Scenes or Mechanics**: NEVER create example-specific scene files (e.g. `dvd_screensaver_scene.cr`, `audio_player_scene.cr`, `controller_tester_scene.cr`) or hardcode application game logic, physics (e.g. DVD bouncing loops), custom telemetry overlays, or metadata files (`album_metadata.json`) inside the compiler or runtime.
- **Pure Bytecode & Standard Hardware Execution**: All graphics, audio calls, controller responses, and animations MUST originate exclusively from user source code compiled into Citrine Bytecode (CBC) and executed via the general-purpose bytecode VM and standard PS2 hardware interfaces (GS GIF packets, DMAC Channel 2, SPU2/CD-DA RPC, DualShock 2 registers).
- **Universal Hardware Buttons**: DualShock 2 buttons (`Button::Cross`, `Button::Circle`, etc.) are universal hardware standards queried via `pad.button_pressed?` and `pad.button_down?`. Never introduce game-specific action enums or MIPS branch hacks into engine files.

## 2. Clean Data Modeling & DRY
- NEVER generate repetitive `case` ladders (e.g. 50-line track/duration switch blocks) inside per-frame loops.
- Model multi-element data using arrays, structs, or pre-computed lookup tables.
- Compute formatting (e.g. `mm:ss`, optical track numbering) dynamically from numeric values.

## 3. Windows Tooling & Process Safety
- In Crystal on Windows, avoid `Dir.glob(File.join(dir, "*"))` with backslashes; use `Dir.children(dir)` to avoid path escaping bugs.
- Always terminate running `pcsx2-qt.exe` or `citrine.exe` process trees before invoking `crystal build` to prevent linker file lock errors (`LNK1104`).
