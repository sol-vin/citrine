# Radare2 & PCSX2 GDB Remote Debugging Reference

Instructions for connecting radare2 as a GDB client to inspect and control a live PCSX2 emulation session.

---

## 1. Establishing Connection

PCSX2 supports GDB remote debugging via the `-gdb <port>` CLI argument or by configuring `GdbPort` in `PCSX2.ini`.

```bash
# Terminal 1: Launch PCSX2 with GDB stub listening on port 28011
pcsx2-qt.exe -gdb 28011 -fastboot "C:\path\to\game.iso"

# Terminal 2: Attach radare2 via GDB protocol
r2 -d gdb://localhost:28011
```

Once connected, r2 gains direct access to the emulated MIPS R5900 CPU registers, breakpoints, single-stepping, and memory read/write.

---

## 2. Debugging Execution Controls (`d`)

| Command | Action |
|:---|:---|
| `dc` | Continue execution until next breakpoint or halt |
| `ds` | Step into single MIPS instruction |
| `dso` | Step over function call (`jal`) |
| `dsu <addr>` | Step until target address is reached |
| `db <addr>` | Set software breakpoint at address (e.g. `db 0x00100020`) |
| `dbi` | List active breakpoints |
| `db- <addr>` | Remove breakpoint at address |
| `db-*` | Delete all breakpoints |

---

## 3. Register Inspection & Modification (`dr`)

| Command | Action |
|:---|:---|
| `dr` | Print all CPU registers (GPRs `$zero` through `$ra`, `$pc`, `$hi`, `$lo`) |
| `drr` | Print registers with color-coded changes and symbolic references |
| `dr <reg>` | Print value of a single register (e.g. `dr pc`, `dr sp`, `dr v0`) |
| `dr <reg>=<val>`| Modify value of a register (e.g. `dr v0=0x1`) |

---

## 4. Live Memory Inspection via GDB

```bash
# Read 32 bytes from Main RAM entry point
x 32 @ 0x00100000

# Inspect SPRAM (0x70000000) for DEADBEEF canary
pxw 16 @ 0x70000000

# Read current GS Privileged register state (GS_CSR at 0x12001000)
pxq 8 @ 0x12001000
```

---

## 5. Automated GDB Diagnostic Script

You can run non-interactive r2 diagnostic scripts against a live GDB stub:

```bash
r2 -q -d gdb://localhost:28011 -c "db 0x00100020; dc; dr; pxw 16 @ 0x70000000; q"
```
This script:
1. Sets a breakpoint at `main` (`0x00100020`).
2. Continues until `main` is hit.
3. Dumps all CPU registers.
4. Reads the SPRAM canary at `0x70000000`.
5. Quits cleanly.
