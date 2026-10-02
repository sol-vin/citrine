# Citrine Tooling & Radare2 Integration

How radare2 is integrated into the Citrine CLI (`citrine debug`), test suites, and bytecode symbol inspection.

---

## 1. Citrine Bytecode & Symbol Mapping

Citrine produces two compilation artifacts:
1. `.cbc`: Citrine Bytecode binary format (`CBC1` magic header, function table, draw command stream).
2. `.cbcsym`: Bytecode Symbol Table (JSON format mapping bytecode offsets to source code filenames, line numbers, function names, and variable names).

When Citrine builds a standalone PS2 ELF executable via `Citrine::ISO::ElfBuilder`:
- Native MIPS stubs are injected for Citrine VM API functions (`Citrine_VM_Run`, `Citrine_DrawRectangle`, etc.).
- ELF symbol tables (`.symtab` and `.strtab`) are embedded into the ELF.
- `r2` automatically extracts and displays these symbols.

---

## 2. Using `citrine debug`

Citrine includes a built-in debugging bridge:
```bash
citrine debug examples/05_hello_world/main.cr --port 28011
```
This command:
1. Compiles the Crystal source into bytecode and builds the runner ELF / ISO.
2. Spawns PCSX2 with `-gdb 28011`.
3. Launches `r2` connected to `gdb://localhost:28011`.
4. Loads symbol mappings from `.cbcsym`.

---

## 3. Automated Radare2 Testing in Crystal

When calling `r2` from automated test harnesses (`spec/r2_iso_symbols_spec.cr`):

### Windows Pipe Deadlock Prevention
On Windows, launching `Process.new("r2.exe", ...)` without redirecting stdin can cause `r2` to wait for stdin EOF, hanging the test suite indefinitely.

```crystal
# Correct pattern: Close stdin and execute commands with -q -c
stdout = IO::Memory.new
process = Process.new(
  "r2.exe",
  ["-q", "-c", "is", elf_path],
  input: Process::Redirect::Close,
  output: stdout,
  error: Process::Redirect::Close
)
status = process.wait
output = stdout.to_s
```

### Verifying Symbols in Test Assertions
```crystal
it "exports global symbols in ELF symtab" do
  output = run_r2_command(elf_path, "is")
  output.should contain("main")
  output.should contain("_start")
  output.should contain("dma_reset")
  output.should contain("g_spram_base")
end
```
