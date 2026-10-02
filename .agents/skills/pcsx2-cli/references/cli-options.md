# PCSX2 Command Line Options Reference

Complete reference for launching and controlling modern PCSX2 (`pcsx2-qt.exe` v2.x).

---

## 1. Primary Execution Flags

| Flag | Argument | Description |
|:---|:---|:---|
| `-batch` | None | Runs in batch mode; suppresses error prompts and exits when emulation terminates. |
| `-fastboot` | None | Bypasses the PS2 BIOS boot animation and launches game immediately. |
| `-slowboot` | None | Plays full PS2 BIOS boot sequence before executing disc. |
| `-elf` | `<path>` | Directly loads and executes an ELF file from the host filesystem. |
| `-disc` | `<iso_path>` | Mounts and boots a CD/DVD ISO image. |
| `-fullscreen` | None | Launches emulator directly into fullscreen mode. |
| `-nogui` | None | Hides Qt GUI window elements where supported. |
| `-gdb` | `<port>` | Enables GDB remote debugging stub listening on specified TCP port (e.g. `28011`). |
| `-debugger` | None | Opens PCSX2's internal disassembly and memory debugger window. |
| `--` | None | Explicit separator indicating all following tokens are file paths. |

---

## 2. Common Usage Scenarios

### Automated Test / Headless Run
```bash
pcsx2-qt.exe -batch -fastboot "C:\build\artifacts\game.iso"
```

### Direct ELF Execution
```bash
pcsx2-qt.exe -batch -elf "C:\build\artifacts\CITRINE.ELF"
```

### Remote GDB Debugging Session
```bash
pcsx2-qt.exe -gdb 28011 -fastboot "C:\build\artifacts\game.iso"
```

### Custom INI Override
PCSX2 stores configuration settings in `PCSX2.ini`. You can launch with custom profile directories or override settings by pointing `-cfgpath`:
```bash
pcsx2-qt.exe -cfgpath "C:\path\to\custom_config_dir" ...
```
