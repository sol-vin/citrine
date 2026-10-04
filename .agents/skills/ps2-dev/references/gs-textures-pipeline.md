# PlayStation 2 Graphics Synthesizer (GS) Texture & Rasterization Pipeline

Comprehensive guide to GS 4 MB embedded DRAM (eDRAM) layout, pixel and texture formats, CLUT palette swizzling, mipmap LOD calculation, and dual-context rendering.

---

## 1. 4 MB Embedded DRAM (eDRAM) Architecture

The Graphics Synthesizer integrates 4 MB of ultra-wide eDRAM connected to the rasterizer via a 2560-bit bus (48 GB/s bandwidth):

- **Memory Structure**: Divided into **512 pages** (or 2048 blocks).
- **Page Size**: 8 KB (2048 32-bit words).
- **Block Size**: 256 bytes (64 32-bit words). Each page contains 32 blocks.
- **Addressing**:
  - Buffer Base Pointer (`FBP` / `TBP` / `ZBP`) is specified in **multiples of 32 blocks** (i.e. page units: `address / 8192` or `address / 2048` words).
  - Buffer Width (`FBW` / `TBW`) is specified in **multiples of 64 pixels** (`width / 64`).

---

## 2. GS Pixel & Texture Formats

| Format Code | Name | Bit Depth | Description & Layout |
|:---|:---|:---|:---|
| `0x00` | `PSMCT32` | 32-bit | RGBA 8:8:8:8 (R:0..7, G:8..15, B:16..23, A:24..31) |
| `0x01` | `PSMCT24` | 24-bit | RGB 8:8:8 (stored in 32-bit words; upper 8 bits preserved or masked) |
| `0x02` | `PSMCT16` | 16-bit | RGBA 1:5:5:5 (R:0..4, G:5..9, B:10..14, A:15) |
| `0x0A` | `PSMCT16S`| 16-bit | Signed RGBA 1:5:5:5 |
| `0x13` | `PSMT8`   | 8-bit  | 8-bit indexed texture (requires 256-color CLUT) |
| `0x14` | `PSMT4`   | 4-bit  | 4-bit indexed texture (requires 16-color CLUT) |
| `0x30` | `PSMZ32`  | 32-bit | 24-bit Z-depth in 32-bit container |
| `0x31` | `PSMZ24`  | 24-bit | 24-bit integer Z-depth |
| `0x32` | `PSMZ16`  | 16-bit | 16-bit unsigned integer Z-depth |

---

## 3. The Infamous PS2 CLUT Swizzle (8-bit / 4-bit Textures)

### The Hardware Quirk
When using indexed textures (`PSMT8` / 8-bit palette), the GS hardware does **not** read palette entries in linear 0..255 order in `CSM1` mode!
Instead, within every 32 entries of the CLUT, **entries 8..15 and 16..23 are swapped**:

```text
Linear Palette Order:
[0..7]   [8..15]   [16..23]   [24..31] ...
Hardware CLUT Order (CSM1):
[0..7]   [16..23]  [8..15]    [24..31] ...
```

If an unswizzled palette is uploaded to eDRAM, textures appear with inverted or scrambled middle-band colors.

### The Swizzle Algorithm (CPU Pre-Processing)
Convert a linear 256-color 32-bit palette into the GS hardware swizzled format before uploading:

```crystal
# Swizzle 256-color RGBA palette for PSMT8 in Crystal / C
def swizzle_palette_psmt8(linear_clut : Slice(UInt32), swizzled_clut : Slice(UInt32))
  (0...256).each do |i|
    # Swizzle bit 3 (val 8) and bit 4 (val 16)
    target_idx = (i & ~0x18) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
    swizzled_clut[target_idx] = linear_clut[i]
  end
end
```

In C:
```c
uint32_t swizzle_clut_index(uint32_t index) {
    return (index & ~0x18) | ((index & 0x08) << 1) | ((index & 0x10) >> 1);
}
```

### CSM1 vs CSM2 Storage Modes
- **`CSM1` (Column Storage Mode 1)**: Palette is stored in a 32-bit framebuffer/texture page (`PSMCT32`). Requires the 32-entry swizzle shown above.
- **`CSM2` (Column Storage Mode 2)**: Palette is stored linearly in eDRAM, but requires 64-byte alignment restrictions and cannot be reloaded as a standard texture.

---

## 4. Texture Mapping & Register Configuration

