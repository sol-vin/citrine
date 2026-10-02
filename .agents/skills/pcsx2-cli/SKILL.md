---
name: pcsx2-cli
description: Automates, runs, and troubleshoots the PCSX2 PlayStation 2 emulator from the command line, scripts, and test harnesses. Use when executing PS2 ELFs or ISO disc images in PCSX2, parsing emulog.txt output, configuring GDB stubs, managing headless batch executions, and killing orphaned emulator processes.
license: MIT
metadata:
  author: Citrine Project
  version: "1.0.0"
  domain: emulation-tooling
  triggers: PCSX2, pcsx2-qt, emulog.txt, PS2 emulator, headless PCSX2, GDB stub, -batch, -nogui, -elf, -disc
  role: specialist
  scope: automation
  output-format: text
  related-skills: ps2-dev, r2-ps2-debug
---

# PCSX2 CLI & Automation Specialist

Operational guide for automating the PCSX2 PlayStation 2 emulator, executing tests, parsing diagnostic logs, managing process lifecycles, and configuring debugging interfaces.

---

## 1. Quick Start Commands

```powershell
# Run ISO image in batch mode (exits when emulation halts)
& "C:\Program Files\PCSX2\pcsx2-qt.exe" -batch -fastboot "C:\path\to\game.iso"

# Run standalone ELF executable
& "C:\Program Files\PCSX2\pcsx2-qt.exe" -batch -elf "C:\path\to\game.elf"

# Run with GDB Stub enabled on port 28011
& "C:\Program Files\PCSX2\pcsx2-qt.exe" -gdb 28011 "C:\path\to\game.iso"

# Check live emulation log
Get-Content -Path "$HOME\Documents\PCSX2\logs\emulog.txt" -Tail 40 -Wait
```

---

## 2. Detailed References

Load detailed guides based on execution context:

| Topic | Reference | Content |
|:---|:---|:---|
| CLI Flags & Options | [cli-options.md](./references/cli-options.md) | Command line arguments, boot options, window modes, exit flags |
| Log Analysis & Diagnostics | [log-analysis.md](./references/log-analysis.md) | Parsing `emulog.txt`, verifying ELF entry points, GS modes, crash signatures |
| Process & CI Management | [process-management.md](./references/process-management.md) | Headless execution, Windows process tree termination, file lock prevention |

---

## 3. Core Automation Workflow

1. **Verify Binary Path**: Locate `pcsx2-qt.exe` in `C:\Program Files\PCSX2\`, `%LOCALAPPDATA%\Programs\PCSX2\`, or user `PATH`.
2. **Launch with Target Artifact**:
   - For complete disc games: `-batch -fastboot <iso_path>`
   - For standalone development binaries: `-batch -elf <elf_path>`
3. **Monitor Diagnostic Output**:
   - Tail `emulog.txt` to confirm ELF load:
     `ELF Loading: cdrom0:\<FILE>.ELF;1, EntryPoint = 0x00100000`
   - Confirm GS mode switch:
     `Set GS CRTC configuration. NTSC 640x448 @ 59.940 (59.82) Interlaced (FIELD)`
4. **Clean Process Teardown**:
   - In CI or automated tests, always terminate the full process tree using `taskkill /F /T /PID <pid>` to prevent dangling file locks on ISO images.

---

## 4. Mandatory Constraints & Rules

### MUST DO
- **Use `-batch` for Automated/Test Runs**: Prevents PCSX2 from presenting interactive modal dialogs on halt or exit.
- **Use `-fastboot` to Skip BIOS Splash**: Saves ~5-8 seconds per test run by skipping the Sony boot animation.
- **Kill Entire Process Trees on Windows**: `pcsx2-qt.exe` spawns child helper processes. Standard `Process#kill` may orphan children; use `taskkill /F /T /PID <pid>`.
- **Use Unique File Names for Concurrent/Sequential Runs**: PCSX2 locks open ISO images. Use unique temporary filenames (e.g. `citrine_spec_runner_#{Process.pid}.iso`) in automated test suites.

### MUST NOT DO
- **Do NOT launch without `--` separator if passing trailing positional paths**: Some PCSX2 versions require `--` before target ISO paths when complex flags precede them.
- **Do NOT rely purely on exit code for success**: PCSX2 may return exit code 0 even if an ELF encounters an unhandled exception or enters an infinite loop; always inspect `emulog.txt`.
