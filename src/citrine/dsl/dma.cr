# Citrine PlayStation 2 Declarative DMA & GIF Packet Builder DSL (Tier 2)
# Ergonomic, block-scoped builders wrapping `Citrine::Core::DMA` with yield-context
# receivers, automatic NLOOP/QWC patching, EOP enforcement, and GS primitive helpers.

require "../core/dma"

module Citrine
  module DSL
    module DMA
      alias Channel        = Citrine::Core::DMA::Channel
      alias Direction      = Citrine::Core::DMA::Direction
      alias TransferMode   = Citrine::Core::DMA::TransferMode
      alias DmaTagId       = Citrine::Core::DMA::DmaTagId
      alias GifFormat      = Citrine::Core::DMA::GifFormat
      alias GifReg         = Citrine::Core::DMA::GifReg
      alias GsReg          = Citrine::Core::DMA::GsReg
      alias Primitive      = Citrine::Core::DMA::Primitive
      alias PixelFormat    = Citrine::Core::DMA::PixelFormat
      alias Quadword       = Citrine::Core::DMA::Quadword
      alias ChannelControl = Citrine::Core::DMA::ChannelControl
      alias DmaTag         = Citrine::Core::DMA::DmaTag
      alias GifTag         = Citrine::Core::DMA::GifTag
      alias GsEncoder      = Citrine::Core::DMA::GsEncoder
      alias PacketBuffer   = Citrine::Core::DMA::PacketBuffer

      # =========================================================================
      # Declarative GIF A+D & Primitive Stream Receiver (`AdBuilder`)
      # =========================================================================

      # Yielded inside `pkt.gif_ad do |gs| ... end` or `Citrine::DMA.draw do |gs| ... end`.
      # Provides fluent methods for configuring GS drawing environment registers and
      # submitting 2D/3D primitives into a `PacketBuffer`.
      struct AdBuilder
        getter buffer : PacketBuffer

        def initialize(@buffer : PacketBuffer)
        end

        # Emits an arbitrary GS register write in A+D mode (`lo = data`, `hi = reg`).
        def reg(address : GsReg | UInt8, data : UInt64) : self
          @buffer.emit_ad(address, data)
          self
        end

        # Emits a raw 128-bit quadword `(lo, hi)`.
        def qword(lo : UInt64, hi : UInt64) : self
          @buffer.emit_qword(lo, hi)
          self
        end

        # Configures `PRIM` (`0x00`) register using symbolic or enum primitive type and pipeline flags.
        def prim(
          type : Primitive | Symbol,
          gouraud : Bool = false,
          textured : Bool = false,
          fog : Bool = false,
          alpha_blend : Bool = false,
          antialias : Bool = false,
          use_uv : Bool = false,
          context : Int = 0,
          fix : Bool = false
        ) : self
          p_enum = parse_primitive(type)
          encoded = GsEncoder.encode_prim(
            p_enum,
            gouraud: gouraud,
            textured: textured,
            fog: fog,
            alpha_blend: alpha_blend,
            antialias: antialias,
            use_uv: use_uv,
            context: context,
            fix: fix
          )
          @buffer.emit_ad(GsReg::Prim, encoded)
          self
        end

        # Emits `RGBAQ` (`0x01`) vertex color register.
        def rgba(r : Int, g : Int, b : Int, a : Int = 0x80, q : Float32 = 1.0_f32) : self
          encoded = GsEncoder.encode_rgbaq(r.to_u8, g.to_u8, b.to_u8, a.to_u8, q)
          @buffer.emit_ad(GsReg::Rgbaq, encoded)
          self
        end

        # Emits `XYZ2` (`0x05`) vertex coordinate in pixel space (shifted by 4 to 12.4 fixed-point) and kicks drawing.
        def xyz2(x : Int32, y : Int32, z : UInt32 = 0_u32) : self
          @buffer.emit_ad(GsReg::Xyz2, GsEncoder.encode_xyz(x, y, z))
          self
        end

        # Emits `XYZ3` (`0x0D`) vertex coordinate in pixel space without drawing kick.
        def xyz3(x : Int32, y : Int32, z : UInt32 = 0_u32) : self
          @buffer.emit_ad(GsReg::Xyz3, GsEncoder.encode_xyz(x, y, z))
          self
        end

        # Emits `XYZ2` (`0x05`) using raw 16-bit 12.4 fixed-point subpixel coordinates.
        def xyz2_raw(fx : UInt16, fy : UInt16, z : UInt32 = 0_u32) : self
          @buffer.emit_ad(GsReg::Xyz2, GsEncoder.encode_xyz_raw(fx, fy, z))
          self
        end

        # Emits `XYZ3` (`0x0D`) using raw 16-bit 12.4 fixed-point subpixel coordinates.
        def xyz3_raw(fx : UInt16, fy : UInt16, z : UInt32 = 0_u32) : self
          @buffer.emit_ad(GsReg::Xyz3, GsEncoder.encode_xyz_raw(fx, fy, z))
          self
        end

        # Emits `UV` (`0x03`) texel coordinates in pixel units (shifted to 10.4 fixed-point).
        def uv(u : Int32, v : Int32) : self
          @buffer.emit_ad(GsReg::Uv, GsEncoder.encode_uv(u, v))
          self
        end

        # Emits `ST` (`0x02`) normalized floating-point texture coordinates.
        def st(s : Float32, t : Float32) : self
          @buffer.emit_ad(GsReg::St, GsEncoder.encode_st(s, t))
          self
        end

        # Configures `FRAME_1` (`0x4C`) or `FRAME_2` (`0x4D`).
        def frame(
          fbp : UInt32 = 0_u32,
          width : Int32 = 640,
          psm : PixelFormat = PixelFormat::PSMCT32,
          fbmsk : UInt32 = 0_u32,
          context : Int = 0
        ) : self
          target = context == 1 ? GsReg::Frame_2 : GsReg::Frame_1
          @buffer.emit_ad(target, GsEncoder.encode_frame(fbp, width, psm, fbmsk))
          self
        end

        # Configures `ZBUF_1` (`0x4E`) or `ZBUF_2` (`0x4F`).
        def zbuf(
          zbp : UInt32 = 140_u32,
          psm : PixelFormat = PixelFormat::PSMZ32,
          zmsk : Bool = false,
          context : Int = 0
        ) : self
          target = context == 1 ? GsReg::Zbuf_2 : GsReg::Zbuf_1
          @buffer.emit_ad(target, GsEncoder.encode_zbuf(zbp, psm, zmsk))
          self
        end

        # Configures `XYOFFSET_1` (`0x18`) or `XYOFFSET_2` (`0x19`).
        def xyoffset(ofx : Int32 = 0, ofy : Int32 = 0, context : Int = 0) : self
          target = context == 1 ? GsReg::Xyoffset_2 : GsReg::Xyoffset_1
          @buffer.emit_ad(target, GsEncoder.encode_xyoffset(ofx, ofy))
          self
        end

        # Configures `SCISSOR_1` (`0x40`) or `SCISSOR_2` (`0x41`).
        def scissor(x0 : Int32 = 0, y0 : Int32 = 0, x1 : Int32 = 639, y1 : Int32 = 447, context : Int = 0) : self
          target = context == 1 ? GsReg::Scissor_2 : GsReg::Scissor_1
          @buffer.emit_ad(target, GsEncoder.encode_scissor(x0, y0, x1, y1))
          self
        end

        # Configures `TEST_1` (`0x47`) or `TEST_2` (`0x48`).
        def test(
          ate : Bool = false,
          atst : UInt8 = 1_u8,
          aref : UInt8 = 0x80_u8,
          afail : UInt8 = 0_u8,
          date : Bool = false,
          datm : UInt8 = 0_u8,
          zte : Bool = true,
          ztst : UInt8 = 1_u8,
          context : Int = 0
        ) : self
          target = context == 1 ? GsReg::Test_2 : GsReg::Test_1
          @buffer.emit_ad(target, GsEncoder.encode_test(ate, atst, aref, afail, date, datm, zte, ztst))
          self
        end

        # Configures `ALPHA_1` (`0x42`) or `ALPHA_2` (`0x43`) blending equation.
        def alpha(a : UInt8 = 0_u8, b : UInt8 = 1_u8, c : UInt8 = 0_u8, d : UInt8 = 1_u8, fix : UInt8 = 0x80_u8, context : Int = 0) : self
          target = context == 1 ? GsReg::Alpha_2 : GsReg::Alpha_1
          @buffer.emit_ad(target, GsEncoder.encode_alpha(a, b, c, d, fix))
          self
        end

        # Configures `TEX0_1` (`0x06`) or `TEX0_2` (`0x07`).
        def tex0(
          tbp0 : UInt32,
          tbw : UInt32,
          psm : PixelFormat = PixelFormat::PSMCT32,
          tw : UInt8 = 6_u8,
          th : UInt8 = 6_u8,
          tcc : UInt8 = 1_u8,
          tfx : UInt8 = 0_u8,
          cbp : UInt32 = 0_u32,
          cpsm : PixelFormat = PixelFormat::PSMCT32,
          csm : UInt8 = 0_u8,
          context : Int = 0
        ) : self
          target = context == 1 ? GsReg::Tex0_2 : GsReg::Tex0_1
          @buffer.emit_ad(target, GsEncoder.encode_tex0(tbp0, tbw, psm, tw, th, tcc, tfx, cbp, cpsm, csm))
          self
        end

        # Emits `TEXFLUSH` (`0x3F`) to synchronize GS texture cache before sampling newly uploaded VRAM data.
        def texflush : self
          @buffer.emit_ad(GsReg::Texflush, 0_u64)
          self
        end

        # Emits `PRMODECONT` (`0x1A`) register (1 = use `PRIM` attributes, 0 = use `PRMODE`).
        def prmodecont(use_prim : Bool = true) : self
          @buffer.emit_ad(GsReg::Prmodecont, use_prim ? 1_u64 : 0_u64)
          self
        end

        # Emits `COLCLAMP` (`0x46`) register (1 = clamp RGB to 0..255, 0 = wrap).
        def colclamp(enabled : Bool = true) : self
          @buffer.emit_ad(GsReg::Colclamp, enabled ? 1_u64 : 0_u64)
          self
        end

        # Emits `DTHE` (`0x45`) dithering control register.
        def dither(enabled : Bool = false) : self
          @buffer.emit_ad(GsReg::Dthe, enabled ? 1_u64 : 0_u64)
          self
        end

        # Emits standard 13-register NTSC 640x448 drawing environment initialization sequence (Contexts 1 & 2).
        def default_env(width : Int32 = 640, height : Int32 = 448, fbp : UInt32 = 0_u32, zbp : UInt32 = 140_u32) : self
          frame(fbp: fbp, width: width, psm: PixelFormat::PSMCT32, context: 0)
          frame(fbp: fbp, width: width, psm: PixelFormat::PSMCT32, context: 1)
          zbuf(zbp: zbp, psm: PixelFormat::PSMCT32, zmsk: true, context: 0)
          zbuf(zbp: zbp, psm: PixelFormat::PSMCT32, zmsk: true, context: 1)
          xyoffset(0, 0, context: 0)
          xyoffset(0, 0, context: 1)
          scissor(0, 0, width - 1, height - 1, context: 0)
          scissor(0, 0, width - 1, height - 1, context: 1)
          prmodecont(true)
          colclamp(true)
          dither(false)
          test(zte: true, ztst: 1_u8, context: 0)
          test(zte: true, ztst: 1_u8, context: 1)
          self
        end

        # High-level helper: Emits a 4-quadword 2D `SPRITE` primitive (`PRIM + RGBAQ + XYZ3 + XYZ2`).
        def sprite(
          x1 : Int32,
          y1 : Int32,
          x2 : Int32,
          y2 : Int32,
          r : Int = 255,
          g : Int = 255,
          b : Int = 255,
          a : Int = 0x80,
          z : UInt32 = 0_u32
        ) : self
          prim(Primitive::Sprite)
          rgba(r, g, b, a)
          xyz3(x1, y1, z)
          xyz2(x2, y2, z)
          self
        end

        # High-level helper: Emits a 5-quadword 2D/3D flat-shaded `TRIANGLE` primitive (`PRIM + RGBAQ + XYZ3 + XYZ3 + XYZ2`).
        def triangle(
          x1 : Int32, y1 : Int32,
          x2 : Int32, y2 : Int32,
          x3 : Int32, y3 : Int32,
          r : Int = 255, g : Int = 255, b : Int = 255, a : Int = 0x80,
          z : UInt32 = 0_u32
        ) : self
          prim(Primitive::Triangle)
          rgba(r, g, b, a)
          xyz3(x1, y1, z)
          xyz3(x2, y2, z)
          xyz2(x3, y3, z)
          self
        end

        # High-level helper: Emits a 4-quadword `LINE` segment primitive (`PRIM + RGBAQ + XYZ3 + XYZ2`).
        def line(
          x1 : Int32, y1 : Int32,
          x2 : Int32, y2 : Int32,
          r : Int = 255, g : Int = 255, b : Int = 255, a : Int = 0x80,
          z : UInt32 = 0_u32
        ) : self
          prim(Primitive::Line)
          rgba(r, g, b, a)
          xyz3(x1, y1, z)
          xyz2(x2, y2, z)
          self
        end

        # High-level helper: Clears the screen by emitting a full-screen `SPRITE` primitive.
        def clear(r : Int = 0, g : Int = 0, b : Int = 0, a : Int = 0x80, width : Int32 = 640, height : Int32 = 448) : self
          sprite(0, 0, width, height, r, g, b, a)
        end

        private def parse_primitive(type : Primitive | Symbol) : Primitive
          return type if type.is_a?(Primitive)
          case type
          when :point          then Primitive::Point
          when :line           then Primitive::Line
          when :line_strip     then Primitive::LineStrip
          when :triangle       then Primitive::Triangle
          when :triangle_strip then Primitive::TriangleStrip
          when :triangle_fan   then Primitive::TriangleFan
          when :sprite, :rect  then Primitive::Sprite
          else
            raise ArgumentError.new("Unknown GS primitive symbol: :#{type}")
          end
        end
      end

      # =========================================================================
      # Declarative Packet & Source-Chain Builder (`PacketBuilder`)
      # =========================================================================

      # Primary declarative receiver for constructing Normal-Mode and Source-Chain
      # DMA packets with automatic tag patching.
      struct PacketBuilder
        getter buffer : PacketBuffer
        getter channel : Channel

        def initialize(@buffer : PacketBuffer, @channel : Channel = Channel::GIF)
        end

        # Number of 128-bit quadwords emitted so far.
        def qwc : Int32
          @buffer.qwc
        end

        # Total size in bytes emitted so far (`qwc * 16`).
        def byte_size : Int32
          @buffer.byte_size
        end

        # Opens a scoped GIF A+D (`0x0E`) tag block, yields an `AdBuilder`, and automatically
        # computes and patches `NLOOP` upon block exit.
        def gif_ad(eop : Bool = true, pre : Bool = false, prim : UInt16 = 0_u16, &block : AdBuilder ->) : self
          @buffer.open_gif_tag(eop: eop, pre: pre, prim: prim, flg: GifFormat::Packed, nreg: 1_u8, regs: GifReg::AD.value.to_u64)
          begin
            yield AdBuilder.new(@buffer)
          ensure
            @buffer.close_gif_tag!
          end
          self
        end

        # Opens a custom packed `GIFTag` with explicit register descriptors (`GifReg`), yields `AdBuilder`,
        # and automatically patches `NLOOP = payload_qwc // descriptors.size` upon block exit.
        def gif_packed(
          *descriptors : GifReg,
          eop : Bool = true,
          pre : Bool = false,
          prim : UInt16 = 0_u16,
          &block : AdBuilder ->
        ) : self
          regs_val = GifTag.pack_regs(*descriptors)
          @buffer.open_gif_tag(
            eop: eop,
            pre: pre,
            prim: prim,
            flg: GifFormat::Packed,
            nreg: descriptors.size.to_u8,
            regs: regs_val
          )
          begin
            yield AdBuilder.new(@buffer)
          ensure
            @buffer.close_gif_tag!
          end
          self
        end

        # Emits a complete VRAM texture/image transfer sequence (`BITBLTBUF`, `TRXPOS`, `TRXREG`, `TRXDIR`
        # followed by one or more `FLG=IMAGE` GIFTag chunks containing the raw pixel data).
        def vram_upload(
          pixels : Bytes,
          dbp : UInt32,
          width : Int32,
          height : Int32,
          psm : PixelFormat = PixelFormat::PSMCT32,
          dsax : Int32 = 0,
          dsay : Int32 = 0,
          eop : Bool = true
        ) : self
          if (pixels.size & 0xF) != 0
            raise ArgumentError.new("VRAM upload pixel buffer size (#{pixels.size}) must be a multiple of 16 bytes (1 quadword)")
          end

          dbw = Math.max(1, (width + 63) // 64).to_u32
          gif_ad(eop: false) do |gs|
            gs.reg(GsReg::Bitbltbuf, GsEncoder.encode_bitbltbuf(dbp: dbp, dbw: dbw, dpsm: psm))
            gs.reg(GsReg::Trxpos, GsEncoder.encode_trxpos(dsax: dsax, dsay: dsay))
            gs.reg(GsReg::Trxreg, GsEncoder.encode_trxreg(width, height))
            gs.reg(GsReg::Trxdir, 0_u64) # 0 = Host -> Local (EE -> GS VRAM)
          end

          total_qwc = pixels.size >> 4
          offset_qwc = 0
          while offset_qwc < total_qwc
            chunk_qwc = Math.min(total_qwc - offset_qwc, Citrine::Core::DMA::MAX_NLOOP.to_i)
            is_last = (offset_qwc + chunk_qwc >= total_qwc)
            @buffer.emit_gif_tag(GifTag.image(chunk_qwc, eop: is_last ? eop : false))
            chunk_qwc.times do |i|
              qw = Quadword.from_slice(pixels[(offset_qwc + i) << 4, 16])
              @buffer.emit_qword(qw)
            end
            offset_qwc += chunk_qwc
          end
          self
        end

        # =====================================================================
        # Source-Chain DMATag Block Helpers (`cnt`, `next_tag`, `ref`, `refe`, `call_tag`, `ret_tag`, `end_tag`)
        # =====================================================================

        # Opens a `CNT` source-chain `DmaTag`, yields `self` to populate inline quadwords,
        # and automatically patches the tag's `QWC` on block exit.
        def cnt(irq : Bool = false, spr : Bool = false, &block : PacketBuilder ->) : self
          @buffer.open_dma_tag(id: DmaTagId::Cnt, addr: 0_u32, irq: irq, spr: spr)
          begin
            yield self
          ensure
            @buffer.close_dma_tag!
          end
          self
        end

        # Opens a `NEXT` source-chain `DmaTag` branching to `next_addr`, yields `self`, and patches `QWC`.
        def next_tag(next_addr : UInt32, irq : Bool = false, spr : Bool = false, &block : PacketBuilder ->) : self
          @buffer.open_dma_tag(id: DmaTagId::Next, addr: next_addr, irq: irq, spr: spr)
          begin
            yield self
          ensure
            @buffer.close_dma_tag!
          end
          self
        end

        # Emits a standalone `REF` source-chain `DmaTag` referencing an external buffer of `qwc` quadwords at `addr`.
        def ref(addr : UInt32, qwc : Int, irq : Bool = false, spr : Bool = false) : self
          if qwc < 0 || qwc > Citrine::Core::DMA::MAX_QWC
            raise ArgumentError.new("DMATag REF QWC (#{qwc}) exceeds 16-bit hardware limit")
          end
          @buffer.emit_dma_tag(DmaTag.new(qwc: qwc.to_u16, id: DmaTagId::Ref, addr: addr, irq: irq, spr: spr))
          self
        end

        # Emits a standalone `REFE` source-chain `DmaTag` referencing an external buffer at `addr` and terminating the chain.
        def refe(addr : UInt32, qwc : Int, irq : Bool = false, spr : Bool = false) : self
          if qwc < 0 || qwc > Citrine::Core::DMA::MAX_QWC
            raise ArgumentError.new("DMATag REFE QWC (#{qwc}) exceeds 16-bit hardware limit")
          end
          @buffer.emit_dma_tag(DmaTag.new(qwc: qwc.to_u16, id: DmaTagId::Refe, addr: addr, irq: irq, spr: spr))
          self
        end

        # Opens a `CALL` source-chain `DmaTag` pushing the return tag address to `ASR` and jumping to `subroutine_addr`.
        def call_tag(subroutine_addr : UInt32, irq : Bool = false, spr : Bool = false) : self
          @buffer.emit_dma_tag(DmaTag.new(qwc: 0_u16, id: DmaTagId::Call, addr: subroutine_addr, irq: irq, spr: spr))
          self
        end

        # Opens a `CALL` source-chain `DmaTag` with inline payload quadwords before jumping to `subroutine_addr`.
        def call_tag(subroutine_addr : UInt32, irq : Bool = false, spr : Bool = false, &block : PacketBuilder ->) : self
          @buffer.open_dma_tag(id: DmaTagId::Call, addr: subroutine_addr, irq: irq, spr: spr)
          begin
            yield self
          ensure
            @buffer.close_dma_tag!
          end
          self
        end

        # Opens a `RET` source-chain `DmaTag` popping the return address from `ASR`.
        def ret_tag(irq : Bool = false) : self
          @buffer.emit_dma_tag(DmaTag.new(qwc: 0_u16, id: DmaTagId::Ret, addr: 0_u32, irq: irq))
          self
        end

        # Opens a `RET` source-chain `DmaTag` with inline payload quadwords before returning from `ASR`.
        def ret_tag(irq : Bool = false, &block : PacketBuilder ->) : self
          @buffer.open_dma_tag(id: DmaTagId::Ret, addr: 0_u32, irq: irq)
          begin
            yield self
          ensure
            @buffer.close_dma_tag!
          end
          self
        end

        # Emits an empty `END` source-chain `DmaTag` (`QWC=0`) terminating the chain.
        def end_tag(irq : Bool = false) : self
          @buffer.emit_dma_tag(DmaTag.new(qwc: 0_u16, id: DmaTagId::End, addr: 0_u32, irq: irq))
          self
        end

        # Opens an `END` source-chain `DmaTag` with inline payload quadwords, terminating the chain after transfer.
        def end_tag(irq : Bool = false, &block : PacketBuilder ->) : self
          @buffer.open_dma_tag(id: DmaTagId::End, addr: 0_u32, irq: irq)
          begin
            yield self
          ensure
            @buffer.close_dma_tag!
          end
          self
        end

        # Emits a raw 128-bit quadword `(lo, hi)`.
        def qword(lo : UInt64, hi : UInt64) : self
          @buffer.emit_qword(lo, hi)
          self
        end
      end

      # =========================================================================
      # Top-Level Declarative Entry Points (`packet`, `chain`, `draw`, `env_packet`)
      # =========================================================================

      # Builds a DMA packet in a newly allocated `PacketBuffer` of `capacity_qwc` quadwords,
      # yields a `PacketBuilder`, finalizes open tags, and returns the completed `PacketBuffer`.
      def self.build(
        channel : Channel = Channel::GIF,
        capacity_qwc : Int32 = 4096,
        &block : PacketBuilder ->
      ) : PacketBuffer
        buf = PacketBuffer.new(capacity_qwc)
        builder = PacketBuilder.new(buf, channel)
        yield builder
        buf.finalize!
      end

      # Builds a DMA packet into an existing `PacketBuffer` or `Bytes` slice (Zero-Allocation when reusing buffer).
      def self.build_into(
        target : PacketBuffer | Bytes,
        channel : Channel = Channel::GIF,
        &block : PacketBuilder ->
      ) : PacketBuffer
        buf = target.is_a?(PacketBuffer) ? target.reset! : PacketBuffer.new(target)
        builder = PacketBuilder.new(buf, channel)
        yield builder
        buf.finalize!
      end

      # Builds a DMA packet and returns the resulting `Bytes` slice directly.
      def self.packet(
        channel : Channel = Channel::GIF,
        capacity_qwc : Int32 = 4096,
        &block : PacketBuilder ->
      ) : Bytes
        build(channel, capacity_qwc, &block).to_slice
      end

      # Builds a single-batch GIF A+D (`0x0E`) drawing packet with `EOP=1` and returns the `Bytes` slice.
      def self.draw(capacity_qwc : Int32 = 4096, eop : Bool = true, &block : AdBuilder ->) : Bytes
        packet(Channel::GIF, capacity_qwc) do |pkt|
          pkt.gif_ad(eop: eop) do |gs|
            block.call(gs)
          end
        end
      end

      # Builds a Source-Chain DMA packet (`MOD = Chain`) and verifies that the chain terminates with `END`, `REFE`, or `RET`.
      def self.chain(
        channel : Channel = Channel::GIF,
        capacity_qwc : Int32 = 4096,
        auto_terminate : Bool = true,
        &block : PacketBuilder ->
      ) : PacketBuffer
        buf = PacketBuffer.new(capacity_qwc)
        builder = PacketBuilder.new(buf, channel)
        yield builder
        buf.finalize!
        if auto_terminate && !buf.chain_terminated?
          builder.end_tag
        end
        buf
      end

      # Generates the canonical 14-quadword (224-byte) NTSC 640x448 GS environment initialization packet.
      def self.env_packet(width : Int32 = 640, height : Int32 = 448, fbp : UInt32 = 0_u32, zbp : UInt32 = 140_u32) : Bytes
        draw(capacity_qwc: 16, eop: true) do |gs|
          gs.default_env(width: width, height: height, fbp: fbp, zbp: zbp)
        end
      end
    end
  end

  # Top-level ergonomic alias `Citrine::DMA` pointing to `Citrine::DSL::DMA`.
  alias DMA = Citrine::DSL::DMA
end
