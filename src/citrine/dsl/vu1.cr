# Citrine PlayStation 2 Declarative VU1 Microcode Assembler & VIF1 Pipeline DSL (Tier 2)
# Ergonomic, block-scoped builders wrapping `Citrine::Core::VU1` and `Citrine::Core::DMA`
# with vector math macros (`mat4_mul_vec4`, `mat4_mul_mat4`, `dot3`, `dot4`, `cross3`,
# `normalize3`, `perspective_divide`, `vec_lerp`, `directional_light`), GS `XGKICK`
# double-buffered GIFTag emission, hazard-free loop constructs, and VIF1 batch packing.

require "../core/dma"
require "../core/vu1"
require "./dma"

module Citrine
  module DSL
    module VU1
      alias DestMask = Citrine::Core::VU1::DestMask
      alias Broadcast = Citrine::Core::VU1::Broadcast
      alias VfReg = Citrine::Core::VU1::VfReg
      alias ViReg = Citrine::Core::VU1::ViReg
      alias UpperOp = Citrine::Core::VU1::UpperOp
      alias LowerOp = Citrine::Core::VU1::LowerOp
      alias UpperInstruction = Citrine::Core::VU1::UpperInstruction
      alias LowerInstruction = Citrine::Core::VU1::LowerInstruction
      alias MicroInstruction = Citrine::Core::VU1::MicroInstruction
      alias HazardSeverity = Citrine::Core::VU1::HazardSeverity
      alias HazardKind = Citrine::Core::VU1::HazardKind
      alias Hazard = Citrine::Core::VU1::Hazard
      alias HazardError = Citrine::Core::VU1::HazardError
      alias HazardReport = Citrine::Core::VU1::HazardReport
      alias HazardDetector = Citrine::Core::VU1::HazardDetector
      alias VifCmd = Citrine::Core::VU1::VifCmd
      alias UnpackFormat = Citrine::Core::VU1::UnpackFormat
      alias VifCode = Citrine::Core::VU1::VifCode
      alias VifPacketPacker = Citrine::Core::VU1::VifPacketPacker
      alias DoubleBufferConfig = Citrine::Core::VU1::DoubleBufferConfig
      alias AssembledProgram = Citrine::Core::VU1::AssembledProgram
      alias Assembler = Citrine::Core::VU1::Assembler

      alias GifTag = Citrine::Core::DMA::GifTag
      alias GifReg = Citrine::Core::DMA::GifReg
      alias GifFormat = Citrine::Core::DMA::GifFormat
      alias GsReg = Citrine::Core::DMA::GsReg
      alias Primitive = Citrine::Core::DMA::Primitive
      alias GsEncoder = Citrine::Core::DMA::GsEncoder
      alias Quadword = Citrine::Core::DMA::Quadword

      # Type union accepted for VF register arguments across the declarative DSL.
      alias VfSpec = VfReg | Int32 | UInt8 | String | Symbol

      # Type union accepted for VI register arguments across the declarative DSL.
      alias ViSpec = ViReg | Int32 | UInt8 | String | Symbol

      # Type union accepted for vector destination masks (`.xyzw`, `:xyz`, `DestMask::XY`).
      alias MaskSpec = DestMask | String | Symbol | UInt8

      # Type union accepted for broadcast lanes (`:x`, `:y`, `:z`, `:w`).
      alias BroadcastSpec = Broadcast | String | Symbol | UInt8

      # =========================================================================
      # Declarative GIFTag Construction Helpers for GS Path 1 (`XGKICK`)
      # =========================================================================

      # Resolves a symbolic or enum primitive type (`:triangle`, `:triangle_strip`, `:sprite`, etc.).
      def self.parse_primitive(type : Primitive | Symbol | String) : Primitive
        return type if type.is_a?(Primitive)
        case type.to_s.downcase
        when "point"               then Primitive::Point
        when "line"                then Primitive::Line
        when "line_strip", "strip" then Primitive::LineStrip
        when "triangle", "tri"     then Primitive::Triangle
        when "triangle_strip"      then Primitive::TriangleStrip
        when "triangle_fan", "fan" then Primitive::TriangleFan
        when "sprite", "rect"      then Primitive::Sprite
        else
          raise ArgumentError.new("Unknown GS primitive specifier: #{type}")
        end
      end

      # Resolves a symbolic or enum `GifReg` descriptor (`:rgbaq`, `:xyz2`, `:st`, `:uv`, `:ad`, etc.).
      def self.parse_gif_reg(reg : GifReg | Symbol | String) : GifReg
        return reg if reg.is_a?(GifReg)
        case reg.to_s.downcase
        when "prim"    then GifReg::Prim
        when "rgbaq"   then GifReg::Rgbaq
        when "st"      then GifReg::St
        when "uv"      then GifReg::Uv
        when "xyzf2"   then GifReg::Xyzf2
        when "xyz2"    then GifReg::Xyz2
        when "tex0_1"  then GifReg::Tex0_1
        when "tex0_2"  then GifReg::Tex0_2
        when "clamp_1" then GifReg::Clamp_1
        when "clamp_2" then GifReg::Clamp_2
        when "fog"     then GifReg::Fog
        when "xyzf3"   then GifReg::Xyzf3
        when "xyz3"    then GifReg::Xyz3
        when "ad"      then GifReg::AD
        when "nop"     then GifReg::Nop
        else
          raise ArgumentError.new("Unknown GIF register descriptor: #{reg}")
        end
      end

      # Builds a 128-bit `GifTag` configured for VU1 `XGKICK` Path 1 emission.
      def self.build_gif_tag(
        primitive : Primitive | Symbol | String = :triangle,
        nloop : Int = 3,
        eop : Bool = true,
        pre : Bool = true,
        gouraud : Bool = true,
        textured : Bool = false,
        fog : Bool = false,
        alpha_blend : Bool = false,
        antialias : Bool = false,
        use_uv : Bool = false,
        context : Int = 0,
        fix : Bool = false,
        flg : GifFormat = GifFormat::Packed,
        regs : Enumerable(GifReg | Symbol | String) = [:rgbaq, :xyz2],
      ) : GifTag
        prim_enum = parse_primitive(primitive)
        prim_bits = GsEncoder.encode_prim(
          prim_enum,
          gouraud: gouraud,
          textured: textured,
          fog: fog,
          alpha_blend: alpha_blend,
          antialias: antialias,
          use_uv: use_uv,
          context: context,
          fix: fix
        ).to_u16

        parsed_regs = regs.map { |r| parse_gif_reg(r) }.to_a
        if parsed_regs.empty? || parsed_regs.size > 16
          raise ArgumentError.new("GIFTag requires between 1 and 16 register descriptors")
        end

        packed_regs = 0_u64
        parsed_regs.each_with_index do |r, idx|
          packed_regs |= ((r.value.to_u64 & 0xF_u64) << (idx * 4))
        end

        GifTag.new(
          nloop: nloop.to_u16,
          eop: eop,
          pre: pre,
          prim: prim_bits,
          flg: flg,
          nreg: parsed_regs.size.to_u8,
          regs: packed_regs
        )
      end

      # =========================================================================
      # Compile-Time Vector Math & XGKICK Macros
      # =========================================================================

      # Compile-time macro expanding a 4-cycle 4x4 matrix * 4D vector multiplication
      # (`MULAx`, `MADDAy`, `MADDAz`, `MADDw`) on a `ProgramBuilder` receiver.
      macro mat4_mul_vec4_macro(builder, dst_vf, row0_vf, row1_vf, row2_vf, row3_vf, src_vf, mask = :xyzw)
        {{builder}}.mulax({{row0_vf}}, {{src_vf}}, mask: {{mask}})
        {{builder}}.madday({{row1_vf}}, {{src_vf}}, mask: {{mask}})
        {{builder}}.maddaz({{row2_vf}}, {{src_vf}}, mask: {{mask}})
        {{builder}}.maddw({{dst_vf}}, {{row3_vf}}, {{src_vf}}, mask: {{mask}})
      end

      # Compile-time macro expanding a 2-cycle hardware 3D cross product (`OPMULA.xyz`, `OPMSUB.xyz`).
      macro cross3_macro(builder, dst_vf, a_vf, b_vf)
        {{builder}}.opmula({{a_vf}}, {{b_vf}})
        {{builder}}.opmsub({{dst_vf}}, {{b_vf}}, {{a_vf}})
      end

      # =========================================================================
      # Declarative VU1 Microprogram Builder (`ProgramBuilder`)
      # =========================================================================

      class ProgramBuilder
        getter name : String
        getter assembler : Assembler
        getter gif_tags : Array(GifTag)
        getter double_buffer_config : DoubleBufferConfig?
        getter vf_aliases : Hash(String, VfReg)
        getter vi_aliases : Hash(String, ViReg)

        def initialize(@name : String = "vu1_program")
          @assembler = Assembler.new
          @gif_tags = [] of GifTag
          @double_buffer_config = nil
          @vf_aliases = {} of String => VfReg
          @vi_aliases = {} of String => ViReg
          @last_xgkick_pc = nil.as(Int32?)
        end

        # Current instruction program counter (in 64-bit VLIW instruction units).
        def pc : Int32
          @assembler.pc
        end

        # =====================================================================
        # Register Resolution & Symbolic Aliasing
        # =====================================================================

        # Defines a symbolic alias for a VF vector register (e.g. `vu.alias_vf(:mvp_row0, :vf01)`).
        def alias_vf(alias_name : Symbol | String, target : VfSpec) : VfReg
          resolved = resolve_vf(target)
          @vf_aliases[alias_name.to_s] = resolved
          resolved
        end

        # Defines a symbolic alias for a VI integer register (e.g. `vu.alias_vi(:kick_ptr, :vi02)`).
        def alias_vi(alias_name : Symbol | String, target : ViSpec) : ViReg
          resolved = resolve_vi(target)
          @vi_aliases[alias_name.to_s] = resolved
          resolved
        end

        def vf(spec : VfSpec) : VfReg
          resolve_vf(spec)
        end

        def vi(spec : ViSpec) : ViReg
          resolve_vi(spec)
        end

        private def resolve_vf(spec : VfSpec) : VfReg
          return spec if spec.is_a?(VfReg)
          if spec.is_a?(Symbol) || spec.is_a?(String)
            key = spec.to_s.strip.lstrip('$')
            if dot = key.index('.')
              key = key[0...dot]
            end
            if aliased = @vf_aliases[key]?
              return aliased
            end
          end
          VfReg.parse(spec)
        end

        private def resolve_vi(spec : ViSpec) : ViReg
          return spec if spec.is_a?(ViReg)
          if spec.is_a?(Symbol) || spec.is_a?(String)
            key = spec.to_s.strip.lstrip('$')
            if aliased = @vi_aliases[key]?
              return aliased
            end
          end
          ViReg.parse(spec)
        end

        private def resolve_mask(spec : MaskSpec) : DestMask
          DestMask.parse(spec)
        end

        private def resolve_bc(spec : BroadcastSpec) : Broadcast
          Broadcast.parse(spec)
        end

        # =====================================================================
        # Core Dual-Issue, Single-Issue & Raw Assembly Emission
        # =====================================================================

        # Emits an explicit dual-issue `(upper, lower)` instruction pair.
        def dual(
          upper : UpperInstruction = UpperInstruction.nop,
          lower : LowerInstruction = LowerInstruction.nop,
        ) : self
          @last_xgkick_pc = pc if lower.op.xgkick?
          @assembler.emit(upper, lower)
          self
        end

        # Emits a single or multi-line VSM assembly snippet (`"MUL.xyzw vf01, vf02, vf03 | LQ.xyzw vf04, 0(vi01)"`).
        def asm(vsm_source : String) : self
          before_pc = pc
          @assembler.parse_and_emit(vsm_source)
          (before_pc...pc).each do |idx|
            if @assembler.instructions[idx].lower.op.xgkick?
              @last_xgkick_pc = idx
            end
          end
          self
        end

        # Defines a symbolic branch target label at the current instruction PC.
        def label(name : String | Symbol) : self
          @assembler.label(name)
          self
        end

        # Emits `count` dual-issue `NOP | NOP` instructions.
        def nop(count : Int = 1, flag_e : Bool = false) : self
          count.times do |i|
            @assembler.nop(flag_e: (i == count - 1) ? flag_e : false)
          end
          self
        end

        # Emits the canonical PS2 VU1 microprogram termination sequence:
        # `NOP[E] | NOP` followed by its mandatory 1-cycle delay slot `NOP | NOP`.
        def end_program : self
          @assembler.nop(flag_e: true)
          @assembler.nop(flag_e: false)
          self
        end

        def halt! : self
          end_program
        end

        # =====================================================================
        # Upper Pipeline (FMAC Vector ALU) Declarative Instructions
        # =====================================================================

        def emit_upper(
          op : UpperOp,
          fd : VfSpec = 0,
          fs : VfSpec = 0,
          ft : VfSpec = 0,
          mask : MaskSpec = :xyzw,
          bc : BroadcastSpec = :x,
          lower : LowerInstruction = LowerInstruction.nop,
          flag_e : Bool = false,
          flag_m : Bool = false,
          flag_d : Bool = false,
          flag_t : Bool = false,
        ) : self
          u = UpperInstruction.new(
            op: op,
            dest: resolve_mask(mask),
            fd: resolve_vf(fd).index,
            fs: resolve_vf(fs).index,
            ft: resolve_vf(ft).index,
            bc: resolve_bc(bc),
            flag_e: flag_e,
            flag_m: flag_m,
            flag_d: flag_d,
            flag_t: flag_t
          )
          dual(u, lower)
        end

        def add(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ADD, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def addi(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ADDI, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def addq(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ADDQ, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def addbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ADDBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def addx(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          addbc(fd, fs, ft, :x, mask: mask, lower: lower)
        end

        def addy(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          addbc(fd, fs, ft, :y, mask: mask, lower: lower)
        end

        def addz(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          addbc(fd, fs, ft, :z, mask: mask, lower: lower)
        end

        def addw(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          addbc(fd, fs, ft, :w, mask: mask, lower: lower)
        end

        def sub(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::SUB, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def subi(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::SUBI, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def subq(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::SUBQ, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def subbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::SUBBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def subx(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          subbc(fd, fs, ft, :x, mask: mask, lower: lower)
        end

        def suby(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          subbc(fd, fs, ft, :y, mask: mask, lower: lower)
        end

        def subz(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          subbc(fd, fs, ft, :z, mask: mask, lower: lower)
        end

        def subw(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          subbc(fd, fs, ft, :w, mask: mask, lower: lower)
        end

        def mul(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MUL, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def muli(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MULI, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def mulq(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MULQ, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def mulbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MULBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def mulx(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulbc(fd, fs, ft, :x, mask: mask, lower: lower)
        end

        def muly(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulbc(fd, fs, ft, :y, mask: mask, lower: lower)
        end

        def mulz(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulbc(fd, fs, ft, :z, mask: mask, lower: lower)
        end

        def mulw(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulbc(fd, fs, ft, :w, mask: mask, lower: lower)
        end

        def madd(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADD, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def maddi(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADDI, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def maddq(fd : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADDQ, fd: fd, fs: fs, mask: mask, lower: lower)
        end

        def maddbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADDBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def maddx(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddbc(fd, fs, ft, :x, mask: mask, lower: lower)
        end

        def maddy(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddbc(fd, fs, ft, :y, mask: mask, lower: lower)
        end

        def maddz(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddbc(fd, fs, ft, :z, mask: mask, lower: lower)
        end

        def maddw(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddbc(fd, fs, ft, :w, mask: mask, lower: lower)
        end

        def msub(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MSUB, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def msubbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MSUBBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def max(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MAX, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def maxbc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MAXBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def mini(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MINI, fd: fd, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def minibc(fd : VfSpec, fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MINIBC, fd: fd, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def miniw(fd : VfSpec, fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          minibc(fd, fs, ft, :w, mask: mask, lower: lower)
        end

        # Accumulator (`ACC`) operations
        def adda(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ADDA, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def mula(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MULA, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def madda(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADDA, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def msuba(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MSUBA, fs: fs, ft: ft, mask: mask, lower: lower)
        end

        def mulabc(fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MULABC, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def mulax(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulabc(fs, ft, :x, mask: mask, lower: lower)
        end

        def mulay(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulabc(fs, ft, :y, mask: mask, lower: lower)
        end

        def mulaz(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulabc(fs, ft, :z, mask: mask, lower: lower)
        end

        def mulaw(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          mulabc(fs, ft, :w, mask: mask, lower: lower)
        end

        def maddabc(fs : VfSpec, ft : VfSpec, bc : BroadcastSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::MADDABC, fs: fs, ft: ft, mask: mask, bc: bc, lower: lower)
        end

        def maddax(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddabc(fs, ft, :x, mask: mask, lower: lower)
        end

        def madday(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddabc(fs, ft, :y, mask: mask, lower: lower)
        end

        def maddaz(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddabc(fs, ft, :z, mask: mask, lower: lower)
        end

        def maddaw(fs : VfSpec, ft : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          maddabc(fs, ft, :w, mask: mask, lower: lower)
        end

        def opmula(fs : VfSpec, ft : VfSpec, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::OPMULA, fs: fs, ft: ft, mask: :xyz, lower: lower)
        end

        def opmsub(fd : VfSpec, fs : VfSpec, ft : VfSpec, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::OPMSUB, fd: fd, fs: fs, ft: ft, mask: :xyz, lower: lower)
        end

        def abs(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ABS, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def clip(fs : VfSpec, ft : VfSpec, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::CLIP, fs: fs, ft: ft, mask: :xyz, bc: :w, lower: lower)
        end

        def ftoi0(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::FTOI0, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def ftoi4(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::FTOI4, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def ftoi12(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::FTOI12, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def ftoi15(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::FTOI15, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def itof0(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ITOF0, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def itof4(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ITOF4, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def itof12(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ITOF12, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        def itof15(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, lower : LowerInstruction = LowerInstruction.nop) : self
          emit_upper(UpperOp::ITOF15, ft: ft, fs: fs, mask: mask, lower: lower)
        end

        # =====================================================================
        # Lower Pipeline (Load/Store, Integer ALU, FDIV, Branch, XGKICK)
        # =====================================================================

        def lq(ft : VfSpec, is : ViSpec, offset : Int = 0, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::LQ,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            is: resolve_vi(is).index,
            imm: offset.to_i32
          )
          dual(upper, l)
        end

        def sq(fs : VfSpec, it : ViSpec, offset : Int = 0, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::SQ,
            dest: resolve_mask(mask),
            fs: resolve_vf(fs).index,
            it: resolve_vi(it).index,
            imm: offset.to_i32
          )
          dual(upper, l)
        end

        def lqi(ft : VfSpec, is : ViSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::LQI,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            is: resolve_vi(is).index
          )
          dual(upper, l)
        end

        def sqi(fs : VfSpec, it : ViSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::SQI,
            dest: resolve_mask(mask),
            fs: resolve_vf(fs).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def lqd(ft : VfSpec, is : ViSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::LQD,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            is: resolve_vi(is).index
          )
          dual(upper, l)
        end

        def sqd(fs : VfSpec, it : ViSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::SQD,
            dest: resolve_mask(mask),
            fs: resolve_vf(fs).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def ilw(it : ViSpec, is : ViSpec, offset : Int = 0, mask : MaskSpec = :x, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::ILW,
            dest: resolve_mask(mask),
            it: resolve_vi(it).index,
            is: resolve_vi(is).index,
            imm: offset.to_i32
          )
          dual(upper, l)
        end

        def isw(it : ViSpec, is : ViSpec, offset : Int = 0, mask : MaskSpec = :x, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::ISW,
            dest: resolve_mask(mask),
            it: resolve_vi(it).index,
            is: resolve_vi(is).index,
            imm: offset.to_i32
          )
          dual(upper, l)
        end

        def iadd(id : ViSpec, is : ViSpec, it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::IADD,
            id: resolve_vi(id).index,
            is: resolve_vi(is).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def isub(id : ViSpec, is : ViSpec, it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::ISUB,
            id: resolve_vi(id).index,
            is: resolve_vi(is).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def iaddi(it : ViSpec, is : ViSpec, imm5 : Int, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::IADDI,
            it: resolve_vi(it).index,
            is: resolve_vi(is).index,
            imm: imm5.to_i32
          )
          dual(upper, l)
        end

        def iaddiu(it : ViSpec, is : ViSpec, imm15 : Int, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::IADDIU,
            it: resolve_vi(it).index,
            is: resolve_vi(is).index,
            imm: imm15.to_i32
          )
          dual(upper, l)
        end

        def isubiu(it : ViSpec, is : ViSpec, imm15 : Int, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::ISUBIU,
            it: resolve_vi(it).index,
            is: resolve_vi(is).index,
            imm: imm15.to_i32
          )
          dual(upper, l)
        end

        def iand(id : ViSpec, is : ViSpec, it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::IAND,
            id: resolve_vi(id).index,
            is: resolve_vi(is).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def ior(id : ViSpec, is : ViSpec, it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::IOR,
            id: resolve_vi(id).index,
            is: resolve_vi(is).index,
            it: resolve_vi(it).index
          )
          dual(upper, l)
        end

        def move(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::MOVE,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            fs: resolve_vf(fs).index
          )
          dual(upper, l)
        end

        def mr32(ft : VfSpec, fs : VfSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::MR32,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            fs: resolve_vf(fs).index
          )
          dual(upper, l)
        end

        def mfir(ft : VfSpec, is : ViSpec, mask : MaskSpec = :xyzw, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::MFIR,
            dest: resolve_mask(mask),
            ft: resolve_vf(ft).index,
            is: resolve_vi(is).index
          )
          dual(upper, l)
        end

        def mtir(it : ViSpec, fs : VfSpec, fsf : BroadcastSpec = :x, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::MTIR,
            it: resolve_vi(it).index,
            fs: resolve_vf(fs).index,
            fsf: resolve_bc(fsf)
          )
          dual(upper, l)
        end

        def loi(value : Number, upper : UpperInstruction = UpperInstruction.nop) : self
          @assembler.emit_loi(value.to_f32, upper)
          self
        end

        def div(fs : VfSpec, fsf : BroadcastSpec, ft : VfSpec, ftf : BroadcastSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::DIV,
            fs: resolve_vf(fs).index,
            fsf: resolve_bc(fsf),
            ft: resolve_vf(ft).index,
            ftf: resolve_bc(ftf)
          )
          dual(upper, l)
        end

        def sqrt(ft : VfSpec, ftf : BroadcastSpec = :x, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::SQRT,
            ft: resolve_vf(ft).index,
            ftf: resolve_bc(ftf)
          )
          dual(upper, l)
        end

        def rsqrt(fs : VfSpec, fsf : BroadcastSpec, ft : VfSpec, ftf : BroadcastSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          l = LowerInstruction.new(
            op: LowerOp::RSQRT,
            fs: resolve_vf(fs).index,
            fsf: resolve_bc(fsf),
            ft: resolve_vf(ft).index,
            ftf: resolve_bc(ftf)
          )
          dual(upper, l)
        end

        def waitq(upper : UpperInstruction = UpperInstruction.nop) : self
          dual(upper, LowerInstruction.new(op: LowerOp::WAITQ, dest: DestMask::None))
        end

        def waitp(upper : UpperInstruction = UpperInstruction.nop) : self
          dual(upper, LowerInstruction.new(op: LowerOp::WAITP, dest: DestMask::None))
        end

        def xtop(it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          dual(upper, LowerInstruction.new(op: LowerOp::XTOP, dest: DestMask::None, it: resolve_vi(it).index))
        end

        def xitop(it : ViSpec, upper : UpperInstruction = UpperInstruction.nop) : self
          dual(upper, LowerInstruction.new(op: LowerOp::XITOP, dest: DestMask::None, it: resolve_vi(it).index))
        end

        def xgkick(is : ViSpec, upper : UpperInstruction = UpperInstruction.nop, ensure_no_stall : Bool = false) : self
          if ensure_no_stall
            if prev = @last_xgkick_pc
              gap = pc - prev
              if gap < 4
                nop(4 - gap)
              end
            end
          end
          l = LowerInstruction.new(op: LowerOp::XGKICK, dest: DestMask::None, is: resolve_vi(is).index)
          dual(upper, l)
        end

        def b(target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::B, dest: DestMask::None, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def bal(it : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::BAL, dest: DestMask::None, it: resolve_vi(it).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def jr(is : ViSpec, delay_slot : Bool = false) : self
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::JR, dest: DestMask::None, is: resolve_vi(is).index))
          nop if delay_slot
          self
        end

        def jalr(it : ViSpec, is : ViSpec, delay_slot : Bool = false) : self
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::JALR, dest: DestMask::None, it: resolve_vi(it).index, is: resolve_vi(is).index))
          nop if delay_slot
          self
        end

        def ibeq(it : ViSpec, is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBEQ, dest: DestMask::None, it: resolve_vi(it).index, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def ibne(it : ViSpec, is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBNE, dest: DestMask::None, it: resolve_vi(it).index, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def ibltz(is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBLTZ, dest: DestMask::None, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def ibgtz(is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBGTZ, dest: DestMask::None, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def iblez(is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBLEZ, dest: DestMask::None, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        def ibgez(is : ViSpec, target : String | Symbol | Int32, delay_slot : Bool = false) : self
          lbl = target.is_a?(Int32) ? nil : target.to_s
          imm = target.is_a?(Int32) ? target : 0
          dual(UpperInstruction.nop, LowerInstruction.new(op: LowerOp::IBGEZ, dest: DestMask::None, is: resolve_vi(is).index, imm: imm, target_label: lbl))
          nop if delay_slot
          self
        end

        # =====================================================================
        # Structured Hazard-Free Loop Construct (`vu.loop`)
        # =====================================================================

        # Emits a counted VU1 hardware loop that:
        # 1. Optionally initializes `counter_vi` with `count` (`IADDIU counter_vi, vi00, count`)
        # 2. Binds `label(name)`
        # 3. Yields to emit the loop body
        # 4. Decrements `counter_vi` (`IADDI counter_vi, counter_vi, -1`)
        # 5. Inserts the mandatory 1-cycle separation `NOP | NOP` to prevent `ViBranchHazard`
        # 6. Emits `IBNE counter_vi, vi00, name` followed by the branch delay slot `NOP | NOP`
        def loop(
          counter_vi : ViSpec,
          count : Int? = nil,
          name : String | Symbol = :loop,
          &block
        ) : self
          if cnt = count
            iaddiu(counter_vi, :vi00, cnt)
          end
          label(name)
          yield
          iaddi(counter_vi, counter_vi, -1)
          nop # 1-cycle separation avoiding PS2 VU1 VI -> Branch pipeline hazard
          ibne(counter_vi, :vi00, name, delay_slot: true)
          self
        end

        # =====================================================================
        # High-Level Vector & Matrix Math Macros
        # =====================================================================

        # Loads a 4x4 matrix (4 contiguous 128-bit quadwords) from `offset(base_vi)..(offset+3)(base_vi)`
        # into the 4 specified `VF` registers.
        def load_matrix4(
          base_vi : ViSpec,
          offset : Int = 0,
          rows : Indexable(VfSpec) = [:vf01, :vf02, :vf03, :vf04],
        ) : self
          if rows.size != 4
            raise ArgumentError.new("load_matrix4 requires exactly 4 VF registers (got #{rows.size})")
          end
          4.times do |i|
            lq(rows[i], base_vi, offset + i)
          end
          self
        end

        # Stores a 4x4 matrix (4 `VF` registers) into `offset(base_vi)..(offset+3)(base_vi)`.
        def store_matrix4(
          base_vi : ViSpec,
          offset : Int = 0,
          rows : Indexable(VfSpec) = [:vf01, :vf02, :vf03, :vf04],
        ) : self
          if rows.size != 4
            raise ArgumentError.new("store_matrix4 requires exactly 4 VF registers (got #{rows.size})")
          end
          4.times do |i|
            sq(rows[i], base_vi, offset + i)
          end
          self
        end

        # 4-cycle PS2 VU1 4x4 Matrix * 4D Vector multiplication using the FMAC accumulator (`ACC`):
        # - `MULAx.<mask> ACC, rows[0], src_vf`
        # - `MADDAy.<mask> ACC, rows[1], src_vf`
        # - `MADDAz.<mask> ACC, rows[2], src_vf`
        # - `MADDw.<mask> dst_vf, rows[3], src_vf`
        # Optionally accepts up to 4 `LowerInstruction`s to dual-issue in parallel with the 4 FMAC cycles.
        def mat4_mul_vec4(
          dst_vf : VfSpec,
          mat_rows : Indexable(VfSpec),
          src_vf : VfSpec,
          mask : MaskSpec = :xyzw,
          lower_ops : Indexable(LowerInstruction)? = nil,
          wait_fmac : Bool = false,
        ) : self
          if mat_rows.size != 4
            raise ArgumentError.new("mat4_mul_vec4 requires 4 matrix row VF registers (got #{mat_rows.size})")
          end
          l0 = lower_ops.try(&.[0]?) || LowerInstruction.nop
          l1 = lower_ops.try(&.[1]?) || LowerInstruction.nop
          l2 = lower_ops.try(&.[2]?) || LowerInstruction.nop
          l3 = lower_ops.try(&.[3]?) || LowerInstruction.nop

          mulax(mat_rows[0], src_vf, mask: mask, lower: l0)
          madday(mat_rows[1], src_vf, mask: mask, lower: l1)
          maddaz(mat_rows[2], src_vf, mask: mask, lower: l2)
          maddw(dst_vf, mat_rows[3], src_vf, mask: mask, lower: l3)
          nop(3) if wait_fmac
          self
        end

        def transform_vec4(
          dst_vf : VfSpec,
          mat_rows : Indexable(VfSpec),
          src_vf : VfSpec,
          mask : MaskSpec = :xyzw,
          wait_fmac : Bool = false,
        ) : self
          mat4_mul_vec4(dst_vf, mat_rows, src_vf, mask: mask, wait_fmac: wait_fmac)
        end

        # 16-cycle PS2 VU1 4x4 Matrix * 4x4 Matrix multiplication (`dst_rows = lhs_rows * rhs_rows`).
        def mat4_mul_mat4(
          dst_rows : Indexable(VfSpec),
          lhs_rows : Indexable(VfSpec),
          rhs_rows : Indexable(VfSpec),
        ) : self
          if dst_rows.size != 4 || lhs_rows.size != 4 || rhs_rows.size != 4
            raise ArgumentError.new("mat4_mul_mat4 requires 4 VF registers for dst, lhs, and rhs matrices")
          end
          4.times do |i|
            mat4_mul_vec4(dst_rows[i], lhs_rows, rhs_rows[i])
          end
          self
        end

        # 3D Dot Product (`dst_vf.x = a.x*b.x + a.y*b.y + a.z*b.z`).
        # When `wait_fmac` is true, inserts 3-cycle FMAC latency padding between dependent reductions.
        def dot3(
          dst_vf : VfSpec,
          a_vf : VfSpec,
          b_vf : VfSpec,
          scratch_vf : VfSpec? = nil,
          wait_fmac : Bool = true,
        ) : self
          tmp = scratch_vf || dst_vf
          mul(tmp, a_vf, b_vf, mask: :xyz)
          nop(3) if wait_fmac
          addy(tmp, tmp, tmp, mask: :x)
          nop(3) if wait_fmac
          addz(dst_vf, tmp, tmp, mask: :x)
          nop(3) if wait_fmac
          self
        end

        # 4D Dot Product (`dst_vf.x = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w`).
        def dot4(
          dst_vf : VfSpec,
          a_vf : VfSpec,
          b_vf : VfSpec,
          scratch_vf : VfSpec? = nil,
          wait_fmac : Bool = true,
        ) : self
          tmp = scratch_vf || dst_vf
          mul(tmp, a_vf, b_vf, mask: :xyzw)
          nop(3) if wait_fmac
          addy(tmp, tmp, tmp, mask: :x)
          nop(3) if wait_fmac
          addz(tmp, tmp, tmp, mask: :x)
          nop(3) if wait_fmac
          addw(dst_vf, tmp, tmp, mask: :x)
          nop(3) if wait_fmac
          self
        end

        # 2-cycle Hardware 3D Cross Product (`dst_vf.xyz = a_vf.xyz × b_vf.xyz`)
        # using VU1's dedicated `OPMULA.xyz` and `OPMSUB.xyz` outer-product instructions.
        def cross3(dst_vf : VfSpec, a_vf : VfSpec, b_vf : VfSpec, wait_fmac : Bool = false) : self
          opmula(a_vf, b_vf)
          opmsub(dst_vf, b_vf, a_vf)
          nop(3) if wait_fmac
          self
        end

        def outer_product(dst_vf : VfSpec, a_vf : VfSpec, b_vf : VfSpec, wait_fmac : Bool = false) : self
          cross3(dst_vf, a_vf, b_vf, wait_fmac: wait_fmac)
        end

        # Normalizes a 3D vector (`dst_vf.xyz = src_vf.xyz / ||src_vf.xyz||`) using
        # `dot3` + FDIV `RSQRT Q, vf00.w, scratch_vf.x` + `WAITQ` + `MULq.xyz dst_vf, src_vf`.
        def normalize3(
          dst_vf : VfSpec,
          src_vf : VfSpec,
          scratch_vf : VfSpec = :vf30,
          wait_fmac : Bool = true,
        ) : self
          dot3(scratch_vf, src_vf, src_vf, scratch_vf: scratch_vf, wait_fmac: wait_fmac)
          rsqrt(:vf00, :w, scratch_vf, :x)
          waitq
          mulq(dst_vf, src_vf, mask: :xyz)
          nop(3) if wait_fmac
          self
        end

        # Perspective division & GS screen-space viewport projection:
        # 1. `DIV Q, vf00.w, clip_vf.w` + `WAITQ`
        # 2. `MULq.xyz dst_vf, clip_vf`
        # 3. Optional viewport scale (`MUL.xyz dst_vf, dst_vf, scale_vf`) & offset (`ADD.xyz dst_vf, dst_vf, offset_vf`)
        # 4. Optional `FTOI4.xyzw dst_vf, dst_vf` converting floating-point screen coordinates to GS 12.4 fixed-point.
        def perspective_divide(
          dst_vf : VfSpec,
          clip_vf : VfSpec,
          scale_vf : VfSpec? = nil,
          offset_vf : VfSpec? = nil,
          ftoi4_convert : Bool = true,
          wait_fmac : Bool = true,
        ) : self
          div(:vf00, :w, clip_vf, :w)
          waitq
          mulq(dst_vf, clip_vf, mask: :xyz)
          if sc = scale_vf
            nop(3) if wait_fmac
            mul(dst_vf, dst_vf, sc, mask: :xyz)
          end
          if off = offset_vf
            nop(3) if wait_fmac
            add(dst_vf, dst_vf, off, mask: :xyz)
          end
          if ftoi4_convert
            nop(3) if wait_fmac
            ftoi4(dst_vf, dst_vf, mask: :xyzw)
            nop(3) if wait_fmac
          end
          self
        end

        # Clamps vector components to `[0.0, 1.0]` using hardware `vf00 = (0.0, 0.0, 0.0, 1.0)`:
        # - `MAX.<mask> dst_vf, src_vf, vf00` (clamps >= 0.0)
        # - `MINIw.<mask> dst_vf, dst_vf, vf00` (clamps <= 1.0 via `vf00.w`)
        def clamp_01(
          dst_vf : VfSpec,
          src_vf : VfSpec,
          mask : MaskSpec = :xyz,
          wait_fmac : Bool = true,
        ) : self
          max(dst_vf, src_vf, :vf00, mask: mask)
          nop(3) if wait_fmac
          miniw(dst_vf, dst_vf, :vf00, mask: mask)
          nop(3) if wait_fmac
          self
        end

        # Linearly interpolates between `a_vf` and `b_vf` by scalar `t` (`dst = a + (b - a) * t`).
        def vec_lerp(
          dst_vf : VfSpec,
          a_vf : VfSpec,
          b_vf : VfSpec,
          t : Float32 | Float64,
          scratch_vf : VfSpec = :vf30,
          mask : MaskSpec = :xyzw,
          wait_fmac : Bool = true,
        ) : self
          sub(scratch_vf, b_vf, a_vf, mask: mask)
          nop(3) if wait_fmac
          loi(t.to_f32)
          muli(scratch_vf, scratch_vf, mask: mask)
          nop(3) if wait_fmac
          add(dst_vf, a_vf, scratch_vf, mask: mask)
          nop(3) if wait_fmac
          self
        end

        # Linearly interpolates between `a_vf` and `b_vf` using the `.x` component of `t_vf`.
        def vec_lerp(
          dst_vf : VfSpec,
          a_vf : VfSpec,
          b_vf : VfSpec,
          t_vf : VfSpec,
          scratch_vf : VfSpec = :vf30,
          mask : MaskSpec = :xyzw,
          wait_fmac : Bool = true,
        ) : self
          sub(scratch_vf, b_vf, a_vf, mask: mask)
          nop(3) if wait_fmac
          mulx(scratch_vf, scratch_vf, t_vf, mask: mask)
          nop(3) if wait_fmac
          add(dst_vf, a_vf, scratch_vf, mask: mask)
          nop(3) if wait_fmac
          self
        end

        # Computes Lambertian directional lighting (`max(0, dot3(normal, light_dir)) * light_color + ambient`)
        # and optionally converts to integer GS `RGBAQ` (`FTOI0.xyzw`).
        def directional_light(
          dst_rgba_vf : VfSpec,
          normal_vf : VfSpec,
          light_dir_vf : VfSpec,
          light_color_vf : VfSpec,
          ambient_vf : VfSpec? = nil,
          scratch_vf : VfSpec = :vf30,
          to_int : Bool = true,
          wait_fmac : Bool = true,
        ) : self
          dot3(scratch_vf, normal_vf, light_dir_vf, scratch_vf: scratch_vf, wait_fmac: wait_fmac)
          max(scratch_vf, scratch_vf, :vf00, mask: :x)
          nop(3) if wait_fmac
          mulx(dst_rgba_vf, light_color_vf, scratch_vf, mask: :xyz)
          if amb = ambient_vf
            nop(3) if wait_fmac
            add(dst_rgba_vf, dst_rgba_vf, amb, mask: :xyz)
          end
          if to_int
            nop(3) if wait_fmac
            ftoi0(dst_rgba_vf, dst_rgba_vf, mask: :xyzw)
            nop(3) if wait_fmac
          end
          self
        end

        # =====================================================================
        # GS `XGKICK` Double-Buffered GIF Tag Emission
        # =====================================================================

        # Configures VIF1 / VU1 Data Memory double buffering (`BASE`, `OFFSET`, `input_offset`, `kick_offset_a`, `kick_offset_b`).
        def double_buffer(
          base : Int = 0,
          offset : Int = 512,
          input_offset : Int = 0,
          kick_offset_a : Int = 256,
          kick_offset_b : Int = 384,
        ) : DoubleBufferConfig
          cfg = DoubleBufferConfig.new(
            base_qwc: base.to_u16,
            offset_qwc: offset.to_u16,
            input_offset: input_offset.to_u16,
            kick_offset_a: kick_offset_a.to_u16,
            kick_offset_b: kick_offset_b.to_u16
          )
          @double_buffer_config = cfg
          cfg
        end

        # Constructs and registers a 128-bit GS `GifTag` for Path 1 `XGKICK` packets.
        def gif_tag(
          primitive : Primitive | Symbol | String = :triangle,
          nloop : Int = 3,
          eop : Bool = true,
          pre : Bool = true,
          gouraud : Bool = true,
          textured : Bool = false,
          fog : Bool = false,
          alpha_blend : Bool = false,
          antialias : Bool = false,
          use_uv : Bool = false,
          context : Int = 0,
          fix : Bool = false,
          flg : GifFormat = GifFormat::Packed,
          regs : Enumerable(GifReg | Symbol | String) = [:rgbaq, :xyz2],
        ) : GifTag
          tag = Citrine::DSL::VU1.build_gif_tag(
            primitive: primitive,
            nloop: nloop,
            eop: eop,
            pre: pre,
            gouraud: gouraud,
            textured: textured,
            fog: fog,
            alpha_blend: alpha_blend,
            antialias: antialias,
            use_uv: use_uv,
            context: context,
            fix: fix,
            flg: flg,
            regs: regs
          )
          @gif_tags << tag
          tag
        end

        # Emits `XTOP base_vi` followed by `IADDIU out_vi, base_vi, kick_offset` so `base_vi` points
        # to the active VIF1 `TOPS` double-buffer and `out_vi` points to the active `XGKICK` output buffer.
        def xtop_double_buffer(
          base_vi : ViSpec = :vi01,
          out_vi : ViSpec = :vi02,
          kick_offset : Int? = nil,
        ) : self
          db = @double_buffer_config || double_buffer
          resolved_offset = kick_offset || db.kick_offset_a.to_i
          xtop(base_vi)
          iaddiu(out_vi, base_vi, resolved_offset)
          self
        end

        # Emits VU1 microcode instructions to copy or store a 128-bit `GIFTag` header into the active `XGKICK` buffer (`dst_offset(out_vi)`).
        # If `src_vi` is given, loads the 128-bit `GIFTag` from `src_offset(src_vi)` into `giftag_vf` before storing.
        def emit_gif_tag(
          out_vi : ViSpec,
          giftag_vf : VfSpec = :vf31,
          src_vi : ViSpec? = nil,
          src_offset : Int = 0,
          dst_offset : Int = 0,
          primitive : Primitive | Symbol | String = :triangle,
          nloop : Int = 3,
          eop : Bool = true,
          pre : Bool = true,
          gouraud : Bool = true,
          textured : Bool = false,
          regs : Enumerable(GifReg | Symbol | String) = [:rgbaq, :xyz2],
        ) : GifTag
          tag = gif_tag(
            primitive: primitive,
            nloop: nloop,
            eop: eop,
            pre: pre,
            gouraud: gouraud,
            textured: textured,
            regs: regs
          )
          if s_vi = src_vi
            lq(giftag_vf, s_vi, src_offset)
          end
          sq(giftag_vf, out_vi, dst_offset)
          tag
        end

        # Declarative block helper for double-buffered GS `XGKICK` packet emission:
        # 1. Configures/reads active double-buffer base via `XTOP base_vi` and computes `out_vi = base_vi + kick_offset`
        # 2. Constructs and registers the 128-bit `GifTag` (`NLOOP`, `EOP=1`, `PRE=1`, `PRIM`, `REGS`)
        # 3. Copies the 128-bit `GIFTag` header into `0(out_vi)` (`LQ` from `giftag_src_offset(base_vi)` if specified, then `SQ` to `0(out_vi)`)
        # 4. Yields so the caller can emit vertex transformations and store vertex quadwords to `1(out_vi)`, `2(out_vi)`, ...
        # 5. Automatically prevents `< 4`-cycle back-to-back `XGKICK` stalls and emits `XGKICK out_vi`!
        def xgkick_double_buffer(
          base_vi : ViSpec = :vi01,
          out_vi : ViSpec = :vi02,
          giftag_vf : VfSpec = :vf31,
          giftag_src_offset : Int? = 0,
          kick_offset : Int? = nil,
          primitive : Primitive | Symbol | String = :triangle,
          nloop : Int = 3,
          eop : Bool = true,
          pre : Bool = true,
          gouraud : Bool = true,
          textured : Bool = false,
          regs : Enumerable(GifReg | Symbol | String) = [:rgbaq, :xyz2],
          &block
        ) : GifTag
          db = @double_buffer_config || double_buffer
          k_off = kick_offset || db.kick_offset_a.to_i

          xtop_double_buffer(base_vi: base_vi, out_vi: out_vi, kick_offset: k_off)

          tag = gif_tag(
            primitive: primitive,
            nloop: nloop,
            eop: eop,
            pre: pre,
            gouraud: gouraud,
            textured: textured,
            regs: regs
          )

          if src_off = giftag_src_offset
            lq(giftag_vf, base_vi, src_off)
          end
          sq(giftag_vf, out_vi, 0)

          yield

          xgkick(out_vi, ensure_no_stall: true)
          tag
        end

        # Initializes intra-program ping-pong `XGKICK` output buffer pointers in VU1 registers:
        # `out_vi = offset_a` and `sum_vi = offset_a + offset_b`.
        # Calling `swap_xgkick_buffer(out_vi, sum_vi)` after each `XGKICK` toggles `out_vi` between `offset_a` and `offset_b` in 1 cycle (`ISUB out_vi, sum_vi, out_vi`).
        def init_ping_pong_buffers(
          out_vi : ViSpec = :vi02,
          sum_vi : ViSpec = :vi03,
          offset_a : Int = 256,
          offset_b : Int = 384,
        ) : self
          double_buffer(kick_offset_a: offset_a, kick_offset_b: offset_b) if @double_buffer_config.nil?
          iaddiu(out_vi, :vi00, offset_a)
          iaddiu(sum_vi, :vi00, offset_a + offset_b)
          self
        end

        # Toggles `out_vi` between ping-pong buffer A (`offset_a`) and buffer B (`offset_b`) in 1 cycle using `ISUB out_vi, sum_vi, out_vi`.
        def swap_xgkick_buffer(out_vi : ViSpec = :vi02, sum_vi : ViSpec = :vi03) : self
          isub(out_vi, sum_vi, out_vi)
        end

        # Finalizes branch resolution, runs the pipeline hazard detector, and returns the `AssembledProgram`.
        def finalize!(strict_hazards : Bool = true) : AssembledProgram
          prog = @assembler.finalize!(strict_hazards: strict_hazards)
          AssembledProgram.new(
            instructions: prog.instructions,
            labels: prog.labels,
            hazard_report: prog.hazard_report,
            name: @name,
            gif_tags: @gif_tags.dup,
            double_buffer: @double_buffer_config
          )
        end
      end

      # =========================================================================
      # Top-Level Declarative Entry Points (`program`, `vif_packet`)
      # =========================================================================

      # Builds and assembles a declarative VU1 microprogram using a `ProgramBuilder` block receiver.
      def self.program(
        name : String = "vu1_program",
        strict_hazards : Bool = true,
        auto_halt : Bool = false,
        &block : ProgramBuilder ->
      ) : AssembledProgram
        builder = ProgramBuilder.new(name)
        yield builder
        if auto_halt
          has_e_bit = builder.assembler.instructions.any?(&.upper.flag_e?)
          builder.end_program unless has_e_bit
        end
        builder.finalize!(strict_hazards: strict_hazards)
      end

      # Builds a complete 16-byte aligned double-buffered VIF1 DMA packet for an `AssembledProgram`.
      def self.vif_packet(
        program : AssembledProgram,
        batches : Array(Array(Float32)) = [] of Array(Float32),
        gif_tag : GifTag? = nil,
        dst_addr : UInt16 = 0_u16,
        exec_addr : UInt16? = nil,
      ) : Bytes
        program.pack_double_buffered_vif1(
          batches: batches,
          gif_tag: gif_tag,
          dst_addr: dst_addr,
          exec_addr: exec_addr
        )
      end
    end
  end

  # Top-level ergonomic alias `Citrine::VU1` pointing to `Citrine::DSL::VU1`.
  alias VU1 = Citrine::DSL::VU1

  # Primary declarative entry point `Citrine.vu1_program` for authoring PS2 VU1 microprograms
  # with vector math macros and GS `XGKICK` double-buffered GIFTag emission.
  def self.vu1_program(
    name : String = "vu1_program",
    strict_hazards : Bool = true,
    auto_halt : Bool = false,
    &block : Citrine::DSL::VU1::ProgramBuilder ->
  ) : Citrine::Core::VU1::AssembledProgram
    Citrine::DSL::VU1.program(name: name, strict_hazards: strict_hazards, auto_halt: auto_halt, &block)
  end
end
