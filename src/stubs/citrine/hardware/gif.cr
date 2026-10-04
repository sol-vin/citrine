# Citrine Graphics Interface (GIF) Packet & DMAC Limit Subsystem
# Modular hardware abstraction - require "citrine/hardware/gif"

module Citrine
  module Hardware
    # PlayStation 2 Graphics Interface (GIF) Packet and DMA Tag utilities.
    # Manages 128-bit GIFTag encoding, 15-bit NLOOP limits, and 16-bit DMAC QWC chunking.
    module GIF
      # Maximum 16-bit QuadWord Count allowed by PS2 DMAC hardware registers.
      MAX_DMAC_QWC = 65535_u32

      # Conservative safe QWC limit ensuring headroom for chain end and sync tags.
      SAFE_QWC_LIMIT = 65500_u32

      # Maximum 15-bit NLOOP field capacity in a 128-bit GIFTag.
      MAX_NLOOP = 32767_u32

      # GIF Tag Data Format
      enum Format : UInt8
        PACKED  = 0_u8
        REGLIST = 1_u8
        IMAGE   = 2_u8
      end

      # 128-bit GIFTag header preceding draw primitive data sent to Graphics Synthesizer.
      struct GIFTag
        getter nloop : UInt32
        getter eop : Bool
        getter pre : Bool
        getter prim : UInt32
        getter flg : Format
        getter nreg : UInt32

        def initialize(
          @nloop : UInt32,
          @eop : Bool = true,
          @pre : Bool = false,
          @prim : UInt32 = 0_u32,
          @flg : Format = Format::PACKED,
          @nreg : UInt32 = 1_u32
        )
          if @nloop > MAX_NLOOP
            raise ArgumentError.new("GIFTag NLOOP (#{@nloop}) exceeds 15-bit hardware maximum (#{MAX_NLOOP})")
          end
        end

        # Encodes the lower 64 bits of the 128-bit GIFTag:
        # [0..14]: NLOOP (15 bits)
        # [15]: EOP (1 bit)
        # [46]: PRE (1 bit)
        # [47..57]: PRIM (11 bits)
        # [58..59]: FLG (2 bits)
        # [60..63]: NREG (4 bits)
        def encode_lo : UInt64
          lo = (@nloop.to_u64 & 0x7FFF_u64)
          lo |= (1_u64 << 15) if @eop
          lo |= (1_u64 << 46) if @pre
          lo |= ((@prim.to_u64 & 0x7FF_u64) << 47)
          lo |= ((@flg.value.to_u64 & 0x3_u64) << 58)
          lo |= ((@nreg.to_u64 & 0xF_u64) << 60)
          lo
        end
      end

      # Computes packet slicing for a large batch of draw elements into safe DMAC chunks.
      def self.split_dma_batches(total_quadwords : Int32, max_chunk_qwc : Int32 = SAFE_QWC_LIMIT.to_i) : Array(Int32)
        return [0] if total_quadwords <= 0
        chunks = [] of Int32
        remaining = total_quadwords
        while remaining > 0
          chunk = Math.min(remaining, max_chunk_qwc)
          chunks << chunk
          remaining -= chunk
        end
        chunks
      end

      # Validates that a proposed quadword count does not overflow hardware DMAC registers.
      def self.validate_qwc!(qwc : Int32) : Bool
        if qwc < 0 || qwc > MAX_DMAC_QWC
          raise ArgumentError.new("DMAC QWC (#{qwc}) exceeds 16-bit hardware register limit (#{MAX_DMAC_QWC})")
        end
        true
      end
    end
  end
end