### `TEX0_1` Register (`0x06`)
Sets base texture configuration for Context 1:
- `TBP0` [0:13]: Texture base page pointer (`address >> 8` in 256-byte blocks).
- `TBW` [14:19]: Texture buffer width (`width / 64`).
- `PSM` [20:25]: Pixel storage mode (`0x00=PSMCT32`, `0x13=PSMT8`, `0x14=PSMT4`).
- `TW` [26:29]: Texture width exponent (`width = 2^TW`).
- `TH` [30:33]: Texture height exponent (`height = 2^TH`).
- `TCC` [34]: Texture color component (`0=RGB`, `1=RGBA`).
- `TFX` [35:36]: Texture function (`0=MODULATE`, `1=DECAL`, `2=HIGHLIGHT`, `3=HIGHLIGHT2`).
- `CBP` [37:50]: CLUT buffer pointer (`clut_address >> 8`).
- `CPSM` [51:54]: CLUT storage mode (`0x00=PSMCT32`, `0x02=PSMCT16`).
- `CSM` [55]: CLUT storage mode (`0=CSM1`, `1=CSM2`).
- `CSA` [56:60]: CLUT entry offset.
- `CLD` [61:63]: CLUT load control (`0=do not load`, `1=load into cache`).

### `CLAMP_1` Register (`0x08`)
Controls texture wrapping, clamping, and texture coordinate masking:
- `WMS` [0:1]: Wrap mode horizontal (`0=REPEAT`, `1=CLAMP`, `2=REGION_CLAMP`, `3=REGION_REPEAT`).
- `WMT` [2:3]: Wrap mode vertical.
- `MINU` [4:13], `MAXU` [14:23]: U coordinate clamping boundary.
- `MINV` [24:33], `MAXV` [34:43]: V coordinate clamping boundary.

---

## 5. Mipmapping & Signed S7.4 LOD Calculation

The GS supports up to 7 mipmap levels ($L_0$ to $L_6$).

### Base & Mipmap Table Registers
- `TEX1_1` (`0x14`): Controls mipmapping mode:
  - `LCM` [0]: LOD calculation method (`0=Formula`, `1=Fixed K`).
  - `MXL` [2:4]: Maximum mip level (0 to 6).
  - `MMAG` [5]: Texture magnification filter (`0=Nearest`, `1=Linear`).
  - `MMIN` [6:8]: Texture minification filter:
    - `0=Nearest`, `1=Linear`
    - `2=Nearest Mipmap Nearest`, `3=Nearest Mipmap Linear`
    - `4=Linear Mipmap Nearest`, `5=Linear Mipmap Linear`
  - `K` [32:43]: **12-bit signed fixed-point constant ($S7.4$)**:
    - Range: $-2048$ to $+2047$ (representing $-128.0$ to $+127.9375$).
    - Calculation in software: `K_reg = (int)(k_float * 16.0f) & 0xFFF`.

### Formula for Mipmap Level Calculation
$$\text{LOD} = \left(\log_2\left(\frac{1}{|Q|}\right) \times 2^L\right) + K$$
When $\text{LOD} \le 0$, level 0 is used. When $0 < \text{LOD} < \text{MXL}$, interpolation occurs between levels.

---

## 6. Dual GS Context Optimization (Handbook Ch. 25)

The GS provides two distinct drawing contexts: **Context 1** and **Context 2**.
Every drawing register exists in duplicate (`FRAME_1` / `FRAME_2`, `ZBUF_1` / `ZBUF_2`, `TEST_1` / `TEST_2`, `TEX0_1` / `TEX0_2`, `XYOFFSET_1` / `XYOFFSET_2`).

### Architectural Advantage
Instead of flushing registers when alternating between 3D world rendering and 2D HUD/overlay passes:
1. **Context 1**: Bound to 3D perspective pipeline:
   - Z-buffer testing enabled (`ZTE=1`, `ZTST=GEQUAL`), alpha testing on, perspective texture correction (`Q`).
2. **Context 2**: Bound to 2D HUD, font, and UI overlay:
   - Z-buffer writes disabled (`ZTE=0`), alpha blending set to constant UI blend, linear screen coordinates.
3. Switch contexts instantaneously with a single bit in the `PRIM` packet (`CONTEXT=0` or `CONTEXT=1`). Zero pipeline stalls, zero redundant register uploads!
