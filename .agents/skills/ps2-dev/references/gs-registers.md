# PlayStation 2 Graphics Synthesizer (GS) Registers

Comprehensive reference for GS Privileged Registers (PCRTC display control) and General Purpose Registers (drawing pipeline & primitive state).

---

## 1. Privileged Registers (PCRTC & System Control)

All privileged registers are 64-bit and reside in physical memory starting at `0x12000000`. Access them using 64-bit store (`sd`) and load (`ld`) instructions.

| Register | Address | Description |
|:---|:---|:---|
| `GS_PMODE` | `0x12000000` | PCRTC Mode setting (Circuit enables, CRT output, blending) |
| `GS_SMODE1` | `0x12000010` | Video sync/clock timings (do not modify manually) |
| `GS_SMODE2` | `0x12000020` | Interlace & display mode (`INT=1`, `FFMD=0` for Field / `1` for Frame) |
| `GS_DISPFB1` | `0x12000070` | Read Circuit 1 frame buffer address, width, and format |
| `GS_DISPLAY1`| `0x12000080` | Read Circuit 1 display positioning, magnification, dimensions |
| `GS_DISPFB2` | `0x12000090` | Read Circuit 2 frame buffer address, width, and format |
| `GS_DISPLAY2`| `0x120000A0` | Read Circuit 2 display positioning, magnification, dimensions |
| `GS_BGCOLOR` | `0x120000E0` | Background border color (`R: 0..7, G: 8..15, B: 16..23`) |
| `GS_CSR` | `0x12001000` | System status, reset, VSync interrupt status |
| `GS_IMR` | `0x12001010` | Interrupt Mask Register |
| `GS_BUSDIR` | `0x12001040` | Host interface FIFO direction |

---

## 2. Bitfield Layouts

### GS_PMODE (`0x12000000`)
```text
Bit 0:     EN1       - Enable Read Circuit 1 (1 = ON, 0 = OFF)
Bit 1:     EN2       - Enable Read Circuit 2 (1 = ON, 0 = OFF)
Bits 2..4: CRTMD     - CRT Output Switching mode (always set to 1)
Bit 5:     MMOD      - Alpha value selection (0 = Circuit 1, 1 = blend_value)
Bit 6:     AMOD      - Output alpha selection (0 = Circuit 1, 1 = Circuit 2)
Bit 7:     SLBG      - Blend style (0 = blend with Circuit 2, 1 = blend with BGCOLOR)
Bits 8..15:ALP       - Fixed Alpha blend factor (0x00 - 0xFF)
Bit 16:    EXSYNC    - External sync mode
```
> [!IMPORTANT]
> **Recommended PMODE Setting**:
> - `0xFF65`: `EN1=1, EN2=0, CRTMD=1, MMOD=1, AMOD=1, SLBG=0, ALP=0xFF` (Circuit 1 Only)
> - `0xFF67`: `EN1=1, EN2=1, CRTMD=1, MMOD=1, AMOD=1, SLBG=0, ALP=0xFF` (Both Circuits Active)
> Setting `0xFF62` disables Read Circuit 1, causing blank/black screen outputs in PCSX2!

### GS_DISPFB1 / GS_DISPFB2 (`0x12000070` / `0x12000090`)
```text
Bits 0..8:   FBP     - Frame Buffer Pointer (Word address / 2048, or page index in blocks)
Bits 9..14:  FBW     - Frame Buffer Width in units of 64 pixels (e.g. 640 px = 10 blocks)
Bits 15..19: PSM     - Pixel Storage Mode:
                       0 = PSMCT32 (RGBA 32-bit)
                       1 = PSMCT24 (RGB 24-bit)
                       2 = PSMCT16 (RGB 16-bit 5:5:5:1)
Bits 32..42: DBX     - Display Buffer X offset in VRAM
Bits 43..53: DBY     - Display Buffer Y offset in VRAM
```
*Standard 640x448 32-bit frame at base 0*: `FBP = 0, FBW = 10, PSM = 0 -> Value = (10 << 9) = 0x1400`.

