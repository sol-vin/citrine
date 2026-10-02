---
name: r2-ps2-debug
description: Guides static analysis and remote dynamic debugging of PlayStation 2 executables and Citrine bytecode using radare2 (r2). Use when inspecting ELF symbols, disassembling MIPS R5900 routines, connecting r2 to PCSX2's GDB stub, setting breakpoints, examining memory/SPRAM, and building automated debugger bridges.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: reverse-engineering
  triggers: radare2, r2, r2pipe, MIPS disassembler, PS2 debugger, GDB stub, SPRAM inspection, Citrine debugger
  role: specialist
  scope: analysis
  output-format: text
  related-skills: ps2-dev, pcsx2-cli
---

# Radare2 PS2 Debugging Specialist

Expert operational guide for static analysis and dynamic debugging of PlayStation 2 executables, Citrine bytecodes, and live PCSX2 sessions using radare2 (`r2`).

---

## 1. Quick Start Commands

```bash
# Analyze ELF binary symbols and function headers
r2 -q -c "is; afl" CITRINE.ELF

# Disassemble function 'main' as MIPS
r2 -e asm.arch=mips -e asm.bits=32 -q -c "pdf @ main" CITRINE.ELF

# Dump first 64 bytes of SPRAM canary at 0x70000000
r2 -q -c "pxw 64 @ 0x70000000" CITRINE.ELF

# Connect r2 to PCSX2 GDB stub on port 28011
r2 -d gdb://localhost:28011
```

---

## 2. Detailed References

Load detailed guides based on debugging task:

| Topic | Reference | Content |
|:---|:---|:---|
| Radare2 PS2 Commands | [r2-commands.md](./references/r2-commands.md) | Disassembly, memory dumps, register inspection, navigation |
| GDB Remote Debugging | [gdb-bridge.md](./references/gdb-bridge.md) | Connecting to PCSX2 GDB stub, breakpoints, stepping, register watch |
| Citrine & Automated Tooling | [citrine-integration.md](./references/citrine-integration.md) | Symbol resolution, `.cbcsym`, headless r2 invocation, pipe management |

---

## 3. Core Debugging Workflow

```text
[ PCSX2 Emulator ] <--- GDB Stub (port 28011) ---> [ r2 Debugger Client ]
        |                                                    |
   Executes ELF                                        Commands:
   MIPS R5900 Core                                     - db 0x00100020 (breakpoint)
   SPRAM: 0x70000000                                   - dc (continue)
   GS Registers                                        - dr (read registers)
                                                       - pxw 64 @ 0x70000000 (read SPRAM)
```

1. **Verify Static Binary Quality**:
   - Run `r2 -q -c "is" <elf>` to ensure symbol table `.symtab` is intact.
   - Run `r2 -q -c "pdf @ main" <elf>` to inspect emitted MIPS instructions and verify branch delay slots.
2. **Launch PCSX2 with Debugger Enabled**:
   - `pcsx2-qt.exe -gdb 28011 -fastboot game.iso`
3. **Attach radare2 via GDB Client**:
   - `r2 -d gdb://localhost:28011`
4. **Inspect Live State**:
   - Check Program Counter: `dr pc`
   - Check Stack Pointer: `dr sp`
   - Check SPRAM Canary: `pxw 16 @ 0x70000000` (should equal `0xDEADBEEF`)

---

## 4. Mandatory Constraints & Rules

### MUST DO
- **Set Architecture to MIPS 32-bit**: In r2 scripts, always configure:
  `e asm.arch = mips`
  `e asm.bits = 32`
- **Use Non-Interactive Flags (`-q -c`) for Automated Scripts**: In automated tests, run r2 with `-q -c "<commands>"` to avoid blocking on interactive shell prompts.
- **Close STDIN When Spawning r2 Processes on Windows**: radare2 on Windows may block waiting for EOF if standard input is open. Always set `input: Process::Redirect::Close`.
- **Target Physical Memory Addresses When Examining GS/SPRAM**: EE Scratchpad RAM is at `0x70000000`. GS Privileged registers are at `0x12000000`.

### MUST NOT DO
- **Do NOT send naked interactive commands without `-q`**: Spawning bare `r2 <file>` in background subprocesses hangs indefinitely waiting for terminal input.
- **Do NOT assume 64-bit MIPS registers in default GDB stubs**: Many GDB stubs report standard 32-bit register widths (`$v0`, `$a0`, `$pc`, `$sp`); verify with `dr` before indexing 128-bit lanes.
