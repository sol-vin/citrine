# Radare2 PlayStation 2 (EE MIPS R5900 + GS + DMAC) Plugin Script
# Version: 1.0.0 - Citrine Toolkit PS2 Architecture Plugin

# ==============================================================================
# 1. Architecture & Disassembly Environment
# ==============================================================================
e asm.arch = mips
e asm.bits = 32
e asm.cpu = mips3
e asm.pseudo = true
e asm.bytes = true
e asm.flags = true
e asm.lines = true
e asm.xrefs = true

# ==============================================================================
# 2. PlayStation 2 Hardware Memory Map Flags
# ==============================================================================

# Emotion Engine (EE) Core RAM Segments
f mem.kuseg_cached   = 0x00000000
f mem.kuseg_uncached = 0x20000000
f mem.kuseg_accel    = 0x30000000
f mem.kseg0          = 0x80000000
f mem.kseg1          = 0xA0000000

# EE Scratchpad RAM (SPRAM) - 16 KB Fast Local RAM
f spram.base         = 0x70000000
f spram.canary       = 0x70000000
f spram.frame_count  = 0x70000004
f spram.vm_status    = 0x70000008
f spram.end          = 0x70004000
f spram.size         = 0x4000

# Graphics Synthesizer (GS) Privileged Control Registers (0x12000000 - 0x12001080)
f gs.pmode           = 0x12000000 # PCRTC Mode setting (EN1, EN2, CRTMD, MMOD, AMOD, SLBG, ALP)
f gs.smode1          = 0x12000010 # Video sync/clock timings
f gs.smode2          = 0x12000020 # Interlace & field/frame mode
f gs.srfsh           = 0x12000030 # DRAM refresh
f gs.synch1          = 0x12000040 # H-Sync timing 1
f gs.synch2          = 0x12000050 # H-Sync timing 2
f gs.syncv           = 0x12000060 # V-Sync timing
f gs.dispfb1         = 0x12000070 # Read Circuit 1 frame buffer base & width
f gs.display1        = 0x12000080 # Read Circuit 1 CRT display position & magnification
f gs.dispfb2         = 0x12000090 # Read Circuit 2 frame buffer base & width
f gs.display2        = 0x120000A0 # Read Circuit 2 CRT display position & magnification
f gs.extbuf          = 0x120000B0 # External buffer control
f gs.extdata         = 0x120000C0 # External data write
f gs.extwrite        = 0x120000D0 # External write control
f gs.bgcolor         = 0x120000E0 # Background border color (RGB 24-bit)
f gs.csr             = 0x12001000 # GS System status & interrupt reset
f gs.imr             = 0x12001010 # Interrupt mask register
f gs.busdir          = 0x12001040 # Host interface bus direction (0=EE->GS, 1=GS->EE)
f gs.siglblid        = 0x12001080 # Signal / Label ID

# Direct Memory Access Controller (DMAC) Registers
f dmac.chcr2         = 0x1000A000 # Channel 2 (GIF) Channel Control Register
f dmac.madr2         = 0x1000A010 # Channel 2 Memory Address (Physical EE RAM)
f dmac.qwc2          = 0x1000A020 # Channel 2 Quadword Count (16-byte units)
f dmac.tadr2         = 0x1000A030 # Channel 2 Tag Address (Chain mode)
f dmac.d_ctrl        = 0x1000E000 # DMAC Global Control Register (DMAE master enable)
f dmac.d_stat        = 0x1000E010 # DMAC Status / Interrupt Flags
f dmac.d_pcr         = 0x1000E020 # DMAC Priority Control Register

# ==============================================================================
# 3. Formats & Struct Definitions (pf)
# ==============================================================================

# GS Privileged PMODE Register (64-bit)
pf.gs_pmode ww (qword)raw (dword)low (dword)high

# GS DISPFB Register (64-bit)
pf.gs_dispfb ww (qword)raw (dword)fbp_fbw_psm (dword)dbx_dby

# GS DISPLAY Register (64-bit)
pf.gs_display ww (qword)raw (dword)dx_dy_mag (dword)dw_dh

# 128-bit GIFTag
pf.giftag qq (qword)low_nloop_eop_flg (qword)high_regs

# ==============================================================================
# 4. Helper Macros
# ==============================================================================

# ps2_info: Display binary metadata and entry point
(ps2_info; iI; iS; iE)

# ps2_spram: Dump SPRAM canary at 0x70000000
(ps2_spram; pxw 32 @ 0x70000000)

# ps2_regs: Dump GS privileged registers
(ps2_regs; pxq 16 @ 0x12000000; pxq 16 @ 0x12001000)

# ps2_dmac: Dump DMAC Channel 2 and Global registers
(ps2_dmac; pxw 16 @ 0x1000A000; pxw 16 @ 0x1000E000)

# ps2_disasm: Disassemble main routines
(ps2_disasm; pd 8 @ 0x00100000; pd 20 @ 0x00100020)
