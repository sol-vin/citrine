# PCSX2 Log Analysis & Diagnostic Reference

Guidelines for reading and diagnosing execution state from `emulog.txt`.

---

## 1. Log File Location

On Windows, modern PCSX2 writes logs to:
```text
%USERPROFILE%\Documents\PCSX2\logs\emulog.txt
```
or inside portable installs at:
```text
<PCSX2_INSTALL_DIR>\logs\emulog.txt
```

---

## 2. Key Emulation Milestones

### A. BIOS & ISO Mount Verification
Look for ISO mount and file system identification:
```text
CDVD: Opening media: C:\Users\Ian\Documents\citrine\game.iso...
Disc Type: DVD
ISO-9660: Volume ID = 'CITRINE'
```

### B. ELF Loading & Entry Point
Look for loader confirmation that the primary executable was discovered and mapped:
```text
ELF Loading: cdrom0:\CITRINE.ELF;1, EntryPoint = 0x00100000
ELF cdrom0:\CITRINE.ELF;1 with entry point at 0x00100000 is executing.
```
> [!NOTE]
> If `emulog.txt` stops before this line or reports `Cannot find SYSTEM.CNF` or `Please insert a PlayStation or PlayStation 2 format disc`, verify that `SYSTEM.CNF` contains:
> ```ini
> BOOT2 = cdrom0:\CITRINE.ELF;1
> VER = 1.00
> VMODE = NTSC
> ```

### C. GS Display Configuration
Look for confirmation of video mode initialization:
```text
Set GS CRTC configuration. NTSC 640x448 @ 59.940 (59.82) Interlaced (FIELD)
```
This confirms that BIOS syscall `0x02` (`_SetGsCrt`) was invoked with valid parameters.

---

## 3. Recognizing Failures & Errors

| Log Signature | Root Cause | Remedy |
|:---|:---|:---|
| `TLB Miss (load) at 0x...` | Code attempted to read an unmapped virtual address. | Check pointer initialization, buffer bounds, and stack pointer (`$sp`). |
| `Unknown syscall 0x...` | Syscall index in `$v1` is invalid or unsupported by BIOS. | Verify `$v1` encoding before `syscall` instruction. |
| `Cannot find cdrom0:\...` | ISO file table or `SYSTEM.CNF` filename mismatch. | Check ISO9660 filename casing and trailing `;1` version numbers. |
| `GS: read from unallocated memory` | GS PCRTC read circuit pointing to out-of-bounds VRAM block. | Check `DISPFB1` / `DISPFB2` FBP and FBW settings. |
| Black screen with no errors | Read Circuit 1 disabled (`PMODE` bit 0 is 0), or DMA packet not kicking rendering. | Set `PMODE = 0xFF65` or `0xFF67`, verify `XYZ2` kicks and `EOP=1`. |
