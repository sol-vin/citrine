# Citrine VM to Emotion Engine (MIPS R5900) JIT Emitter Reference

Technical reference for translating Citrine VM bytecodes into native MIPS R5900 machine code, utilizing 128-bit MMI SIMD instructions, VU0 macro mode, and branch delay slot rules.

---

## 1. Native Machine Code Emitter Overview (`Citrine::ElfBuilder`)

Citrine VM compiles bytecode instructions (`.cbc`) directly into standalone PlayStation 2 ELF executables using `Citrine::ElfBuilder` and `Citrine::Compiler::MipsEmitter`.

```text
Citrine Source (.cr) ---> Bytecode (.cbc) ---> MipsEmitter ---> Standalone PS2 ELF
                            (Opcode)             (R5900 MMI)       (0x00100000)
```

---

## 2. SIMD & Vector Opcode Translation Table

| Citrine VM Opcode | Format | Emitted MIPS R5900 Sequence | Hardware Notes |
|:---|:---|:---|:---|
| `Nop` | ABC | `nop` (`0x00000000`) | Standard 1-cycle pipeline idle |
| `Move $dst, $src` | ABC | `move $dst, $src` (`addu $dst, $src, $zero`) | 1 cycle ALU |
| `LoadInt $dst, imm16` | AB_IMM | `addiu $dst, $zero, imm16` | Sign-extended 16-bit immediate |
| `Add $dst, $a, $b` | ABC | `addu $dst, $a, $b` | Unsigned 32-bit addition |
| `Sub $dst, $a, $b` | ABC | `subu $dst, $a, $b` | Unsigned 32-bit subtraction |
| `Mul $dst, $a, $b` | ABC | `mult $a, $b; mflo $dst` | 2-cycle latency on `$LO` read |
| `Div $dst, $a, $b` | ABC | `div $a, $b; mflo $dst` | Hardware divider |
| **`Vec2Add`** | ABC | **`PADDW $dst, $a, $b`** | 128-bit MMI: adds both X and Y lanes in **1 instruction**! |
| **`Vec2Sub`** | ABC | **`PSUBW $dst, $a, $b`** | 128-bit MMI: subtracts X and Y lanes simultaneously |
| **`ColorNew`** | ABC | **`PPAC5 $dst, $a`** | 128-bit MMI: packs 4 × 32-bit RGBA channels into 16-bit `5:5:5:1` |
| **`ColorUnpack`** | ABC | **`PEXT5 $dst, $a`** | 128-bit MMI: expands 16-bit pixel into 32-bit color lanes |
| `Jump` | BRANCH | `j target; nop` | Unconditional jump with delay slot |
| `JumpIfTrue` | BRANCH | `bne $cond, $zero, target; nop` | Conditional branch with delay slot |
| `JumpIfFalse` | BRANCH | `beq $cond, $zero, target; nop` | Conditional branch with delay slot |
| `Call` | AB_IMM | `jal target; nop` | Function call, `$ra` stores return address |
| `Return` | ABC | `move $v0, $src; jr $ra; nop` | Return value in `$v0`, jump to `$ra` |

---

## 3. Branch Delay Slot Emitter Rules

MIPS architectures execute the instruction immediately following a jump or branch before the branch takes effect:

```assembly
; Correct Emitter Sequence:
    bne $a0, $zero, .label_target
    nop                             ; Delay slot filled with NOP or non-destructive work

.label_target:
    addu $v0, $v0, $a0
```

### Critical Emitter Invariants
1. **Never Branch into a Delay Slot**:
   - The emitter must verify that branch targets do NOT land on an instruction in a branch delay slot.
2. **Never Emit Branches Inside Delay Slots**:
   - Emitting `bne`, `beq`, `j`, or `jal` inside the delay slot of a previous jump produces undefined processor behavior and triggers a CPU bus exception.
3. **Delay Slot Optimization**:
   - When emitting simple moves (`move $dst, $src`) or register initializations directly preceding a jump, move the instruction down into the branch delay slot to save 1 instruction word.

---

## 4. Register Allocation & Scratchpad Fast Frames

- **Virtual Registers `$r0` through `$r15`**:
  - Mapped to MIPS GPRs `$v0`, `$v1`, `$a0` - `$a3`, `$t0` - `$t7`.
- **Extended Registers `$r16` through `$r255`**:
  - Mapped to **Fast Activation Frames in SPRAM (`0x70000000 - 0x70003FFF`)**.
  - SPRAM offers 0-wait-state single-cycle access directly on the EE core, avoiding main memory cache-miss penalties during heavy register spills.
