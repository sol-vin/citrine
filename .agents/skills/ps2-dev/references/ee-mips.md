# Emotion Engine (EE) MIPS R5900 Reference

Technical guide for the PlayStation 2 Emotion Engine MIPS R5900 core, Scratchpad RAM, BIOS syscall conventions, and ELF executable generation.

---

## 1. MIPS R5900 Architecture Highlights

- **Clock Speed**: 294.912 MHz
- **General Purpose Registers**: 32 GPRs (`$zero`, `$at`, `$v0-$v1`, `$a0-$a3`, `$t0-$t9`, `$s0-$s7`, `$k0-$k1`, `$gp`, `$sp`, `$fp/$s8`, `$ra`).
- **Register Width**: 128 bits internal width, accessible as standard 32-bit/64-bit MIPS III instructions with multimedia 128-bit extensions (MMI).
- **Branch Delay Slots**: All branch and jump instructions (`j`, `jal`, `jr`, `jalr`, `beq`, `bne`, `beqz`, `bnez`) execute the immediately following instruction before branching.
- **Pipeline Constraints**: Load delay slot applies; avoid using a register loaded via `lw` or `ld` in the very next instruction.

---

## 2. PS2 BIOS Syscall Conventions

Syscalls on the EE are invoked using standard MIPS `syscall` instruction.
The syscall index is placed into register **`$v1`**, arguments into **`$a0-$a3`**, and the return value is returned in **`$v0`**.

| Function | Syscall (`$v1`) | Arguments | Description |
|:---|:---|:---|:---|
| `Exit` | `0x04` | None | Terminates program and returns to OSDSYS |
| `_SetGsCrt` | `0x02` | `$a0`: `interlace`<br>`$a1`: `ntsc_pal`<br>`$a2`: `field` | Configures GS video signal mode.<br>NTSC: `_SetGsCrt(1, 2, 0)` (Interlaced, NTSC, Field)<br>PAL: `_SetGsCrt(1, 3, 0)` |
| `_GsPutIMR` | `0x71` | `$a0`: mask (e.g. `0xFF00`) | Sets GS Interrupt Mask Register |
| `_SyncDCache`| `0x64` | `$a0`: start addr, `$a1`: size | Flushes data cache lines for memory range |

### Standard Video Initialization Sequence
```mips
# 1. Reset GS via GS_CSR:
lui   $v1, 0x1200
ori   $v1, $v1, 0x1000     # $v1 = 0x12001000
ori   $v0, $zero, 0x200    # bit 9: Reset GS
sd    $v0, 0($v1)

# 2. Syscall _GsPutIMR(0xFF00):
ori   $v1, $zero, 0x71
lui   $a0, 0x0000
ori   $a0, $a0, 0xff00
syscall
nop

# 3. Syscall _SetGsCrt(1, 2, 0) - Interlaced, NTSC, Field:
ori   $v1, $zero, 0x02
ori   $a0, $zero, 1        # Interlace = 1
ori   $a1, $zero, 2        # Mode = 2 (NTSC)
ori   $a2, $zero, 0        # Field = 0
syscall
nop
```

---

## 3. Scratchpad RAM (SPRAM)

The EE includes **16 KB of high-speed Scratchpad RAM** mapped at `0x70000000 - 0x70003FFF`.
- Accessed at CPU clock speed without bus arbitration or cache overhead.
- Excellent for stack allocation, transient DMA queues, or VM execution frames.
- **Canary testing**: Writing a sentinel like `0xDEADBEEF` to `0x70000000` allows debuggers (r2 / GDB) to verify that execution reached entry without requiring complex display initialization.

```mips
lui   $t0, 0x7000
lui   $t1, 0xDEAD
ori   $t1, $t1, 0xBEEF
sw    $t1, 0($t0)          # SPRAM canary written
```

---

## 4. PS2 ELF Binary Structure

PS2 ELFs are 32-bit Little-Endian MIPS executables (`ELF32`, `2LSB`, `EM_MIPS = 8`):
- `e_entry`: Default user entry point is `0x00100000`.
- `e_flags`: `0x20924001` (EF_MIPS_R5900 / MIPS III / PIC flags).
- **Segment Layout**:
  - `PH 0 (Code/RO)`: Virtual address `0x00100000`, flags `PF_R | PF_X` (`0x5`), containing `.text` and `.rodata`.
  - `PH 1 (Data)`: Virtual address `0x00200000`, flags `PF_R | PF_W` (`0x6`), containing `.data` and `.bss`.
- **Symbols**: Adding `.symtab` and `.strtab` allows external debuggers (`r2`, PCSX2 debugger) to resolve function boundaries and symbol names without manual disassembly symbol recovery.