### GS_DISPLAY1 / GS_DISPLAY2 (`0x12000080` / `0x120000A0`)
```text
Bits 0..11:  DX      - Display Area X position on CRT beam (centering offset, e.g. 656)
Bits 12..22: DY      - Display Area Y position on CRT beam (e.g. 36)
Bits 23..26: MAGH    - Horizontal magnification factor (0..15 -> scale = MAGH + 1)
Bits 27..28: MAGV    - Vertical magnification factor (0 = 1x, 1 = 2x)
Bits 32..43: DW      - Display Area Width in CRT beam ticks (e.g. (640 * 4) - 1 = 2559 = 0x9FF)
Bits 44..54: DH      - Display Area Height in CRT scanlines (e.g. 448 - 1 = 447 = 0x1BF)
```
*Standard NTSC 640x448 DISPLAY Value*:
- Lower 32 bits: `(0 << 27) | (3 << 23) | (36 << 12) | 656 = 0x01824290`
- Upper 32 bits: `(447 << 12) | 2559 = 0x001BF9FF`
- Full 64-bit value: `0x001BF9FF01824290`

---

## 3. Drawing Environment Registers (Context 1)

These registers are configured through GIF packets using register address offset in A+D mode (`0x0E`).

| Register | Offset | Format | Description |
|:---|:---|:---|:---|
| `FRAME_1` | `0x4C` | `(FBMSK<<32) | (PSM<<24) | (FBW<<16) | FBP` | Drawing frame buffer address and mask |
| `ZBUF_1` | `0x4E` | `(ZMSK<<32) | (PSM<<24) | ZBP` | Z-Buffer address and mask |
| `XYOFFSET_1`| `0x18`| `(OFY<<32) | OFX` | 16-bit coordinate center offset (2048 - w/2) * 16 |
| `SCISSOR_1` | `0x40` | `(SCAY1<<48) | (SCAX1<<16) | (SCAY0<<32) | SCAX0` | Clipping boundary rectangle |
| `PRMODECONT`| `0x1A` | `1` | Use primitive attributes from `PRIM` (0) or `PRMODE` (1) |
| `COLCLAMP` | `0x46` | `1` | Clamp color values to [0, 255] |
| `TEST_1` | `0x47` | `(ZTST<<17) | (ZTE<<16) | (ATST<<1) | ATE` | Depth & Alpha pixel test settings |

### Recommended Standard 640x448 Environment Packet
```text
1. FRAME_1    (0x4C): 0x000A0000 (FBP=0, FBW=10 [640px], PSM=0, FBMSK=0)
2. ZBUF_1     (0x4E): 0x0000008C (ZBP=140, PSM=0, ZMSK=0)
3. XYOFFSET_1 (0x18): (30976 << 32) | 27648 (OFX = 1728*16, OFY = 1936*16)
4. SCISSOR_1  (0x40): (447 << 48) | (639 << 16) (X0=0, Y0=0, X1=639, Y1=447)
5. PRMODECONT (0x1A): 1 (Enable primitive mode control)
6. COLCLAMP   (0x46): 1 (Enable color clamping)
7. TEST_1     (0x47): 0x00030000 (ZTE=1, ZTST=1 [ALWAYS pass depth test])
```

---

## 4. Drawing Primitives & Vertex Submission

GS supports primitives via `PRIM` (`0x00`):
- `0`: Point
- `1`: Line
- `2`: LineStrip
- `3`: Triangle
- `4`: TriangleStrip
- `5`: TriangleFan
- `6`: Sprite (2D axis-aligned rectangle)

### Drawing a 2D Sprite
A sprite is defined by two vertices:
1. **Set `PRIM` (`0x00`)**: `6 | (0 << 9)` (Sprite, Context 1)
2. **Set `RGBAQ` (`0x01`)**: `(Q << 32) | (A << 24) | (B << 16) | (G << 8) | R` (Q is IEEE 754 float `1.0f = 0x3F800000`)
3. **Vertex 1 (Upper-Left)**:
   - X1: `((1728 + x1) << 4) & 0xFFFF`
   - Y1: `((1936 + y1) << 4) & 0xFFFF`
   - Send to `XYZ2` (`0x05`) or `XYZ3` (`0x0D`)
4. **Vertex 2 (Lower-Right)**:
   - X2: `((1728 + x2) << 4) & 0xFFFF`
   - Y2: `((1936 + y2) << 4) & 0xFFFF`
   - Send to `XYZ2` (`0x05`) -> **Triggers GS Drawing Kick!**
