# Citrine PlayStation 2 DMA & GIF Core Engine (Tier 1)
# Pure, strongly-typed structs, state machines, and zero-allocation packet buffers
# targeting the Emotion Engine DMAC (10 channels) and Graphics Interface (GIF).

require "io/memory"

module Citrine
  annotation ZeroAllocation
  end

  module Core
    module DMA
      # =========================================================================
      # Hardware Constants & Memory Segment Masks
      # =========================================================================

      # Maximum 16-bit QuadWord Count (QWC) allowed in a single DMAC hardware transfer.
      MAX_QWC = 65535_u32

      # Safe QWC limit leaving headroom for source-chain and sync tags.
      SAFE_QWC = 65500_u32

      # Maximum 15-bit NLOOP count in a single 128-bit GIFTag.
      MAX_NLOOP = 32767_u32

      # KUSEG Physical RAM mask (32 MB: 0x00000000 - 0x01FFFFFF).
      PHYSICAL_RAM_MASK = 0x01FFFFFF_u32

      # KUSEG Uncached mirror base (0x20000000).
      UNCACHED_BASE = 0x20000000_u32

      # KUSEG Uncached Accelerated mirror base (0x30000000) for write-combined DMA buffers.
      UNCACHED_ACCEL_BASE = 0x30000000_u32

      # KSEG1 Kernel Uncached mirror base (0xA0000000).
      KSEG1_BASE = 0xA0000000_u32

      # Scratchpad RAM (SPRAM) base address (16 KB: 0x70000000 - 0x70003FFF).
      SPRAM_BASE = 0x70000000_u32
      SPRAM_SIZE = 0x00004000_u32

      # =========================================================================
      # Enumerations (DMAC Channels, Modes, Tag IDs, GIF & GS Registers)
      # =========================================================================

      # PlayStation 2 10-Channel Direct Memory Access Controller (DMAC) Channels.
      enum Channel : UInt8
        VIF0     = 0_u8 # Vector Interface 0 (EE -> VU0)
        VIF1     = 1_u8 # Vector Interface 1 (EE <-> VU1 / GIF Path 2)
        GIF      = 2_u8 # Graphics Interface (EE -> GS Path 3)
        IPU_FROM = 3_u8 # Image Processing Unit output (IPU -> EE)
        IPU_TO   = 4_u8 # Image Processing Unit input (EE -> IPU)
        SIF0     = 5_u8 # Subsystem Interface 0 (IOP -> EE)
        SIF1     = 6_u8 # Subsystem Interface 1 (EE -> IOP)
        SIF2     = 7_u8 # Subsystem Interface 2 (Bidirectional debug/control)
        SPR_FROM = 8_u8 # Scratchpad RAM -> Main RAM
        SPR_TO   = 9_u8 # Main RAM -> Scratchpad RAM

        # Returns the physical base I/O register address (`Dn_CHCR`) for this channel.
        def chcr_addr : UInt32
          case self
          when .vif0?     then 0x10008000_u32
          when .vif1?     then 0x10009000_u32
          when .gif?      then 0x1000A000_u32
          when .ipu_from? then 0x1000B000_u32
          when .ipu_to?   then 0x1000B400_u32
          when .sif0?     then 0x1000C000_u32
          when .sif1?     then 0x1000C400_u32
          when .sif2?     then 0x1000C800_u32
          when .spr_from? then 0x1000D000_u32
          when .spr_to?   then 0x1000D400_u32
          else                 0x1000A000_u32
          end
        end

        # Returns the Memory Address Register (`Dn_MADR`) physical address.
        def madr_addr : UInt32
          chcr_addr + 0x10_u32
        end

        # Returns the Quadword Count Register (`Dn_QWC`) physical address.
        def qwc_addr : UInt32
          chcr_addr + 0x20_u32
        end

        # Returns the Tag Address Register (`Dn_TADR`) physical address.
        def tadr_addr : UInt32
          chcr_addr + 0x30_u32
        end

        # Returns the Scratchpad Address Register (`Dn_SADR`) physical address (for SPR channels).
        def sadr_addr : UInt32
          chcr_addr + 0x80_u32
        end
      end

      # DMAC Transfer Direction (`CHCR.DIR`).
      enum Direction : UInt8
        ToMemory   = 0_u8 # Peripheral / FIFO -> Main RAM
        FromMemory = 1_u8 # Main RAM -> Peripheral / FIFO (Standard for GIF/VIF1)
      end

      # DMAC Operating Mode (`CHCR.MOD`).
      enum TransferMode : UInt8
        Normal     = 0_u8 # Contiguous linear block of QWC quadwords
        Chain      = 1_u8 # Source/Destination chain driven by 128-bit DMATags
        Interleave = 2_u8 # Rectangular stride transfer
      end

      # Source-Chain 128-bit DMATag ID (`ID` bits 28..30).
      enum DmaTagId : UInt8
        Refe = 0_u8 # Transfer QWC from ADDR, then terminate chain
        Cnt  = 1_u8 # Transfer QWC following tag, then read next tag after data
        Next = 2_u8 # Transfer QWC following tag, then read next tag at ADDR
        Ref  = 3_u8 # Transfer QWC from ADDR, then read next tag following this tag
        Refs = 4_u8 # Transfer QWC from ADDR with stall control, then next tag
        Call = 5_u8 # Transfer QWC following tag, push next addr to ASR, jump to ADDR
        Ret  = 6_u8 # Transfer QWC following tag, pop next tag address from ASR
        End  = 7_u8 # Transfer QWC following tag, then terminate chain
      end

      # 128-bit GIFTag Data Format (`FLG` bits 58..59).
      enum GifFormat : UInt8
        Packed  = 0_u8 # Packed register descriptors (including 0x0E A+D mode)
        RegList = 1_u8 # 64-bit packed register pairs
        Image   = 2_u8 # Raw GS VRAM pixel transfer (after BITBLTBUF/TRXREG/TRXDIR)
        Disable = 3_u8 # Same as Image mode in hardware
      end

      # 4-bit GIF Packed Register Descriptors (bits 64..127 of GIFTag).
      enum GifReg : UInt8
        Prim    = 0x00_u8
        Rgbaq   = 0x01_u8
        St      = 0x02_u8
        Uv      = 0x03_u8
        Xyzf2   = 0x04_u8
        Xyz2    = 0x05_u8
        Tex0_1  = 0x06_u8
        Tex0_2  = 0x07_u8
        Clamp_1 = 0x08_u8
        Clamp_2 = 0x09_u8
        Fog     = 0x0A_u8
        Xyzf3   = 0x0C_u8
        Xyz3    = 0x0D_u8
        AD      = 0x0E_u8 # Address + Data (64-bit data + 8-bit GS register address)
        Nop     = 0x0F_u8
      end

      # Graphics Synthesizer (GS) General Purpose Drawing Registers (via GIF A+D 0x0E).
      enum GsReg : UInt8
        Prim       = 0x00_u8
        Rgbaq      = 0x01_u8
        St         = 0x02_u8
        Uv         = 0x03_u8
        Xyzf2      = 0x04_u8
        Xyz2       = 0x05_u8
        Tex0_1     = 0x06_u8
        Tex0_2     = 0x07_u8
        Clamp_1    = 0x08_u8
        Clamp_2    = 0x09_u8
        Fog        = 0x0A_u8
        Xyzf3      = 0x0C_u8
        Xyz3       = 0x0D_u8
        Tex1_1     = 0x14_u8
        Tex1_2     = 0x15_u8
        Tex2_1     = 0x16_u8
        Tex2_2     = 0x17_u8
        Xyoffset_1 = 0x18_u8
        Xyoffset_2 = 0x19_u8
        Prmodecont = 0x1A_u8
        Prmode     = 0x1B_u8
        Texclut    = 0x1C_u8
        Scanmsk    = 0x22_u8
        Miptbp1_1  = 0x34_u8
        Miptbp1_2  = 0x35_u8
        Miptbp2_1  = 0x36_u8
        Miptbp2_2  = 0x37_u8
        Texa       = 0x3B_u8
        Fogcol     = 0x3D_u8
        Texflush   = 0x3F_u8
        Scissor_1  = 0x40_u8
        Scissor_2  = 0x41_u8
        Alpha_1    = 0x42_u8
        Alpha_2    = 0x43_u8
        Dimx       = 0x44_u8
        Dthe       = 0x45_u8
        Colclamp   = 0x46_u8
        Test_1     = 0x47_u8
        Test_2     = 0x48_u8
        Pabe       = 0x49_u8
        Fba_1      = 0x4A_u8
        Fba_2      = 0x4B_u8
        Frame_1    = 0x4C_u8
        Frame_2    = 0x4D_u8
        Zbuf_1     = 0x4E_u8
        Zbuf_2     = 0x4F_u8
        Bitbltbuf  = 0x50_u8
        Trxpos     = 0x51_u8
        Trxreg     = 0x52_u8
        Trxdir     = 0x53_u8
        Hwreg      = 0x54_u8
        Signal     = 0x60_u8
        Finish     = 0x61_u8
        Label      = 0x62_u8
      end

      # GS Primitive Types (`PRIM` register bits 0..2).
      enum Primitive : UInt8
        Point         = 0_u8
        Line          = 1_u8
        LineStrip     = 2_u8
        Triangle      = 3_u8
        TriangleStrip = 4_u8
        TriangleFan   = 5_u8
        Sprite        = 6_u8
      end

      # GS Pixel Storage Modes (`PSM`).
      enum PixelFormat : UInt8
        PSMCT32  = 0x00_u8 # 32-bit RGBA (8-8-8-8)
        PSMCT24  = 0x01_u8 # 24-bit RGB (packed in 32-bit words)
        PSMCT16  = 0x02_u8 # 16-bit RGBA (5-5-5-1)
        PSMCT16S = 0x0A_u8 # 16-bit Swizzled RGBA
        PSMT8    = 0x13_u8 # 8-bit Indexed CLUT
        PSMT4    = 0x14_u8 # 4-bit Indexed CLUT
        PSMT8H   = 0x1B_u8 # 8-bit Indexed in upper 8 bits of 32-bit word
        PSMT4HL  = 0x24_u8 # 4-bit Indexed in bits 24..27
        PSMT4HH  = 0x2C_u8 # 4-bit Indexed in bits 28..31
        PSMZ32   = 0x30_u8 # 32-bit Z-buffer
        PSMZ24   = 0x31_u8 # 24-bit Z-buffer
        PSMZ16   = 0x32_u8 # 16-bit Z-buffer
        PSMZ16S  = 0x3A_u8 # 16-bit Swizzled Z-buffer
      end

      # =========================================================================
      # Core Value Structs (128-bit Quadword, ChannelControl, DmaTag, GifTag)
      # =========================================================================

      # 128-bit (16-byte) aligned hardware quadword value (`lo` 64-bit, `hi` 64-bit).
      struct Quadword
        property lo : UInt64
        property hi : UInt64

        def initialize(@lo : UInt64 = 0_u64, @hi : UInt64 = 0_u64)
        end

        # Creates a Quadword representing a GIF A+D (Address + Data) register write.
        def self.ad(reg : GsReg | UInt8, data : UInt64) : Quadword
          reg_val = reg.is_a?(GsReg) ? reg.value.to_u64 : reg.to_u64
          Quadword.new(data, reg_val)
        end

        # Encodes this 128-bit quadword to an IO in little-endian byte order.
        def write_to(io : IO) : Nil
          io.write_bytes(@lo, IO::ByteFormat::LittleEndian)
          io.write_bytes(@hi, IO::ByteFormat::LittleEndian)
        end

        # Decodes a 128-bit quadword from a 16-byte slice.
        def self.from_slice(slice : Bytes) : Quadword
          lo = IO::ByteFormat::LittleEndian.decode(UInt64, slice[0, 8])
          hi = IO::ByteFormat::LittleEndian.decode(UInt64, slice[8, 8])
          Quadword.new(lo, hi)
        end
      end

      # 32-bit DMAC Channel Control Register (`Dn_CHCR`) bitfield representation.
      struct ChannelControl
        getter direction : Direction
        getter mode : TransferMode
        getter asp : UInt8
        getter tte : Bool
        getter tie : Bool
        getter start : Bool
        getter tag_bits : UInt16

        def initialize(
          @direction : Direction = Direction::FromMemory,
          @mode : TransferMode = TransferMode::Normal,
          @asp : UInt8 = 0_u8,
          @tte : Bool = false,
          @tie : Bool = false,
          @start : Bool = true,
          @tag_bits : UInt16 = 0_u16,
        )
        end

        # Encodes the `Dn_CHCR` 32-bit hardware register word:
        # - Bit 0: `DIR` (0 = To Memory, 1 = From Memory)
        # - Bits 2..3: `MOD` (0 = Normal, 1 = Chain, 2 = Interleave)
        # - Bits 4..5: `ASP` (Address stack pointer for CALL/RET)
        # - Bit 6: `TTE` (Tag Transfer Enable)
        # - Bit 7: `TIE` (Tag Interrupt Enable)
        # - Bit 8: `STR` (Start/Busy flag)
        # - Bits 16..31: `TAG` (Upper bits of most recently read DMA tag)
        def encode : UInt32
          val = @direction.value.to_u32 & 0x1_u32
          val |= ((@mode.value.to_u32 & 0x3_u32) << 2)
          val |= ((@asp.to_u32 & 0x3_u32) << 4)
          val |= (1_u32 << 6) if @tte
          val |= (1_u32 << 7) if @tie
          val |= (1_u32 << 8) if @start
          val |= (@tag_bits.to_u32 << 16)
          val
        end

        # Standard Normal Mode Start value (`0x101`: `STR=1, MOD=Normal, DIR=FromMemory`).
        def self.normal_start : ChannelControl
          ChannelControl.new(direction: Direction::FromMemory, mode: TransferMode::Normal, start: true)
        end

        # Standard Source-Chain Mode Start value (`0x105`: `STR=1, MOD=Chain, DIR=FromMemory`).
        def self.chain_start(tte : Bool = false, tie : Bool = false) : ChannelControl
          ChannelControl.new(direction: Direction::FromMemory, mode: TransferMode::Chain, tte: tte, tie: tie, start: true)
        end
      end

      # 128-bit Source-Chain DMATag (`lo` 64-bit DMA control & address, `hi` 64-bit optional VIFcodes or 0).
      struct DmaTag
        getter qwc : UInt16
        getter pce : UInt8
        getter id : DmaTagId
        getter irq : Bool
        getter addr : UInt32
        getter spr : Bool
        getter opt_hi : UInt64

        def initialize(
          @qwc : UInt16,
          @id : DmaTagId = DmaTagId::Cnt,
          @addr : UInt32 = 0_u32,
          @irq : Bool = false,
          @pce : UInt8 = 0_u8,
          @spr : Bool = false,
          @opt_hi : UInt64 = 0_u64,
        )
          if (@addr & 0xF_u32) != 0_u32
            raise ArgumentError.new("DMATag address (0x#{@addr.to_s(16)}) must be 16-byte (128-bit) aligned")
          end
        end

        # Encodes the lower 64 bits of the 128-bit DMATag:
        # - Bits 0..15: `QWC` (Quadword count)
        # - Bits 26..27: `PCE` (Priority control enable)
        # - Bits 28..30: `ID` (Tag ID: REFE, CNT, NEXT, REF, REFS, CALL, RET, END)
        # - Bit 31: `IRQ` (Interrupt request on tag completion)
        # - Bits 32..62: `ADDR` (16-byte aligned physical memory address)
        # - Bit 63: `SPR` (Scratchpad RAM flag: 1 = SPRAM, 0 = Main RAM)
        def encode_lo : UInt64
          lo = @qwc.to_u64
          lo |= ((@pce.to_u64 & 0x3_u64) << 26)
          lo |= ((@id.value.to_u64 & 0x7_u64) << 28)
          lo |= (1_u64 << 31) if @irq
          lo |= ((@addr.to_u64 & 0x7FFFFFF0_u64) << 32)
          lo |= (1_u64 << 63) if @spr
          lo
        end

        def to_quadword : Quadword
          Quadword.new(encode_lo, @opt_hi)
        end
      end

      # 128-bit Graphics Interface Tag (`GIFTag`) header preceding GS primitive/register payloads.
      struct GifTag
        getter nloop : UInt16
        getter eop : Bool
        getter pre : Bool
        getter prim : UInt16
        getter flg : GifFormat
        getter nreg : UInt8
        getter regs : UInt64

        def initialize(
          @nloop : UInt16,
          @eop : Bool = true,
          @pre : Bool = false,
          @prim : UInt16 = 0_u16,
          @flg : GifFormat = GifFormat::Packed,
          @nreg : UInt8 = 1_u8,
          @regs : UInt64 = GifReg::AD.value.to_u64,
        )
          if @nloop > MAX_NLOOP
            raise ArgumentError.new("GIFTag NLOOP (#{@nloop}) exceeds 15-bit hardware maximum (#{MAX_NLOOP})")
          end
          if @nreg == 0_u8 || @nreg > 16_u8
            raise ArgumentError.new("GIFTag NREG (#{@nreg}) must be between 1 and 16")
          end
        end

        # Helper to build the 64-bit `REGS` field from an array/tuple of `GifReg` descriptors.
        def self.pack_regs(*descriptors : GifReg) : UInt64
          if descriptors.empty? || descriptors.size > 16
            raise ArgumentError.new("GIFTag requires between 1 and 16 register descriptors")
          end
          packed = 0_u64
          descriptors.each_with_index do |reg, idx|
            packed |= ((reg.value.to_u64 & 0xF_u64) << (idx * 4))
          end
          packed
        end

        # Creates a standard PACKED A+D (`NREG=1, REGS=0x0E`) GIFTag.
        def self.ad(nloop : Int, eop : Bool = true, pre : Bool = false, prim : Int = 0) : GifTag
          if nloop < 0 || nloop > MAX_NLOOP
            raise ArgumentError.new("GIFTag NLOOP (#{nloop}) exceeds 15-bit hardware maximum (#{MAX_NLOOP})")
          end
          GifTag.new(
            nloop: nloop.to_u16,
            eop: eop,
            pre: pre,
            prim: prim.to_u16,
            flg: GifFormat::Packed,
            nreg: 1_u8,
            regs: GifReg::AD.value.to_u64
          )
        end

        # Creates an IMAGE mode (`FLG=IMAGE`) GIFTag for raw texture/framebuffer uploads.
        def self.image(qwc : Int, eop : Bool = true) : GifTag
          if qwc < 0 || qwc > MAX_NLOOP
            raise ArgumentError.new("GIFTag IMAGE NLOOP (#{qwc}) exceeds 15-bit hardware maximum (#{MAX_NLOOP})")
          end
          GifTag.new(
            nloop: qwc.to_u16,
            eop: eop,
            pre: false,
            prim: 0_u16,
            flg: GifFormat::Image,
            nreg: 1_u8,
            regs: 0_u64
          )
        end

        # Encodes the lower 64 bits of the 128-bit GIFTag:
        # - Bits 0..14: `NLOOP` (15 bits)
        # - Bit 15: `EOP` (1 bit)
        # - Bits 16..45: Reserved (0)
        # - Bit 46: `PRE` (1 bit)
        # - Bits 47..57: `PRIM` (11 bits)
        # - Bits 58..59: `FLG` (2 bits)
        # - Bits 60..63: `NREG` (4 bits; 16 is encoded as 0)
        def encode_lo : UInt64
          encoded_nreg = (@nreg == 16_u8) ? 0_u64 : (@nreg.to_u64 & 0xF_u64)
          lo = (@nloop.to_u64 & 0x7FFF_u64)
          lo |= (1_u64 << 15) if @eop
          lo |= (1_u64 << 46) if @pre
          lo |= ((@prim.to_u64 & 0x7FF_u64) << 47)
          lo |= ((@flg.value.to_u64 & 0x3_u64) << 58)
          lo |= (encoded_nreg << 60)
          lo
        end

        def encode_hi : UInt64
          @regs
        end

        def to_quadword : Quadword
          Quadword.new(encode_lo, encode_hi)
        end
      end

      # =========================================================================
      # Pure GS Register Bitfield Encoders (Zero-Allocation)
      # =========================================================================

      module GsEncoder
        # Encodes the 11-bit `PRIM` register value:
        # - Bits 0..2: `PRIM` (Primitive type 0..6)
        # - Bit 3: `IIP` (Shading: 0 = Flat, 1 = Gouraud)
        # - Bit 4: `TME` (Texture Mapping Enable)
        # - Bit 5: `FGE` (Fog Enable)
        # - Bit 6: `ABE` (Alpha Blending Enable)
        # - Bit 7: `AA1` (Anti-Aliasing Enable)
        # - Bit 8: `FST` (Texture Coordinate Method: 0 = STQ, 1 = UV)
        # - Bit 9: `CTXT` (Drawing Context: 0 = Context 1, 1 = Context 2)
        # - Bit 10: `FIX` (Fragment Value Control)
        def self.encode_prim(
          prim : Primitive,
          gouraud : Bool = false,
          textured : Bool = false,
          fog : Bool = false,
          alpha_blend : Bool = false,
          antialias : Bool = false,
          use_uv : Bool = false,
          context : Int = 0,
          fix : Bool = false,
        ) : UInt64
          val = prim.value.to_u64 & 0x7_u64
          val |= (1_u64 << 3) if gouraud
          val |= (1_u64 << 4) if textured
          val |= (1_u64 << 5) if fog
          val |= (1_u64 << 6) if alpha_blend
          val |= (1_u64 << 7) if antialias
          val |= (1_u64 << 8) if use_uv
          val |= (1_u64 << 9) if context == 1
          val |= (1_u64 << 10) if fix
          val
        end

        # Encodes `RGBAQ` (0x01): R(0..7), G(8..15), B(16..23), A(24..31), Q(32..63 IEEE-754 float).
        def self.encode_rgbaq(r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8, q : Float32 = 1.0_f32) : UInt64
          q_bits = q.unsafe_as(UInt32).to_u64
          (q_bits << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
        end

        # Encodes `XYZ2` (0x05) or `XYZ3` (0x0D) from integer pixel coordinates (shifted to 12.4 fixed-point) and 32-bit Z.
        def self.encode_xyz(x : Int32, y : Int32, z : UInt32 = 0_u32) : UInt64
          gs_x = ((x.to_i64 << 4) & 0xFFFF_i64).to_u64
          gs_y = ((y.to_i64 << 4) & 0xFFFF_i64).to_u64
          (z.to_u64 << 32) | (gs_y << 16) | gs_x
        end

        # Encodes `XYZ2` / `XYZ3` from raw 16-bit 12.4 fixed-point subpixel coordinates.
        def self.encode_xyz_raw(fx : UInt16, fy : UInt16, z : UInt32 = 0_u32) : UInt64
          (z.to_u64 << 32) | (fy.to_u64 << 16) | fx.to_u64
        end

        # Encodes `UV` (0x03) texel coordinates in 10.4 fixed-point format.
        def self.encode_uv(u : Int32, v : Int32) : UInt64
          gs_u = ((u.to_i64 << 4) & 0x3FFF_i64).to_u64
          gs_v = ((v.to_i64 << 4) & 0x3FFF_i64).to_u64
          (gs_v << 16) | gs_u
        end

        # Encodes `ST` (0x02) normalized texture coordinates as two IEEE-754 floats.
        def self.encode_st(s : Float32, t : Float32) : UInt64
          s_bits = s.unsafe_as(UInt32).to_u64
          t_bits = t.unsafe_as(UInt32).to_u64
          (t_bits << 32) | s_bits
        end

        # Encodes `FRAME_1` (0x4C) / `FRAME_2` (0x4D):
        # - Bits 0..8: `FBP` (Base pointer in 2048-word pages)
        # - Bits 16..21: `FBW` (Buffer width in 64-pixel units, e.g. 640px -> 10)
        # - Bits 24..29: `PSM` (Pixel storage mode)
        # - Bits 32..63: `FBMSK` (Frame buffer write mask)
        def self.encode_frame(fbp : UInt32, width : Int32, psm : PixelFormat = PixelFormat::PSMCT32, fbmsk : UInt32 = 0_u32) : UInt64
          fbw = ((width + 63) // 64).to_u64 & 0x3F_u64
          (fbmsk.to_u64 << 32) | ((psm.value.to_u64 & 0x3F_u64) << 24) | (fbw << 16) | (fbp.to_u64 & 0x1FF_u64)
        end

        # Encodes `ZBUF_1` (0x4E) / `ZBUF_2` (0x4F):
        # - Bits 0..8: `ZBP` (Z-buffer base pointer in 2048-word pages)
        # - Bits 24..27: `PSM` (Z-buffer format, e.g. PSMZ32 = 0x30 -> lower 4 bits)
        # - Bit 32: `ZMSK` (1 = mask Z writes, 0 = enable Z writes)
        def self.encode_zbuf(zbp : UInt32, psm : PixelFormat = PixelFormat::PSMZ32, zmsk : Bool = false) : UInt64
          val = (zbp.to_u64 & 0x1FF_u64) | ((psm.value.to_u64 & 0xF_u64) << 24)
          val |= (1_u64 << 32) if zmsk
          val
        end

        # Encodes `XYOFFSET_1` (0x18) / `XYOFFSET_2` (0x19) from pixel offsets `(ofx, ofy)`.
        def self.encode_xyoffset(ofx : Int32, ofy : Int32) : UInt64
          raw_x = ((ofx.to_i64 << 4) & 0xFFFF_i64).to_u64
          raw_y = ((ofy.to_i64 << 4) & 0xFFFF_i64).to_u64
          (raw_y << 32) | raw_x
        end

        # Encodes `SCISSOR_1` (0x40) / `SCISSOR_2` (0x41) clipping bounds `(x0, y0)` to `(x1, y1)`.
        def self.encode_scissor(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : UInt64
          sx0 = (x0.clamp(0, 2047)).to_u64
          sy0 = (y0.clamp(0, 2047)).to_u64
          sx1 = (x1.clamp(0, 2047)).to_u64
          sy1 = (y1.clamp(0, 2047)).to_u64
          (sy1 << 48) | (sy0 << 32) | (sx1 << 16) | sx0
        end

        # Encodes `TEST_1` (0x47) / `TEST_2` (0x48) pixel alpha and depth test control.
        def self.encode_test(
          ate : Bool = false,
          atst : UInt8 = 1_u8,
          aref : UInt8 = 0x80_u8,
          afail : UInt8 = 0_u8,
          date : Bool = false,
          datm : UInt8 = 0_u8,
          zte : Bool = true,
          ztst : UInt8 = 1_u8,
        ) : UInt64
          val = ate ? 1_u64 : 0_u64
          val |= ((atst.to_u64 & 0x7_u64) << 1)
          val |= (aref.to_u64 << 4)
          val |= ((afail.to_u64 & 0x3_u64) << 12)
          val |= (1_u64 << 14) if date
          val |= ((datm.to_u64 & 0x1_u64) << 15)
          val |= (1_u64 << 16) if zte
          val |= ((ztst.to_u64 & 0x3_u64) << 17)
          val
        end

        # Encodes `ALPHA_1` (0x42) / `ALPHA_2` (0x43) hardware blending formula: `(A - B) * C >> 7 + D`.
        # `a, b, d`: 0 = Cs (Source RGB), 1 = Cd (Dest RGB), 2 = 0
        # `c`: 0 = As (Source Alpha), 1 = Ad (Dest Alpha), 2 = FIX
        def self.encode_alpha(a : UInt8 = 0_u8, b : UInt8 = 1_u8, c : UInt8 = 0_u8, d : UInt8 = 1_u8, fix : UInt8 = 0x80_u8) : UInt64
          ((fix.to_u64) << 32) | ((d.to_u64 & 0x3_u64) << 6) | ((c.to_u64 & 0x3_u64) << 4) | ((b.to_u64 & 0x3_u64) << 2) | (a.to_u64 & 0x3_u64)
        end

        # Encodes `TEX0_1` (0x06) / `TEX0_2` (0x07) texture buffer configuration.
        def self.encode_tex0(
          tbp0 : UInt32,
          tbw : UInt32,
          psm : PixelFormat,
          tw : UInt8,
          th : UInt8,
          tcc : UInt8 = 1_u8,
          tfx : UInt8 = 0_u8,
          cbp : UInt32 = 0_u32,
          cpsm : PixelFormat = PixelFormat::PSMCT32,
          csm : UInt8 = 0_u8,
        ) : UInt64
          val = (tbp0.to_u64 & 0x3FFF_u64)
          val |= ((tbw.to_u64 & 0x3F_u64) << 14)
          val |= ((psm.value.to_u64 & 0x3F_u64) << 20)
          val |= ((tw.to_u64 & 0xF_u64) << 26)
          val |= ((th.to_u64 & 0xF_u64) << 30)
          val |= ((tcc.to_u64 & 0x1_u64) << 34)
          val |= ((tfx.to_u64 & 0x3_u64) << 35)
          val |= ((cbp.to_u64 & 0x3FFF_u64) << 37)
          val |= ((cpsm.value.to_u64 & 0xF_u64) << 51)
          val |= ((csm.to_u64 & 0x1_u64) << 55)
          val
        end

        # Encodes `BITBLTBUF` (0x50) for VRAM texture/image transfers.
        def self.encode_bitbltbuf(
          sbp : UInt32 = 0_u32,
          sbw : UInt32 = 0_u32,
          spsm : PixelFormat = PixelFormat::PSMCT32,
          dbp : UInt32 = 0_u32,
          dbw : UInt32 = 1_u32,
          dpsm : PixelFormat = PixelFormat::PSMCT32,
        ) : UInt64
          val = (sbp.to_u64 & 0x3FFF_u64)
          val |= ((sbw.to_u64 & 0x3F_u64) << 16)
          val |= ((spsm.value.to_u64 & 0x3F_u64) << 24)
          val |= ((dbp.to_u64 & 0x3FFF_u64) << 32)
          val |= ((dbw.to_u64 & 0x3F_u64) << 48)
          val |= ((dpsm.value.to_u64 & 0x3F_u64) << 56)
          val
        end

        # Encodes `TRXPOS` (0x51) transfer rectangular coordinates.
        def self.encode_trxpos(ssax : Int32 = 0, ssay : Int32 = 0, dsax : Int32 = 0, dsay : Int32 = 0, dir : UInt8 = 0_u8) : UInt64
          val = (ssax.to_u64 & 0x7FF_u64)
          val |= ((ssay.to_u64 & 0x7FF_u64) << 16)
          val |= ((dsax.to_u64 & 0x7FF_u64) << 32)
          val |= ((dsay.to_u64 & 0x7FF_u64) << 48)
          val |= ((dir.to_u64 & 0x3_u64) << 59)
          val
        end

        # Encodes `TRXREG` (0x52) transfer dimensions `(rrw, rrh)`.
        def self.encode_trxreg(rrw : Int32, rrh : Int32) : UInt64
          ((rrh.to_u64 & 0xFFF_u64) << 32) | (rrw.to_u64 & 0xFFF_u64)
        end
      end

      # =========================================================================
      # Address & Memory Segment Utilities
      # =========================================================================

      # Converts a virtual EE address into its 29-bit physical RAM address (`0x00000000 - 0x01FFFFFF`).
      def self.to_physical_addr(addr : UInt32) : UInt32
        return addr if (addr & 0xF0000000_u32) == SPRAM_BASE
        addr & PHYSICAL_RAM_MASK
      end

      # Maps a physical RAM address into the KUSEG Uncached mirror (`0x20000000 | phys`).
      def self.to_uncached_addr(addr : UInt32) : UInt32
        (addr & PHYSICAL_RAM_MASK) | UNCACHED_BASE
      end

      # Maps a physical RAM address into the KUSEG Uncached Accelerated mirror (`0x30000000 | phys`).
      def self.to_uncached_accel_addr(addr : UInt32) : UInt32
        (addr & PHYSICAL_RAM_MASK) | UNCACHED_ACCEL_BASE
      end

      # Maps a physical RAM address into the Kernel KSEG1 Uncached mirror (`0xA0000000 | phys`).
      def self.to_kseg1_addr(addr : UInt32) : UInt32
        (addr & PHYSICAL_RAM_MASK) | KSEG1_BASE
      end

      # Returns true if the address resides within the 16 KB Scratchpad RAM (`0x70000000 - 0x70003FFF`).
      def self.spram_addr?(addr : UInt32) : Bool
        addr >= SPRAM_BASE && addr < (SPRAM_BASE + SPRAM_SIZE)
      end

      # Returns true if the address is 16-byte (128-bit quadword) aligned.
      def self.qword_aligned?(addr : UInt32) : Bool
        (addr & 0xF_u32) == 0_u32
      end

      # =========================================================================
      # Core Packet Buffer State Machine (Pre-Allocated / Zero-Alloc Hot Path)
      # =========================================================================

      # Low-level 128-bit quadword packet buffer and state machine for assembling
      # contiguous Normal-Mode GIF packets and Source-Chain DMATag lists.
      class PacketBuffer
        # Underlying byte slice storing 16-byte quadwords.
        getter buffer : Bytes
        # Number of 128-bit quadwords currently written into the buffer.
        getter qwc : Int32
        # Maximum capacity in quadwords.
        getter capacity_qwc : Int32
        # Active open GIFTag index (-1 if no open tag).
        getter active_gif_tag_idx : Int32
        # Active open DMATag index (-1 if no open tag).
        getter active_dma_tag_idx : Int32
        # Tracks whether the final GIFTag in this packet has EOP=1 set.
        getter? has_eop : Bool
        # Tracks whether the DMA chain is terminated by END, REFE, or RET.
        getter? chain_terminated : Bool

        def initialize(@capacity_qwc : Int32 = 4096)
          if @capacity_qwc <= 0
            raise ArgumentError.new("PacketBuffer capacity_qwc must be positive")
          end
          @buffer = Bytes.new(@capacity_qwc * 16)
          @qwc = 0
          @active_gif_tag_idx = -1
          @active_dma_tag_idx = -1
          @has_eop = false
          @chain_terminated = false
        end

        # Initializes a `PacketBuffer` wrapping an existing pre-allocated `Bytes` slice (Zero-Allocation).
        def initialize(@buffer : Bytes)
          if (@buffer.size & 0xF) != 0 || @buffer.empty?
            raise ArgumentError.new("PacketBuffer backing slice size (#{@buffer.size}) must be a positive multiple of 16 bytes")
          end
          @capacity_qwc = @buffer.size >> 4
          @qwc = 0
          @active_gif_tag_idx = -1
          @active_dma_tag_idx = -1
          @has_eop = false
          @chain_terminated = false
        end

        # Resets write cursor and state machine in O(1) without deallocating backing memory.
        @[ZeroAllocation]
        def reset! : self
          @qwc = 0
          @active_gif_tag_idx = -1
          @active_dma_tag_idx = -1
          @has_eop = false
          @chain_terminated = false
          self
        end

        # Total size in bytes of the written packet (`qwc * 16`).
        @[ZeroAllocation]
        def byte_size : Int32
          @qwc << 4
        end

        # Returns a read-only `Bytes` slice view over the written quadwords.
        @[ZeroAllocation]
        def to_slice : Bytes
          @buffer[0, @qwc << 4]
        end

        # Reads the `Quadword` at index `idx` (`0 <= idx < qwc`).
        def [](idx : Int32) : Quadword
          if idx < 0 || idx >= @qwc
            raise IndexError.new("Quadword index #{idx} out of bounds (qwc: #{@qwc})")
          end
          Quadword.from_slice(@buffer[idx << 4, 16])
        end

        # Overwrites the `Quadword` at index `idx` in-place.
        @[ZeroAllocation]
        def []=(idx : Int32, qw : Quadword) : Quadword
          offset = idx << 4
          IO::ByteFormat::LittleEndian.encode(qw.lo, @buffer[offset, 8])
          IO::ByteFormat::LittleEndian.encode(qw.hi, @buffer[offset + 8, 8])
          qw
        end

        # Appends a raw 128-bit `(lo, hi)` quadword to the packet buffer.
        @[ZeroAllocation]
        def emit_qword(lo : UInt64, hi : UInt64) : Int32
          idx = @qwc
          offset = idx << 4
          IO::ByteFormat::LittleEndian.encode(lo, @buffer[offset, 8])
          IO::ByteFormat::LittleEndian.encode(hi, @buffer[offset + 8, 8])
          @qwc = idx + 1
          idx
        end

        # Appends a `Quadword` struct to the packet buffer.
        @[ZeroAllocation]
        def emit_qword(qw : Quadword) : Int32
          emit_qword(qw.lo, qw.hi)
        end

        # Appends a GIF A+D (Address + Data) quadword (`lo = data`, `hi = reg`).
        @[ZeroAllocation]
        def emit_ad(reg : GsReg | UInt8, data : UInt64) : Int32
          reg_val = reg.is_a?(GsReg) ? reg.value.to_u64 : reg.to_u64
          emit_qword(data, reg_val)
        end

        # Appends an explicit `GifTag` quadword.
        def emit_gif_tag(tag : GifTag) : Int32
          @has_eop = tag.eop
          emit_qword(tag.encode_lo, tag.encode_hi)
        end

        # Appends an explicit `DmaTag` quadword.
        def emit_dma_tag(tag : DmaTag) : Int32
          if tag.id.end? || tag.id.refe? || tag.id.ret?
            @chain_terminated = true
          end
          emit_qword(tag.encode_lo, tag.opt_hi)
        end

        # Opens a dynamic GIFTag block where `NLOOP` is automatically calculated on `close_gif_tag!`.
        def open_gif_tag(
          eop : Bool = true,
          pre : Bool = false,
          prim : UInt16 = 0_u16,
          flg : GifFormat = GifFormat::Packed,
          nreg : UInt8 = 1_u8,
          regs : UInt64 = GifReg::AD.value.to_u64,
        ) : Int32
          if @active_gif_tag_idx >= 0
            close_gif_tag!
          end
          # Write placeholder tag with NLOOP = 0
          tag = GifTag.new(nloop: 0_u16, eop: eop, pre: pre, prim: prim, flg: flg, nreg: nreg, regs: regs)
          @active_gif_tag_idx = emit_gif_tag(tag)
          @active_gif_tag_idx
        end

        # Closes the currently open dynamic GIFTag and patches its `NLOOP` field based on the number of emitted quadwords.
        # If the payload exceeds `MAX_NLOOP` (32,767), raises an `ArgumentError`.
        def close_gif_tag! : Int32
          tag_idx = @active_gif_tag_idx
          return 0 if tag_idx < 0

          payload_qwc = (@qwc - 1) - tag_idx
          existing = self[tag_idx]
          raw_nreg = ((existing.lo >> 60) & 0xF_u64).to_i32
          nreg = raw_nreg == 0 ? 16 : raw_nreg
          flg_val = ((existing.lo >> 58) & 0x3_u64).to_u8
          flg = GifFormat.new(flg_val)

          nloop = case flg
                  when .packed?
                    if payload_qwc % nreg != 0
                      raise ArgumentError.new("Packed GIF payload (#{payload_qwc} QWs) is not a multiple of NREG (#{nreg})")
                    end
                    payload_qwc // nreg
                  when .reg_list?
                    (payload_qwc * 2) // nreg
                  when .image?, .disable?
                    payload_qwc
                  else
                    payload_qwc
                  end

          if nloop > MAX_NLOOP
            raise ArgumentError.new("Dynamic GIFTag NLOOP (#{nloop}) exceeds 15-bit hardware maximum (#{MAX_NLOOP})")
          end

          patched_lo = (existing.lo & ~0x7FFF_u64) | (nloop.to_u64 & 0x7FFF_u64)
          self[tag_idx] = Quadword.new(patched_lo, existing.hi)
          @active_gif_tag_idx = -1
          nloop
        end

        # Opens a dynamic Source-Chain `DmaTag` (`CNT`, `NEXT`, `CALL`, `RET`, `END`) where `QWC` is patched on `close_dma_tag!`.
        def open_dma_tag(
          id : DmaTagId = DmaTagId::Cnt,
          addr : UInt32 = 0_u32,
          irq : Bool = false,
          pce : UInt8 = 0_u8,
          spr : Bool = false,
          opt_hi : UInt64 = 0_u64,
        ) : Int32
          if @active_gif_tag_idx >= 0
            close_gif_tag!
          end
          if @active_dma_tag_idx >= 0
            close_dma_tag!
          end
          tag = DmaTag.new(qwc: 0_u16, id: id, addr: addr, irq: irq, pce: pce, spr: spr, opt_hi: opt_hi)
          @active_dma_tag_idx = emit_dma_tag(tag)
          @active_dma_tag_idx
        end

        # Closes the currently open dynamic `DmaTag` and patches its 16-bit `QWC` field.
        def close_dma_tag! : Int32
          tag_idx = @active_dma_tag_idx
          return 0 if tag_idx < 0
          if @active_gif_tag_idx >= 0
            close_gif_tag!
          end

          payload_qwc = (@qwc - 1) - tag_idx
          if payload_qwc > MAX_QWC
            raise ArgumentError.new("Dynamic DMATag QWC (#{payload_qwc}) exceeds 16-bit hardware maximum (#{MAX_QWC})")
          end

          existing = self[tag_idx]
          patched_lo = (existing.lo & ~0xFFFF_u64) | (payload_qwc.to_u64 & 0xFFFF_u64)
          self[tag_idx] = Quadword.new(patched_lo, existing.hi)
          @active_dma_tag_idx = -1
          payload_qwc
        end

        # Finalizes any open GIFTag or DMATag and validates packet integrity.
        def finalize! : self
          close_gif_tag! if @active_gif_tag_idx >= 0
          close_dma_tag! if @active_dma_tag_idx >= 0
          self
        end

        # Appends a body of A+D quadwords, automatically splitting into multiple GIFTag chunks of `<= 32,767` NLOOP
        # and setting `EOP=1` on the final chunk.
        def append_chunked_ad_payload(ad_quadwords : Bytes) : Int32
          if (ad_quadwords.size & 0xF) != 0
            raise ArgumentError.new("A+D payload size (#{ad_quadwords.size}) must be a multiple of 16 bytes")
          end
          total_items = ad_quadwords.size >> 4
          if total_items == 0
            emit_gif_tag(GifTag.ad(0, eop: true))
            return 1
          end

          chunks_emitted = 0
          offset = 0
          while offset < total_items
            chunk_size = Math.min(total_items - offset, MAX_NLOOP.to_i)
            is_last = (offset + chunk_size >= total_items)
            emit_gif_tag(GifTag.ad(chunk_size, eop: is_last))
            src_slice = ad_quadwords[offset << 4, chunk_size << 4]
            dst_offset = @qwc << 4
            @buffer[dst_offset, src_slice.size].copy_from(src_slice)
            @qwc += chunk_size
            offset += chunk_size
            chunks_emitted += 1
          end
          chunks_emitted
        end
      end
    end
  end
end
