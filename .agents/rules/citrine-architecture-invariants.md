# Citrine Architecture & Code Invariants

## 1. Engine Purity
- `src/citrine/iso/elf_builder.cr` and `src/stubs/citrine/inputmap.cr` are core engine runtime components.
- NEVER add game-specific or example-specific action names, enum entries, or MIPS branching logic into engine files.
- DualShock 2 buttons (`Button::Cross`, `Button::Circle`, `Button::Square`, `Button::Triangle`, `Button::R1`, `Button::L1`, `Button::R2`, `Button::L2`, `Button::Up`, `Button::Down`, `Button::Left`, `Button::Right`) are universal hardware standards accessed via `pad.button_pressed?` and `pad.button_down?`.

## 2. Clean Data Modeling & DRY
- NEVER generate repetitive `case` ladders (e.g. 50-line track/duration switch blocks) inside per-frame loops.
- Model multi-element data using arrays, structs, or pre-computed lookup tables.
- Compute formatting (e.g. `mm:ss`, optical track numbering) dynamically from numeric values.

## 3. Windows Tooling & Process Safety
- In Crystal on Windows, avoid `Dir.glob(File.join(dir, "*"))` with backslashes; use `Dir.children(dir)` to avoid path escaping bugs.
- Always terminate running `pcsx2-qt.exe` or `citrine.exe` process trees before invoking `crystal build` to prevent linker file lock errors (`LNK1104`).
