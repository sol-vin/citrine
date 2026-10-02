# Radare2 PS2 Commands Cheatsheet

Complete reference for disassembling, analyzing, and navigating PS2 MIPS binaries with radare2.

---

## 1. Environment & Architecture Configuration

```bash
# Set MIPS 32-bit architecture
e asm.arch = mips
e asm.bits = 32
e asm.cpu = r5900         # or mips.gnu

# Display pseudo-syntax instead of raw assembly (optional)
e asm.pseudo = true

# Show opcode bytes alongside disassembly
e asm.bytes = true
```

---

## 2. Information & Symbols (`i`)

| Command | Description |
|:---|:---|
| `iI` | Display ELF binary architecture, endianness, entry point, OS ABI |
| `is` | List all symbols from `.symtab` and `.dynsym` |
| `iS` | List all sections (`.text`, `.rodata`, `.data`, `.spram`, etc.) |
| `iE` | Display ELF entry point address (e.g. `0x00100000`) |
| `iz` | List strings found in data sections |

---

## 3. Disassembly & Code Inspection (`p`)

| Command | Description |
|:---|:---|
| `pdf @ <fn>` | Disassemble full function (e.g. `pdf @ main`, `pdf @ _start`) |
| `pd <N> @ <addr>` | Disassemble `N` instructions starting at `<addr>` |
| `pds @ <fn>` | Summary of function calls, strings, and cross-references |
| `pi <N> @ <addr>` | Print `N` assembly instructions only (no offsets or hex) |

---

## 4. Memory & Hex Inspection (`p`)

| Command | Description |
|:---|:---|
| `px <N> @ <addr>` | Print `N` bytes as standard hex dump |
| `pxw <N> @ <addr>` | Print `N` bytes as 32-bit little-endian words |
| `pxq <N> @ <addr>` | Print `N` bytes as 64-bit doublewords |
| `ps @ <addr>` | Print null-terminated string at `<addr>` |

---

## 5. Navigation & Seeking (`s`)

| Command | Description |
|:---|:---|
| `s <addr>` | Seek cursor to address (e.g. `s 0x00100020`, `s sym.main`) |
| `s-` | Undo previous seek (go back) |
| `s+` | Redo seek (go forward) |
| `sr <reg>` | Seek to value stored in register (e.g. `sr pc`) |

---

## 6. Analysis (`a`)

| Command | Description |
|:---|:---|
| `aa` | Analyze all functions, symbols, and cross-references |
| `aaa` | Deep automated analysis (autoname functions, find preludes) |
| `afl` | List all detected functions with sizes and call counts |
| `afi @ <fn>` | Display function metadata (stack frame size, arguments) |
