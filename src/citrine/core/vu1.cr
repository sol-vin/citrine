# Citrine PlayStation 2 Vector Unit 1 (VU1) Microcode Assembler & VIF1 Packet Engine (Tier 1)
# Pure, strongly-typed structs, dual-issue 64-bit VLIW instruction encoders, compile-time
# and assembly-time pipeline hazard detectors, and zero-allocation VIF1 packet packers
# (`MPG`, `UNPACK`, `MSCAL`, `FLUSH`) targeting the Emotion Engine Vector Unit 1.

require "io/memory"
require "./dma"

module Citrine
  module Core
    module VU1
      # =========================================================================
      # Hardware Constants & Memory Addresses
      # =========================================================================

      # EE memory-mapped base address of VU1 Micro Memory (16 KB = 2,048 x 64-bit instructions).
      VU1_MICRO_MEM_BASE = 0x11008000_u32
      VU1_MICRO_MEM_SIZE = 0x00004000_u32

      # EE memory-mapped base address of VU1 Data Memory / VU Mem1 (16 KB = 1,024 x 128-bit quadwords).
      VU1_DATA_MEM_BASE = 0x1100C000_u32
      VU1_DATA_MEM_SIZE = 0x00004000_u32

      # Maximum 64-bit VLIW microinstructions in VU1 Micro Memory (16,384 / 8 = 2,048).
      MAX_MICRO_INSTRUCTIONS = 2048

      # Maximum 128-bit quadwords in VU1 Data Memory (16,384 / 16 = 1,024).
      MAX_DATA_QWC = 1024

      # Maximum 64-bit instructions transferable in a single VIF1 `MPG` command (`NUM = 0` means 256).
      MAX_MPG_CHUNK = 256

      # Canonical 32-bit Upper NOP instruction (`NOP`: `0x000002FF`).
      UPPER_NOP_WORD = 0x000002FF_u32

      # Canonical 32-bit Lower NOP instruction (`MOVE.none vf00, vf00`: `0x8000033C`).
      LOWER_NOP_WORD = 0x8000033C_u32

      # Canonical 64-bit Dual-Issue NOP (`UPPER_NOP << 32 | LOWER_NOP`).
      VLIW_NOP_WORD = (UPPER_NOP_WORD.to_u64 << 32) | LOWER_NOP_WORD.to_u64

      # =========================================================================
      # Registers, Vector Component Masks & Broadcast Lanes
      # =========================================================================

      # 4-bit Vector Component Destination Mask (`dest` field in bits 21..24).
      # Bit 3 = X (`0b1000`), Bit 2 = Y (`0b0100`), Bit 1 = Z (`0b0010`), Bit 0 = W (`0b0001`).
      enum DestMask : UInt8
        None = 0x0_u8
        W    = 0x1_u8
        Z    = 0x2_u8
        ZW   = 0x3_u8
        Y    = 0x4_u8
        YW   = 0x5_u8
        YZ   = 0x6_u8
        YZW  = 0x7_u8
        X    = 0x8_u8
        XW   = 0x9_u8
        XZ   = 0xA_u8
        XZW  = 0xB_u8
        XY   = 0xC_u8
        XYW  = 0xD_u8
        XYZ  = 0xE_u8
        XYZW = 0xF_u8

        # Parses a destination mask from a string or symbol (e.g. `"xyzw"`, `:xyz`, `"x"`).
        def self.parse(spec : String | Symbol | DestMask | UInt8) : DestMask
          return spec if spec.is_a?(DestMask)
          return DestMask.from_value(spec & 0xF_u8) if spec.is_a?(UInt8)

          str = spec.to_s.downcase.lstrip('.')
          return DestMask::XYZW if str.empty?
          return DestMask::None if str == "none"

          mask = 0_u8
          str.each_char do |ch|
            case ch
            when 'x' then mask |= 0x8_u8
            when 'y' then mask |= 0x4_u8
            when 'z' then mask |= 0x2_u8
            when 'w' then mask |= 0x1_u8
            else
              raise ArgumentError.new("Invalid VU1 vector field mask character '#{ch}' in '#{spec}'")
            end
          end
          DestMask.from_value(mask)
        end

        def overlaps?(other : DestMask) : Bool
          (value & other.value) != 0_u8
        end

        def to_suffix : String
          return "none" if value == 0_u8
          io = String::Builder.new(4)
          io << 'x' if (value & 0x8_u8) != 0
          io << 'y' if (value & 0x4_u8) != 0
          io << 'z' if (value & 0x2_u8) != 0
          io << 'w' if (value & 0x1_u8) != 0
          io.to_s
        end
      end

      # 2-bit Vector Broadcast Lane (`bc` field in bits 0..1 or `fsf`/`ftf` in FDIV).
      enum Broadcast : UInt8
        X = 0_u8
        Y = 1_u8
        Z = 2_u8
        W = 3_u8

        def self.parse(spec : String | Symbol | Broadcast | UInt8) : Broadcast
          return spec if spec.is_a?(Broadcast)
          return Broadcast.from_value(spec & 0x3_u8) if spec.is_a?(UInt8)

          case spec.to_s.downcase.lstrip('.')
          when "x", "0" then Broadcast::X
          when "y", "1" then Broadcast::Y
          when "z", "2" then Broadcast::Z
          when "w", "3" then Broadcast::W
          else
            raise ArgumentError.new("Invalid VU1 broadcast lane '#{spec}' (expected x, y, z, or w)")
          end
        end
      end

      # 128-bit Vector Floating-Point Register (`VF00`..`VF31`).
      # `VF00` is hardware-hardwired to `(0.0, 0.0, 0.0, 1.0)`.
      struct VfReg
        getter index : UInt8

        def initialize(idx : Int)
          if idx < 0 || idx > 31
            raise ArgumentError.new("VU1 VF register index (#{idx}) out of bounds (expected 0..31)")
          end
          @index = idx.to_u8
        end

        def zero? : Bool
          @index == 0_u8
        end

        def to_s(io : IO) : Nil
          io << "vf"
          io << '0' if @index < 10
          io << @index
        end

        def self.parse(spec : VfReg | Int | String | Symbol) : VfReg
          return spec if spec.is_a?(VfReg)
          return VfReg.new(spec) if spec.is_a?(Int)

          cleaned = spec.to_s.strip.lstrip('$').downcase
          # Strip trailing component specifier if present (e.g. "vf01.xyzw" -> "vf01")
          if dot = cleaned.index('.')
            cleaned = cleaned[0...dot]
          end
          if cleaned.starts_with?("vf")
            if num = cleaned[2..].to_i?
              return VfReg.new(num)
            end
          elsif num = cleaned.to_i?
            return VfReg.new(num)
          end
          raise ArgumentError.new("Invalid VU1 VF register '#{spec}' (expected vf00..vf31)")
        end
      end

      # 16-bit Scalar Integer Register (`VI00`..`VI15`).
      # `VI00` is hardware-hardwired to `0`.
      struct ViReg
        getter index : UInt8

        def initialize(idx : Int)
          if idx < 0 || idx > 15
            raise ArgumentError.new("VU1 VI register index (#{idx}) out of bounds (expected 0..15)")
          end
          @index = idx.to_u8
        end

        def zero? : Bool
          @index == 0_u8
        end

        def to_s(io : IO) : Nil
          io << "vi"
          io << '0' if @index < 10
          io << @index
        end

        def self.parse(spec : ViReg | Int | String | Symbol) : ViReg
          return spec if spec.is_a?(ViReg)
          return ViReg.new(spec) if spec.is_a?(Int)

          cleaned = spec.to_s.strip.lstrip('$').downcase
          if cleaned.starts_with?("vi")
            if num = cleaned[2..].to_i?
              return ViReg.new(num)
            end
          elsif num = cleaned.to_i?
            return ViReg.new(num)
          end
          raise ArgumentError.new("Invalid VU1 VI register '#{spec}' (expected vi00..vi15)")
        end
      end

      # =========================================================================
      # Upper & Lower Instruction Opcodes & Encoders (Dual-Issue 64-Bit VLIW)
      # =========================================================================

      # Upper 32-bit Floating-Point ALU (FMAC) Opcodes.
      enum UpperOp : UInt8
        NOP
        ADD
        ADDI
        ADDQ
        ADDBC
        SUB
        SUBI
        SUBQ
        SUBBC
        MADD
        MADDI
        MADDQ
        MADDBC
        MSUB
        MSUBI
        MSUBQ
        MSUBBC
        MAX
        MAXI
        MAXBC
        MINI
        MINII
        MINIBC
        MUL
        MULI
        MULQ
        MULBC
        ADDA
        ADDAI
        ADDAQ
        ADDABC
        SUBA
        SUBAI
        SUBAQ
        SUBABC
        MADDA
        MADDAI
        MADDAQ
        MADDABC
        MSUBA
        MSUBAI
        MSUBAQ
        MSUBABC
        MULA
        MULAI
        MULAQ
        MULABC
        OPMULA
        OPMSUB
        ABS
        CLIP
        FTOI0
        FTOI4
        FTOI12
        FTOI15
        ITOF0
        ITOF4
        ITOF12
        ITOF15
      end

      # Lower 32-bit Load/Store, Integer ALU, FDIV/EFU, Branch & GS Kick Opcodes.
      enum LowerOp : UInt8
        NOP
        LQ
        SQ
        LQI
        SQI
        LQD
        SQD
        ILW
        ISW
        IADD
        ISUB
        IADDI
        IADDIU
        ISUBIU
        IAND
        IOR
        MOVE
        MR32
        MFIR
        MTIR
        DIV
        SQRT
        RSQRT
        WAITQ
        WAITP
        XGKICK
        XTOP
        XITOP
        B
        BAL
        JR
        JALR
        IBEQ
        IBNE
        IBLTZ
        IBGTZ
        IBLEZ
        IBGEZ
        LOI_DATA
      end

      # Represents a 32-bit Upper VU1 instruction (FMAC Vector ALU pipeline).
      struct UpperInstruction
        getter op : UpperOp
        getter dest : DestMask
        getter fd : UInt8
        getter fs : UInt8
        getter ft : UInt8
        getter bc : Broadcast
        getter? flag_i : Bool
        getter? flag_e : Bool
        getter? flag_m : Bool
        getter? flag_d : Bool
        getter? flag_t : Bool

        def initialize(
          @op : UpperOp = UpperOp::NOP,
          @dest : DestMask = DestMask::XYZW,
          @fd : UInt8 = 0_u8,
          @fs : UInt8 = 0_u8,
          @ft : UInt8 = 0_u8,
          @bc : Broadcast = Broadcast::X,
          @flag_i : Bool = false,
          @flag_e : Bool = false,
          @flag_m : Bool = false,
          @flag_d : Bool = false,
          @flag_t : Bool = false,
        )
        end

        def self.nop(
          flag_i : Bool = false,
          flag_e : Bool = false,
          flag_m : Bool = false,
          flag_d : Bool = false,
          flag_t : Bool = false,
        ) : UpperInstruction
          UpperInstruction.new(
            op: UpperOp::NOP,
            dest: DestMask::None,
            flag_i: flag_i,
            flag_e: flag_e,
            flag_m: flag_m,
            flag_d: flag_d,
            flag_t: flag_t
          )
        end

        def nop? : Bool
          @op.nop?
        end

        # Returns true if this Upper instruction writes to a general-purpose VF register (`vf01..vf31`).
        def writes_vf? : Bool
          return false if @dest.none? || @fd == 0_u8
          case @op
          when .nop?, .adda?, .addai?, .addaq?, .addabc?,
               .suba?, .subai?, .subaq?, .subabc?,
               .madda?, .maddai?, .maddaq?, .maddabc?,
               .msuba?, .msubai?, .msubaq?, .msubabc?,
               .mula?, .mulai?, .mulaq?, .mulabc?,
               .opmula?, .clip?
            false
          else
            true
          end
        end

        # Returns true if this Upper instruction reads from `VF[fs]`.
        def reads_fs? : Bool
          !@op.nop? && @fs != 0_u8
        end

        # Returns true if this Upper instruction reads from `VF[ft]`.
        def reads_ft? : Bool
          return false if @ft == 0_u8
          case @op
          when .add?, .addbc?, .sub?, .subbc?, .madd?, .maddbc?,
               .msub?, .msubbc?, .max?, .maxbc?, .mini?, .minibc?,
               .mul?, .mulbc?, .adda?, .addabc?, .suba?, .subabc?,
               .madda?, .maddabc?, .msuba?, .msubabc?, .mula?, .mulabc?,
               .opmula?, .opmsub?, .clip?
            true
          else
            false
          end
        end

        # Returns true if this Upper instruction reads the `Q` register (FDIV result).
        def reads_q? : Bool
          case @op
          when .addq?, .subq?, .maddq?, .msubq?, .mulq?, .addaq?, .subaq?, .maddaq?, .msubaq?, .mulaq?
            true
          else
            false
          end
        end

        # Encodes the Upper instruction into its 32-bit machine word.
        def encode : UInt32
          mode_bits = 0_u32
          mode_bits |= (1_u32 << 31) if @flag_i
          mode_bits |= (1_u32 << 30) if @flag_e
          mode_bits |= (1_u32 << 29) if @flag_m
          mode_bits |= (1_u32 << 28) if @flag_d
          mode_bits |= (1_u32 << 27) if @flag_t

          if @op.nop?
            return mode_bits | UPPER_NOP_WORD
          end

          dest_bits = (@dest.value.to_u32 & 0xF_u32) << 21
          ft_bits = (@ft.to_u32 & 0x1F_u32) << 16
          fs_bits = (@fs.to_u32 & 0x1F_u32) << 11
          fd_bits = (@fd.to_u32 & 0x1F_u32) << 6
          bc_bits = @bc.value.to_u32 & 0x3_u32

          body = case @op
                 when .add?     then dest_bits | ft_bits | fs_bits | fd_bits | 0x28_u32
                 when .addi?    then dest_bits | fs_bits | fd_bits | 0x22_u32
                 when .addq?    then dest_bits | fs_bits | fd_bits | 0x20_u32
                 when .addbc?   then dest_bits | ft_bits | fs_bits | fd_bits | (0x00_u32 | bc_bits)
                 when .sub?     then dest_bits | ft_bits | fs_bits | fd_bits | 0x2C_u32
                 when .subi?    then dest_bits | fs_bits | fd_bits | 0x26_u32
                 when .subq?    then dest_bits | fs_bits | fd_bits | 0x24_u32
                 when .subbc?   then dest_bits | ft_bits | fs_bits | fd_bits | (0x04_u32 | bc_bits)
                 when .madd?    then dest_bits | ft_bits | fs_bits | fd_bits | 0x29_u32
                 when .maddi?   then dest_bits | fs_bits | fd_bits | 0x23_u32
                 when .maddq?   then dest_bits | fs_bits | fd_bits | 0x21_u32
                 when .maddbc?  then dest_bits | ft_bits | fs_bits | fd_bits | (0x08_u32 | bc_bits)
                 when .msub?    then dest_bits | ft_bits | fs_bits | fd_bits | 0x2D_u32
                 when .msubi?   then dest_bits | fs_bits | fd_bits | 0x27_u32
                 when .msubq?   then dest_bits | fs_bits | fd_bits | 0x25_u32
                 when .msubbc?  then dest_bits | ft_bits | fs_bits | fd_bits | (0x0C_u32 | bc_bits)
                 when .max?     then dest_bits | ft_bits | fs_bits | fd_bits | 0x2B_u32
                 when .maxi?    then dest_bits | fs_bits | fd_bits | 0x1D_u32
                 when .maxbc?   then dest_bits | ft_bits | fs_bits | fd_bits | (0x10_u32 | bc_bits)
                 when .mini?    then dest_bits | ft_bits | fs_bits | fd_bits | 0x2F_u32
                 when .minii?   then dest_bits | fs_bits | fd_bits | 0x1F_u32
                 when .minibc?  then dest_bits | ft_bits | fs_bits | fd_bits | (0x14_u32 | bc_bits)
                 when .mul?     then dest_bits | ft_bits | fs_bits | fd_bits | 0x2A_u32
                 when .muli?    then dest_bits | fs_bits | fd_bits | 0x1E_u32
                 when .mulq?    then dest_bits | fs_bits | fd_bits | 0x1C_u32
                 when .mulbc?   then dest_bits | ft_bits | fs_bits | fd_bits | (0x18_u32 | bc_bits)
                 when .opmsub?  then dest_bits | ft_bits | fs_bits | fd_bits | 0x2E_u32
                 when .adda?    then dest_bits | ft_bits | fs_bits | 0x2BC_u32
                 when .addai?   then dest_bits | fs_bits | 0x23E_u32
                 when .addaq?   then dest_bits | fs_bits | 0x23C_u32
                 when .addabc?  then dest_bits | ft_bits | fs_bits | (0x03C_u32 | bc_bits)
                 when .suba?    then dest_bits | ft_bits | fs_bits | 0x2FC_u32
                 when .subai?   then dest_bits | fs_bits | 0x27E_u32
                 when .subaq?   then dest_bits | fs_bits | 0x27C_u32
                 when .subabc?  then dest_bits | ft_bits | fs_bits | (0x07C_u32 | bc_bits)
                 when .madda?   then dest_bits | ft_bits | fs_bits | 0x2BD_u32
                 when .maddai?  then dest_bits | fs_bits | 0x23F_u32
                 when .maddaq?  then dest_bits | fs_bits | 0x23D_u32
                 when .maddabc? then dest_bits | ft_bits | fs_bits | (0x0BC_u32 | bc_bits)
                 when .msuba?   then dest_bits | ft_bits | fs_bits | 0x2FD_u32
                 when .msubai?  then dest_bits | fs_bits | 0x27F_u32
                 when .msubaq?  then dest_bits | fs_bits | 0x27D_u32
                 when .msubabc? then dest_bits | ft_bits | fs_bits | (0x0FC_u32 | bc_bits)
                 when .mula?    then dest_bits | ft_bits | fs_bits | 0x2BE_u32
                 when .mulai?   then dest_bits | fs_bits | 0x1FE_u32
                 when .mulaq?   then dest_bits | fs_bits | 0x1FC_u32
                 when .mulabc?  then dest_bits | ft_bits | fs_bits | (0x1BC_u32 | bc_bits)
                 when .opmula?  then dest_bits | ft_bits | fs_bits | 0x2FE_u32
                 when .abs?     then dest_bits | ft_bits | fs_bits | 0x1FD_u32
                 when .clip?    then (DestMask::XYZ.value.to_u32 << 21) | ft_bits | fs_bits | 0x1FF_u32
                 when .ftoi0?   then dest_bits | ft_bits | fs_bits | 0x13D_u32
                 when .ftoi4?   then dest_bits | ft_bits | fs_bits | 0x17D_u32
                 when .ftoi12?  then dest_bits | ft_bits | fs_bits | 0x1BD_u32
                 when .ftoi15?  then dest_bits | ft_bits | fs_bits | 0x1FD_u32
                 when .itof0?   then dest_bits | ft_bits | fs_bits | 0x13C_u32
                 when .itof4?   then dest_bits | ft_bits | fs_bits | 0x17C_u32
                 when .itof12?  then dest_bits | ft_bits | fs_bits | 0x1BC_u32
                 when .itof15?  then dest_bits | ft_bits | fs_bits | 0x1FC_u32
                 else
                   UPPER_NOP_WORD
                 end

          mode_bits | body
        end
      end

      # Represents a 32-bit Lower VU1 instruction (Load/Store, Integer ALU, FDIV, Branch, XGKICK, or LOI float).
      struct LowerInstruction
        getter op : LowerOp
        getter dest : DestMask
        getter ft : UInt8
        getter fs : UInt8
        getter id : UInt8
        getter is : UInt8
        getter it : UInt8
        getter fsf : Broadcast
        getter ftf : Broadcast
        getter imm : Int32
        getter raw_word : UInt32
        getter target_label : String?

        def initialize(
          @op : LowerOp = LowerOp::NOP,
          @dest : DestMask = DestMask::XYZW,
          @ft : UInt8 = 0_u8,
          @fs : UInt8 = 0_u8,
          @id : UInt8 = 0_u8,
          @is : UInt8 = 0_u8,
          @it : UInt8 = 0_u8,
          @fsf : Broadcast = Broadcast::X,
          @ftf : Broadcast = Broadcast::X,
          @imm : Int32 = 0,
          @raw_word : UInt32 = LOWER_NOP_WORD,
          @target_label : String? = nil,
        )
        end

        def self.nop : LowerInstruction
          LowerInstruction.new(op: LowerOp::NOP, dest: DestMask::None, raw_word: LOWER_NOP_WORD)
        end

        def self.loi(val : Float32) : LowerInstruction
          LowerInstruction.new(
            op: LowerOp::LOI_DATA,
            dest: DestMask::None,
            raw_word: val.unsafe_as(UInt32)
          )
        end

        def nop? : Bool
          @op.nop?
        end

        # Returns true if this Lower instruction writes to a VF register (`LQ`, `LQI`, `LQD`, `MOVE`, `MR32`, `MFIR`).
        def writes_vf? : Bool
          return false if @dest.none? || @ft == 0_u8
          case @op
          when .lq?, .lqi?, .lqd?, .move?, .mr32?, .mfir?
            true
          else
            false
          end
        end

        # Returns the destination VF register index if `writes_vf?` is true.
        def vf_dest : UInt8
          @ft
        end

        # Returns true if this Lower instruction reads from `VF[fs]` (`SQ`, `SQI`, `SQD`, `MOVE`, `MR32`, `MTIR`, `DIV`, `RSQRT`).
        def reads_vf_fs? : Bool
          return false if @fs == 0_u8
          case @op
          when .sq?, .sqi?, .sqd?, .move?, .mr32?, .mtir?, .div?, .rsqrt?
            true
          else
            false
          end
        end

        # Returns true if this Lower instruction reads from `VF[ft]` (`DIV`, `SQRT`, `RSQRT`).
        def reads_vf_ft? : Bool
          return false if @ft == 0_u8
          case @op
          when .div?, .sqrt?, .rsqrt?
            true
          else
            false
          end
        end

        # Returns the destination VI register index if this Lower instruction writes a VI register (`1..15`), or `0_u8` if none.
        def vi_dest : UInt8
          case @op
          when .iadd?, .isub?, .iand?, .ior?
            @id
          when .iaddi?, .iaddiu?, .isubiu?, .ilw?, .mtir?, .bal?, .jalr?, .xtop?, .xitop?
            @it
          else
            0_u8
          end
        end

        # Returns true if this instruction is a branch or jump (`B`, `BAL`, `JR`, `JALR`, `IBEQ`, `IBNE`, `IBLTZ`, `IBGTZ`, `IBLEZ`, `IBGEZ`).
        def branch? : Bool
          case @op
          when .b?, .bal?, .jr?, .jalr?, .ibeq?, .ibne?, .ibltz?, .ibgtz?, .iblez?, .ibgez?
            true
          else
            false
          end
        end

        # Returns true if this branch reads `VI[is]`.
        def branch_reads_is? : Bool
          return false if @is == 0_u8
          case @op
          when .jr?, .jalr?, .ibeq?, .ibne?, .ibltz?, .ibgtz?, .iblez?, .ibgez?
            true
          else
            false
          end
        end

        # Returns true if this branch reads `VI[it]`.
        def branch_reads_it? : Bool
          return false if @it == 0_u8
          case @op
          when .ibeq?, .ibne?
            true
          else
            false
          end
        end

        # Returns a copy of this instruction with a resolved relative branch offset `imm`.
        def with_imm(new_imm : Int32) : LowerInstruction
          LowerInstruction.new(
            op: @op,
            dest: @dest,
            ft: @ft,
            fs: @fs,
            id: @id,
            is: @is,
            it: @it,
            fsf: @fsf,
            ftf: @ftf,
            imm: new_imm,
            raw_word: @raw_word,
            target_label: nil
          )
        end

        # Encodes the Lower instruction into its 32-bit machine word.
        def encode : UInt32
          return @raw_word if @op.nop? || @op.loi_data?

          dest_bits = (@dest.value.to_u32 & 0xF_u32) << 21
          ft_bits = (@ft.to_u32 & 0x1F_u32) << 16
          fs_bits = (@fs.to_u32 & 0x1F_u32) << 11
          it_bits = (@it.to_u32 & 0x1F_u32) << 16
          is_bits = (@is.to_u32 & 0x1F_u32) << 11
          id_bits = (@id.to_u32 & 0x1F_u32) << 6
          imm11 = (@imm & 0x7FF).to_u32
          imm5 = (@imm & 0x1F).to_u32
          imm15_hi = ((@imm >> 11) & 0xF).to_u32 << 21
          imm15_lo = (@imm & 0x7FF).to_u32
          fsf_bits = (@fsf.value.to_u32 & 0x3_u32) << 21
          ftf_bits = (@ftf.value.to_u32 & 0x3_u32) << 23

          case @op
          when .lq?     then (0x00_u32 << 25) | dest_bits | ft_bits | is_bits | imm11
          when .sq?     then (0x01_u32 << 25) | dest_bits | it_bits | fs_bits | imm11
          when .ilw?    then (0x04_u32 << 25) | dest_bits | it_bits | is_bits | imm11
          when .isw?    then (0x05_u32 << 25) | dest_bits | it_bits | is_bits | imm11
          when .iaddiu? then (0x08_u32 << 25) | imm15_hi | it_bits | is_bits | imm15_lo
          when .isubiu? then (0x09_u32 << 25) | imm15_hi | it_bits | is_bits | imm15_lo
          when .b?      then (0x20_u32 << 25) | imm11
          when .bal?    then (0x21_u32 << 25) | it_bits | imm11
          when .jr?     then (0x24_u32 << 25) | is_bits
          when .jalr?   then (0x25_u32 << 25) | it_bits | is_bits
          when .ibeq?   then (0x28_u32 << 25) | it_bits | is_bits | imm11
          when .ibne?   then (0x29_u32 << 25) | it_bits | is_bits | imm11
          when .ibltz?  then (0x2C_u32 << 25) | is_bits | imm11
          when .ibgtz?  then (0x2D_u32 << 25) | is_bits | imm11
          when .iblez?  then (0x2E_u32 << 25) | is_bits | imm11
          when .ibgez?  then (0x2F_u32 << 25) | is_bits | imm11
          when .iadd?   then 0x80000030_u32 | it_bits | is_bits | id_bits
          when .isub?   then 0x80000031_u32 | it_bits | is_bits | id_bits
          when .iaddi?  then 0x80000032_u32 | it_bits | is_bits | (imm5 << 6)
          when .iand?   then 0x80000034_u32 | it_bits | is_bits | id_bits
          when .ior?    then 0x80000035_u32 | it_bits | is_bits | id_bits
          when .move?   then 0x8000033C_u32 | dest_bits | ft_bits | fs_bits
          when .mr32?   then 0x8000033D_u32 | dest_bits | ft_bits | fs_bits
          when .lqi?    then 0x8000037C_u32 | dest_bits | is_bits | (@ft.to_u32 << 11)
          when .sqi?    then 0x800003FC_u32 | dest_bits | it_bits | fs_bits
          when .lqd?    then 0x8000037E_u32 | dest_bits | is_bits | (@ft.to_u32 << 11)
          when .sqd?    then 0x800003FE_u32 | dest_bits | it_bits | fs_bits
          when .div?    then 0x800003BC_u32 | ftf_bits | fsf_bits | ft_bits | fs_bits
          when .sqrt?   then 0x800003BD_u32 | ftf_bits | ft_bits
          when .rsqrt?  then 0x800003BE_u32 | ftf_bits | fsf_bits | ft_bits | fs_bits
          when .waitq?  then 0x800003BF_u32
          when .waitp?  then 0x800007BF_u32
          when .mfir?   then 0x800003FD_u32 | dest_bits | ft_bits | is_bits
          when .mtir?   then 0x800003FF_u32 | fsf_bits | it_bits | fs_bits
          when .xtop?   then 0x800006BC_u32 | it_bits
          when .xitop?  then 0x800006BD_u32 | it_bits
          when .xgkick? then 0x800006FC_u32 | is_bits
          else
            LOWER_NOP_WORD
          end
        end
      end

      # Represents a single 64-bit Dual-Issue VLIW VU1 Microinstruction (`Upper` in bits 32..63, `Lower` in bits 0..31).
      struct MicroInstruction
        getter upper : UpperInstruction
        getter lower : LowerInstruction
        getter pc : Int32

        def initialize(
          @upper : UpperInstruction = UpperInstruction.nop,
          @lower : LowerInstruction = LowerInstruction.nop,
          @pc : Int32 = 0,
        )
        end

        def self.nop(pc : Int32 = 0, flag_e : Bool = false) : MicroInstruction
          MicroInstruction.new(
            upper: UpperInstruction.nop(flag_e: flag_e),
            lower: LowerInstruction.nop,
            pc: pc
          )
        end

        # Encodes the 64-bit VLIW instruction word (`(upper.encode << 32) | lower.encode`).
        def encode : UInt64
          (upper.encode.to_u64 << 32) | lower.encode.to_u64
        end

        # Writes this 64-bit instruction to `io` in PlayStation 2 little-endian format (`lower` 32-bit LE, then `upper` 32-bit LE).
        def write_to(io : IO) : Nil
          io.write_bytes(encode, IO::ByteFormat::LittleEndian)
        end
      end

      # =========================================================================
      # Compile-Time & Assembly-Time Register Hazard Detector
      # =========================================================================

      enum HazardSeverity : UInt8
        Warning # Hardware interlocks or stalls pipeline (e.g. FMAC RAW 1..3 cycle stall)
        Error   # Undefined hardware behavior or wrong register value (Same-cycle VF write, VI->Branch in +1 cycle, unwaited Q read)
      end

      enum HazardKind : UInt8
        SameCycleVfWrite      # Both Upper and Lower write overlapping fields of the same VF register in the same cycle
        LoiLowerConflict      # Upper has LOI (I-bit) set while Lower is not LOI_DATA / NOP
        ViBranchHazard        # VI register modified in cycle N-1 is read by branch in cycle N (hardware reads old VI value!)
        BranchDelaySlotHazard # Branch instruction placed inside the delay slot of another branch or E-bit
        QRegisterHazard       # Upper instruction reads Q within DIV/SQRT (7 cycles) or RSQRT (13 cycles) window without WAITQ
        FmacRawHazard         # VF component read within 1..3 cycles after Upper FMAC write (causes hardware interlock stall)
        ViLoadRawHazard       # VI register read within 1..3 cycles after ILW load
        XgkickStallHazard     # Back-to-back XGKICK instructions within < 4 cycles
      end

      # Describes a detected register or pipeline hazard at a specific instruction PC.
      struct Hazard
        getter kind : HazardKind
        getter severity : HazardSeverity
        getter pc : Int32
        getter producer_pc : Int32
        getter stall_cycles : Int32
        getter register_name : String
        getter message : String

        def initialize(
          @kind : HazardKind,
          @severity : HazardSeverity,
          @pc : Int32,
          @producer_pc : Int32,
          @stall_cycles : Int32,
          @register_name : String,
          @message : String,
        )
        end

        def error? : Bool
          @severity.error?
        end

        def warning? : Bool
          @severity.warning?
        end
      end

      # Raised when strict hazard checking detects a critical register conflict or hardware hazard.
      class HazardError < Exception
        getter hazards : Array(Hazard)

        def initialize(@hazards : Array(Hazard))
          msg = String.build do |io|
            io << "VU1 Microcode Hazard Detector found #{@hazards.size} hazard(s):\n"
            @hazards.each do |h|
              io << "  - [PC #{h.pc}] (#{h.kind}): #{h.message}\n"
            end
          end
          super(msg.rstrip)
        end
      end

      # Summary report of cycle count, stall cycles, and hazards across a VU1 microprogram.
      struct HazardReport
        getter instruction_count : Int32
        getter base_cycles : Int32
        getter stall_cycles : Int32
        getter total_estimated_cycles : Int32
        getter hazards : Array(Hazard)

        def initialize(
          @instruction_count : Int32,
          @base_cycles : Int32,
          @stall_cycles : Int32,
          @hazards : Array(Hazard),
        )
          @total_estimated_cycles = @base_cycles + @stall_cycles
        end

        def clean? : Bool
          @hazards.empty?
        end

        def has_errors? : Bool
          @hazards.any?(&.error?)
        end

        def errors : Array(Hazard)
          @hazards.select(&.error?)
        end

        def warnings : Array(Hazard)
          @hazards.select(&.warning?)
        end
      end

      # Analyzes a sequence of 64-bit dual-issue `MicroInstruction`s for PS2 VU1 register and pipeline hazards.
      module HazardDetector
        FMAC_LATENCY  =  4
        DIV_LATENCY   =  7
        RSQRT_LATENCY = 13
        ILW_LATENCY   =  4

        # Validates a single dual-issue instruction pair for same-cycle structural/register hazards.
        def self.check_pair(upper : UpperInstruction, lower : LowerInstruction, pc : Int32 = 0) : Array(Hazard)
          hazards = [] of Hazard

          # 1. LOI + active Lower instruction conflict
          if upper.flag_i? && !lower.op.loi_data? && !lower.nop?
            hazards << Hazard.new(
              kind: HazardKind::LoiLowerConflict,
              severity: HazardSeverity::Error,
              pc: pc,
              producer_pc: pc,
              stall_cycles: 0,
              register_name: "I",
              message: "Upper instruction sets LOI (I-bit) while Lower slot contains #{lower.op} (32-bit Lower slot is occupied by float immediate)"
            )
          end

          # 2. Same-cycle VF write-after-write hazard (Upper & Lower writing overlapping components of same VF register)
          if upper.writes_vf? && lower.writes_vf? && upper.fd == lower.vf_dest
            if upper.dest.overlaps?(lower.dest)
              reg_str = "vf#{upper.fd.to_s.rjust(2, '0')}.#{(upper.dest.value & lower.dest.value).try { |m| DestMask.from_value(m).to_suffix }}"
              hazards << Hazard.new(
                kind: HazardKind::SameCycleVfWrite,
                severity: HazardSeverity::Error,
                pc: pc,
                producer_pc: pc,
                stall_cycles: 0,
                register_name: reg_str,
                message: "Dual-issue write conflict on #{reg_str}: both Upper (#{upper.op}) and Lower (#{lower.op}) write overlapping components in the same cycle"
              )
            end
          end

          hazards
        end

        # Performs a full pipeline & register hazard analysis across a sequence of `MicroInstruction`s.
        def self.analyze(instructions : Array(MicroInstruction)) : HazardReport
          hazards = [] of Hazard
          total_stalls = 0

          # Track recent FDIV/SQRT/RSQRT producer: {pc, latency}
          pending_q : Tuple(Int32, Int32)? = nil
          last_xgkick_pc : Int32? = nil

          instructions.each_with_index do |inst, pc|
            u = inst.upper
            l = inst.lower

            # 1. Same-cycle dual-issue checks
            pair_hazards = check_pair(u, l, pc)
            hazards.concat(pair_hazards)

            # 2. Branch delay slot hazard (branch at pc when pc - 1 was also a branch or had E-bit)
            if pc > 0
              prev = instructions[pc - 1]
              if l.branch? && (prev.lower.branch? || prev.upper.flag_e?)
                hazards << Hazard.new(
                  kind: HazardKind::BranchDelaySlotHazard,
                  severity: HazardSeverity::Error,
                  pc: pc,
                  producer_pc: pc - 1,
                  stall_cycles: 0,
                  register_name: "PC",
                  message: "Branch instruction #{l.op} at PC #{pc} is inside the delay slot of PC #{pc - 1}"
                )
              end
            end

            # 3. Critical PS2 VU1 VI -> Branch 1-cycle hazard (no hardware bypass from VI write in PC-1 to Branch in PC)
            if l.branch? && pc > 0
              prev_l = instructions[pc - 1].lower
              written_vi = prev_l.vi_dest
              if written_vi != 0_u8
                conflict = (l.branch_reads_is? && l.is == written_vi) || (l.branch_reads_it? && l.it == written_vi)
                if conflict
                  reg_str = "vi#{written_vi.to_s.rjust(2, '0')}"
                  hazards << Hazard.new(
                    kind: HazardKind::ViBranchHazard,
                    severity: HazardSeverity::Error,
                    pc: pc,
                    producer_pc: pc - 1,
                    stall_cycles: 1,
                    register_name: reg_str,
                    message: "VI branch hazard on #{reg_str}: written by #{prev_l.op} at PC #{pc - 1} and read by #{l.op} at PC #{pc} without 1-cycle NOP separation"
                  )
                end
              end
            end

            # 4. ILW Load -> VI read stall (4-cycle latency)
            (1...ILW_LATENCY).each do |delta|
              break if pc - delta < 0
              prod_l = instructions[pc - delta].lower
              if prod_l.op.ilw? && prod_l.vi_dest != 0_u8
                vi_reg = prod_l.vi_dest
                reads_vi = (l.is == vi_reg && !l.nop?) || (l.it == vi_reg && (l.op.iadd? || l.op.isub? || l.op.iand? || l.op.ior? || l.op.ibeq? || l.op.ibne?))
                if reads_vi
                  stall = ILW_LATENCY - delta
                  total_stalls += stall
                  reg_str = "vi#{vi_reg.to_s.rjust(2, '0')}"
                  hazards << Hazard.new(
                    kind: HazardKind::ViLoadRawHazard,
                    severity: HazardSeverity::Warning,
                    pc: pc,
                    producer_pc: pc - delta,
                    stall_cycles: stall,
                    register_name: reg_str,
                    message: "ILW load latency stall (#{stall} cycle(s)) on #{reg_str} written at PC #{pc - delta}"
                  )
                end
              end
            end

            # 5. FMAC 4-cycle RAW pipeline stall check
            (1...FMAC_LATENCY).each do |delta|
              break if pc - delta < 0
              prod_u = instructions[pc - delta].upper
              next unless prod_u.writes_vf?

              prod_vf = prod_u.fd
              prod_mask = prod_u.dest

              reads_in_u = (u.reads_fs? && u.fs == prod_vf) || (u.reads_ft? && u.ft == prod_vf)
              reads_in_l = (l.reads_vf_fs? && l.fs == prod_vf && l.dest.overlaps?(prod_mask)) ||
                           (l.reads_vf_ft? && l.ft == prod_vf)

              if reads_in_u || reads_in_l
                stall = FMAC_LATENCY - delta
                total_stalls += stall
                reg_str = "vf#{prod_vf.to_s.rjust(2, '0')}.#{prod_mask.to_suffix}"
                hazards << Hazard.new(
                  kind: HazardKind::FmacRawHazard,
                  severity: HazardSeverity::Warning,
                  pc: pc,
                  producer_pc: pc - delta,
                  stall_cycles: stall,
                  register_name: reg_str,
                  message: "FMAC RAW interlock stall (#{stall} cycle(s)) on #{reg_str} produced by #{prod_u.op} at PC #{pc - delta}"
                )
                break
              end
            end

            # 6. FDIV / SQRT / RSQRT Q-register latency check
            if l.op.waitq?
              if pq = pending_q
                elapsed = pc - pq[0]
                if elapsed < pq[1]
                  total_stalls += (pq[1] - elapsed)
                end
                pending_q = nil
              end
            end

            if u.reads_q?
              if pq = pending_q
                elapsed = pc - pq[0]
                if elapsed < pq[1]
                  rem = pq[1] - elapsed
                  hazards << Hazard.new(
                    kind: HazardKind::QRegisterHazard,
                    severity: HazardSeverity::Error,
                    pc: pc,
                    producer_pc: pq[0],
                    stall_cycles: rem,
                    register_name: "Q",
                    message: "Upper #{u.op} reads Q register #{elapsed} cycle(s) after FDIV at PC #{pq[0]} (requires #{pq[1]} cycles or WAITQ; #{rem} cycle(s) early)"
                  )
                else
                  pending_q = nil
                end
              end
            end

            case l.op
            when .div?, .sqrt?
              pending_q = {pc, DIV_LATENCY}
            when .rsqrt?
              pending_q = {pc, RSQRT_LATENCY}
            else
              # no FDIV started
            end

            # 7. Back-to-back XGKICK stall check
            if l.op.xgkick?
              if prev_kick = last_xgkick_pc
                if (pc - prev_kick) < 4
                  stall = 4 - (pc - prev_kick)
                  total_stalls += stall
                  hazards << Hazard.new(
                    kind: HazardKind::XgkickStallHazard,
                    severity: HazardSeverity::Warning,
                    pc: pc,
                    producer_pc: prev_kick,
                    stall_cycles: stall,
                    register_name: "GIF_PATH1",
                    message: "Back-to-back XGKICK at PC #{pc} within #{pc - prev_kick} cycle(s) of PC #{prev_kick} stalls VU1 on GIF Path 1"
                  )
                end
              end
              last_xgkick_pc = pc
            end
          end

          HazardReport.new(
            instruction_count: instructions.size,
            base_cycles: instructions.size,
            stall_cycles: total_stalls,
            hazards: hazards
          )
        end
      end

      # =========================================================================
      # Compile-Time Macro Hazard Verification
      # =========================================================================

      # Compile-time macro that verifies a dual-issue `(upper, lower)` instruction pair
      # has no same-cycle VF register write conflict (`{% raise %}` at Crystal compile time if violated)
      # and returns the `MicroInstruction`.
      macro static_dual_issue(
        upper_op, upper_dest, fd, fs, ft,
        lower_op, lower_dest, l_ft, l_fs, l_is = 0, l_imm = 0,
      )
        {% begin %}
          {% u_op_str = upper_op.id.stringify.upcase %}
          {% l_op_str = lower_op.id.stringify.upcase %}
          {% u_writes = !["NOP", "ADDA", "ADDAI", "ADDAQ", "ADDABC", "SUBA", "SUBAI", "SUBAQ", "SUBABC", "MADDA", "MADDAI", "MADDAQ", "MADDABC", "MSUBA", "MSUBAI", "MSUBAQ", "MSUBABC", "MULA", "MULAI", "MULAQ", "MULABC", "OPMULA", "CLIP"].includes?(u_op_str) %}
          {% l_writes = ["LQ", "LQI", "LQD", "MOVE", "MR32", "MFIR"].includes?(l_op_str) %}
          {% if u_writes && l_writes && fd == l_ft && fd != 0 %}
            {% u_mask_str = upper_dest.id.stringify.downcase %}
            {% l_mask_str = lower_dest.id.stringify.downcase %}
            {% overlap = (u_mask_str.includes?("x") && l_mask_str.includes?("x")) ||
                         (u_mask_str.includes?("y") && l_mask_str.includes?("y")) ||
                         (u_mask_str.includes?("z") && l_mask_str.includes?("z")) ||
                         (u_mask_str.includes?("w") && l_mask_str.includes?("w")) %}
            {% if overlap %}
              {% raise "Citrine::Core::VU1 Compile-Time Hazard: Dual-issue VF write conflict on vf#{fd} between Upper #{u_op_str}.#{u_mask_str} and Lower #{l_op_str}.#{l_mask_str}" %}
            {% end %}
          {% end %}
        {% end %}
        Citrine::Core::VU1::MicroInstruction.new(
          upper: Citrine::Core::VU1::UpperInstruction.new(
            op: Citrine::Core::VU1::UpperOp::{{upper_op.id}},
            dest: Citrine::Core::VU1::DestMask.parse({{upper_dest}}),
            fd: ({{fd}}).to_u8,
            fs: ({{fs}}).to_u8,
            ft: ({{ft}}).to_u8
          ),
          lower: Citrine::Core::VU1::LowerInstruction.new(
            op: Citrine::Core::VU1::LowerOp::{{lower_op.id}},
            dest: Citrine::Core::VU1::DestMask.parse({{lower_dest}}),
            ft: ({{l_ft}}).to_u8,
            fs: ({{l_fs}}).to_u8,
            is: ({{l_is}}).to_u8,
            imm: ({{l_imm}}).to_i32
          )
        )
      end

      # =========================================================================
      # VIF1 Command & Packet Packer (`MPG`, `UNPACK`, `MSCAL`, `FLUSH`)
      # =========================================================================

      # VIF1 Command Opcodes (`CMD` field in bits 24..30 of 32-bit `VIFcode`).
      enum VifCmd : UInt8
        NOP      = 0x00_u8
        STCYCL   = 0x01_u8
        OFFSET   = 0x02_u8
        BASE     = 0x03_u8
        ITOP     = 0x04_u8
        STMOD    = 0x05_u8
        MSKPATH3 = 0x06_u8
        MARK     = 0x07_u8
        FLUSHE   = 0x10_u8
        FLUSH    = 0x11_u8
        FLUSHA   = 0x13_u8
        MSCAL    = 0x14_u8
        MSCALF   = 0x15_u8
        MSCNT    = 0x17_u8
        STMASK   = 0x20_u8
        STROW    = 0x30_u8
        STCOL    = 0x31_u8
        MPG      = 0x4A_u8
        DIRECT   = 0x50_u8
        DIRECTHL = 0x51_u8
      end

      # VIF1 `UNPACK` Decompression Formats (`(vn << 2) | vl` in lower 4 bits of `CMD = 0x60 | fmt`).
      enum UnpackFormat : UInt8
        S_32  = 0x00_u8 # 1x32-bit scalar replicated across xyzw (4 bytes per destination qword)
        S_16  = 0x01_u8 # 1x16-bit scalar (2 bytes per destination qword)
        S_8   = 0x02_u8 # 1x8-bit scalar (1 byte per destination qword)
        V2_32 = 0x04_u8 # 2x32-bit vector xy (8 bytes per destination qword)
        V2_16 = 0x05_u8 # 2x16-bit vector xy (4 bytes per destination qword)
        V2_8  = 0x06_u8 # 2x8-bit vector xy (2 bytes per destination qword)
        V3_32 = 0x08_u8 # 3x32-bit vector xyz (12 bytes per destination qword)
        V3_16 = 0x09_u8 # 3x16-bit vector xyz (6 bytes per destination qword)
        V3_8  = 0x0A_u8 # 3x8-bit vector xyz (3 bytes per destination qword)
        V4_32 = 0x0C_u8 # 4x32-bit quadword xyzw (16 bytes per destination qword)
        V4_16 = 0x0D_u8 # 4x16-bit vector xyzw (8 bytes per destination qword)
        V4_8  = 0x0E_u8 # 4x8-bit RGBA/vector xyzw (4 bytes per destination qword)
        V4_5  = 0x0F_u8 # 16-bit packed 5-5-5-1 RGBA (2 bytes per destination qword)

        # Number of source bytes required per destination VU1 128-bit quadword (assuming `CL <= WL`).
        def bytes_per_qword : Int32
          vn = ((value >> 2) & 0x3_u8).to_i + 1
          vl = (value & 0x3_u8).to_i
          if value == 0x0F_u8 # V4_5
            2
          else
            elem_bytes = 4 >> vl
            vn * elem_bytes
          end
        end
      end

      # 32-bit PlayStation 2 `VIFcode` command header:
      # - Bits 0..15: `IMMEDIATE`
      # - Bits 16..23: `NUM`
      # - Bits 24..30: `CMD`
      # - Bit 31: `IRQ`
      struct VifCode
        getter cmd : UInt8
        getter num : UInt8
        getter imm : UInt16
        getter? irq : Bool

        def initialize(@cmd : UInt8, @num : UInt8 = 0_u8, @imm : UInt16 = 0_u16, @irq : Bool = false)
        end

        def encode : UInt32
          val = @imm.to_u32
          val |= (@num.to_u32 << 16)
          val |= ((@cmd.to_u32 & 0x7F_u32) << 24)
          val |= (1_u32 << 31) if @irq
          val
        end

        def self.nop(irq : Bool = false) : VifCode
          VifCode.new(VifCmd::NOP.value, 0_u8, 0_u16, irq)
        end

        def self.stcycl(cl : UInt8 = 1_u8, wl : UInt8 = 1_u8, irq : Bool = false) : VifCode
          imm = ((wl.to_u16 & 0xFF_u16) << 8) | (cl.to_u16 & 0xFF_u16)
          VifCode.new(VifCmd::STCYCL.value, 0_u8, imm, irq)
        end

        def self.offset(offset_qwc : UInt16, irq : Bool = false) : VifCode
          VifCode.new(VifCmd::OFFSET.value, 0_u8, offset_qwc & 0x3FF_u16, irq)
        end

        def self.base(base_qwc : UInt16, irq : Bool = false) : VifCode
          VifCode.new(VifCmd::BASE.value, 0_u8, base_qwc & 0x3FF_u16, irq)
        end

        def self.itop(itop_qwc : UInt16, irq : Bool = false) : VifCode
          VifCode.new(VifCmd::ITOP.value, 0_u8, itop_qwc & 0x3FF_u16, irq)
        end

        def self.stmod(mode : UInt8 = 0_u8, irq : Bool = false) : VifCode
          VifCode.new(VifCmd::STMOD.value, 0_u8, (mode & 0x3_u8).to_u16, irq)
        end

        def self.flushe(irq : Bool = false) : VifCode
          VifCode.new(VifCmd::FLUSHE.value, 0_u8, 0_u16, irq)
        end

        def self.flush(irq : Bool = false) : VifCode
          VifCode.new(VifCmd::FLUSH.value, 0_u8, 0_u16, irq)
        end

        def self.flusha(irq : Bool = false) : VifCode
          VifCode.new(VifCmd::FLUSHA.value, 0_u8, 0_u16, irq)
        end

        def self.mscal(exec_addr : UInt16 = 0_u16, irq : Bool = false) : VifCode
          if exec_addr >= MAX_MICRO_INSTRUCTIONS
            raise ArgumentError.new("VIF1 MSCAL exec_addr (#{exec_addr}) exceeds VU1 Micro Memory limit (#{MAX_MICRO_INSTRUCTIONS - 1})")
          end
          VifCode.new(VifCmd::MSCAL.value, 0_u8, exec_addr, irq)
        end

        def self.mscalf(exec_addr : UInt16 = 0_u16, irq : Bool = false) : VifCode
          if exec_addr >= MAX_MICRO_INSTRUCTIONS
            raise ArgumentError.new("VIF1 MSCALF exec_addr (#{exec_addr}) exceeds VU1 Micro Memory limit (#{MAX_MICRO_INSTRUCTIONS - 1})")
          end
          VifCode.new(VifCmd::MSCALF.value, 0_u8, exec_addr, irq)
        end

        def self.mscnt(irq : Bool = false) : VifCode
          VifCode.new(VifCmd::MSCNT.value, 0_u8, 0_u16, irq)
        end

        # Creates an `MPG` VIFcode (`0x4A`) transferring `inst_count` (`1..256`) 64-bit instructions to `dst_addr`.
        def self.mpg(inst_count : Int, dst_addr : UInt16 = 0_u16, irq : Bool = false) : VifCode
          if inst_count <= 0 || inst_count > MAX_MPG_CHUNK
            raise ArgumentError.new("VIF1 MPG instruction count (#{inst_count}) must be between 1 and #{MAX_MPG_CHUNK}")
          end
          if dst_addr.to_i + inst_count > MAX_MICRO_INSTRUCTIONS
            raise ArgumentError.new("VIF1 MPG transfer (dst_addr=#{dst_addr}, count=#{inst_count}) exceeds VU1 Micro Memory (#{MAX_MICRO_INSTRUCTIONS} instructions)")
          end
          num_byte = (inst_count == 256) ? 0_u8 : inst_count.to_u8
          VifCode.new(VifCmd::MPG.value, num_byte, dst_addr, irq)
        end

        # Creates an `UNPACK` VIFcode (`0x60 | format`) transferring `qwc` (`1..256`) quadwords to VU1 Data Memory `vu_addr`.
        def self.unpack(
          format : UnpackFormat,
          qwc : Int,
          vu_addr : UInt16,
          use_tops : Bool = false,
          unsigned : Bool = false,
          masked : Bool = false,
          irq : Bool = false,
        ) : VifCode
          if qwc <= 0 || qwc > 256
            raise ArgumentError.new("VIF1 UNPACK quadword count (#{qwc}) must be between 1 and 256")
          end
          if vu_addr.to_i + qwc > MAX_DATA_QWC
            raise ArgumentError.new("VIF1 UNPACK transfer (vu_addr=#{vu_addr}, qwc=#{qwc}) exceeds VU1 Data Memory (#{MAX_DATA_QWC} quadwords)")
          end
          cmd_byte = 0x60_u8 | (format.value & 0x0F_u8)
          cmd_byte |= 0x10_u8 if masked
          num_byte = (qwc == 256) ? 0_u8 : qwc.to_u8
          imm = vu_addr & 0x3FF_u16
          imm |= (1_u16 << 14) if unsigned
          imm |= (1_u16 << 15) if use_tops
          VifCode.new(cmd_byte, num_byte, imm, irq)
        end

        def self.direct(qwc : Int, irq : Bool = false) : VifCode
          if qwc <= 0 || qwc > 65535
            raise ArgumentError.new("VIF1 DIRECT quadword count (#{qwc}) must be between 1 and 65535")
          end
          VifCode.new(VifCmd::DIRECT.value, 0_u8, (qwc == 65536 ? 0_u16 : qwc.to_u16), irq)
        end
      end

      # Zero-allocation-capable 32-bit word & 128-bit quadword stream packer for VIF1 DMA Channel 1 packets.
      class VifPacketPacker
        getter buffer : Bytes
        getter word_count : Int32
        getter capacity_words : Int32

        def initialize(capacity_qwc : Int32 = 1024)
          if capacity_qwc <= 0
            raise ArgumentError.new("VifPacketPacker capacity_qwc must be positive")
          end
          @capacity_words = capacity_qwc * 4
          @buffer = Bytes.new(@capacity_words * 4)
          @word_count = 0
        end

        def initialize(@buffer : Bytes)
          if (@buffer.size & 0xF) != 0 || @buffer.empty?
            raise ArgumentError.new("VifPacketPacker backing slice size (#{@buffer.size}) must be a positive multiple of 16 bytes")
          end
          @capacity_words = @buffer.size >> 2
          @word_count = 0
        end

        @[Citrine::ZeroAllocation]
        def reset! : self
          @word_count = 0
          self
        end

        @[Citrine::ZeroAllocation]
        def byte_size : Int32
          @word_count << 2
        end

        @[Citrine::ZeroAllocation]
        def qwc : Int32
          (@word_count + 3) >> 2
        end

        @[Citrine::ZeroAllocation]
        def qword_aligned? : Bool
          (@word_count & 0x3) == 0
        end

        @[Citrine::ZeroAllocation]
        def emit_word(word : UInt32) : Int32
          if @word_count >= @capacity_words
            raise IndexError.new("VifPacketPacker capacity exceeded (#{@capacity_words} words)")
          end
          idx = @word_count
          IO::ByteFormat::LittleEndian.encode(word, @buffer[idx << 2, 4])
          @word_count = idx + 1
          idx
        end

        @[Citrine::ZeroAllocation]
        def emit_u64(dword : UInt64) : Int32
          idx = emit_word((dword & 0xFFFFFFFF_u64).to_u32)
          emit_word((dword >> 32).to_u32)
          idx
        end

        @[Citrine::ZeroAllocation]
        def emit_vifcode(code : VifCode) : Int32
          emit_word(code.encode)
        end

        def nop(irq : Bool = false) : self
          emit_vifcode(VifCode.nop(irq))
          self
        end

        def stcycl(cl : UInt8 = 1_u8, wl : UInt8 = 1_u8, irq : Bool = false) : self
          emit_vifcode(VifCode.stcycl(cl, wl, irq))
          self
        end

        def offset(offset_qwc : UInt16, irq : Bool = false) : self
          emit_vifcode(VifCode.offset(offset_qwc, irq))
          self
        end

        def base(base_qwc : UInt16, irq : Bool = false) : self
          emit_vifcode(VifCode.base(base_qwc, irq))
          self
        end

        def itop(itop_qwc : UInt16, irq : Bool = false) : self
          emit_vifcode(VifCode.itop(itop_qwc, irq))
          self
        end

        def stmod(mode : UInt8 = 0_u8, irq : Bool = false) : self
          emit_vifcode(VifCode.stmod(mode, irq))
          self
        end

        def flushe(irq : Bool = false) : self
          emit_vifcode(VifCode.flushe(irq))
          self
        end

        def flush(irq : Bool = false) : self
          emit_vifcode(VifCode.flush(irq))
          self
        end

        def flusha(irq : Bool = false) : self
          emit_vifcode(VifCode.flusha(irq))
          self
        end

        def mscal(exec_addr : UInt16 = 0_u16, irq : Bool = false) : self
          emit_vifcode(VifCode.mscal(exec_addr, irq))
          self
        end

        def mscalf(exec_addr : UInt16 = 0_u16, irq : Bool = false) : self
          emit_vifcode(VifCode.mscalf(exec_addr, irq))
          self
        end

        def mscnt(irq : Bool = false) : self
          emit_vifcode(VifCode.mscnt(irq))
          self
        end

        # Packs a VU1 microprogram (`Array(MicroInstruction)` or `Slice(UInt64)` or `Array(UInt64)`) into one or more
        # VIF1 `MPG` (`0x4A`) transfer blocks, automatically splitting transfers larger than 256 instructions.
        def mpg(instructions : Array(MicroInstruction), dst_addr : UInt16 = 0_u16, irq : Bool = false) : self
          if instructions.empty?
            raise ArgumentError.new("VIF1 MPG requires at least 1 instruction")
          end
          if dst_addr.to_i + instructions.size > MAX_MICRO_INSTRUCTIONS
            raise ArgumentError.new("VIF1 MPG microprogram (#{instructions.size} instructions at #{dst_addr}) exceeds VU1 Micro Memory limit (#{MAX_MICRO_INSTRUCTIONS})")
          end

          offset = 0
          total = instructions.size
          while offset < total
            chunk = Math.min(total - offset, MAX_MPG_CHUNK)
            is_last = (offset + chunk == total)
            emit_vifcode(VifCode.mpg(chunk, dst_addr + offset.to_u16, irq: is_last ? irq : false))
            chunk.times do |i|
              emit_u64(instructions[offset + i].encode)
            end
            offset += chunk
          end
          self
        end

        def mpg(words : Array(UInt64) | Slice(UInt64), dst_addr : UInt16 = 0_u16, irq : Bool = false) : self
          if words.empty?
            raise ArgumentError.new("VIF1 MPG requires at least 1 64-bit instruction word")
          end
          if dst_addr.to_i + words.size > MAX_MICRO_INSTRUCTIONS
            raise ArgumentError.new("VIF1 MPG microprogram (#{words.size} instructions at #{dst_addr}) exceeds VU1 Micro Memory limit (#{MAX_MICRO_INSTRUCTIONS})")
          end

          offset = 0
          total = words.size
          while offset < total
            chunk = Math.min(total - offset, MAX_MPG_CHUNK)
            is_last = (offset + chunk == total)
            emit_vifcode(VifCode.mpg(chunk, dst_addr + offset.to_u16, irq: is_last ? irq : false))
            chunk.times do |i|
              emit_u64(words[offset + i])
            end
            offset += chunk
          end
          self
        end

        # Packs an `UNPACK` command (`0x60 | format`) and its raw byte payload into the VIF1 stream,
        # padding trailing payload bytes to a 32-bit word boundary.
        def unpack(
          format : UnpackFormat,
          vu_addr : UInt16,
          payload : Bytes,
          qwc : Int? = nil,
          use_tops : Bool = false,
          unsigned : Bool = false,
          masked : Bool = false,
          irq : Bool = false,
        ) : self
          bpq = format.bytes_per_qword
          computed_qwc = qwc || (payload.size // bpq)
          if computed_qwc <= 0
            raise ArgumentError.new("VIF1 UNPACK computed QWC (#{computed_qwc}) must be >= 1")
          end
          expected_bytes = computed_qwc * bpq
          if payload.size < expected_bytes
            raise ArgumentError.new("VIF1 UNPACK payload size (#{payload.size} bytes) is smaller than required (#{expected_bytes} bytes for #{computed_qwc} QWC of #{format})")
          end

          emit_vifcode(VifCode.unpack(format, computed_qwc, vu_addr, use_tops: use_tops, unsigned: unsigned, masked: masked, irq: irq))

          # Emit 32-bit words (with zero-padding to 4-byte boundary if needed)
          full_words = expected_bytes >> 2
          rem_bytes = expected_bytes & 0x3
          full_words.times do |w_idx|
            word = IO::ByteFormat::LittleEndian.decode(UInt32, payload[w_idx << 2, 4])
            emit_word(word)
          end
          if rem_bytes > 0
            last_word = 0_u32
            rem_bytes.times do |b|
              last_word |= (payload[(full_words << 2) + b].to_u32 << (b * 8))
            end
            emit_word(last_word)
          end
          self
        end

        # Convenience helper: Unpacks an array of 128-bit `Quadword`s using `UnpackFormat::V4_32`.
        def unpack_quadwords(
          vu_addr : UInt16,
          quadwords : Array(Citrine::Core::DMA::Quadword) | Slice(Citrine::Core::DMA::Quadword),
          use_tops : Bool = false,
          irq : Bool = false,
        ) : self
          if quadwords.empty?
            raise ArgumentError.new("VIF1 unpack_quadwords requires at least 1 quadword")
          end
          emit_vifcode(VifCode.unpack(UnpackFormat::V4_32, quadwords.size, vu_addr, use_tops: use_tops, irq: irq))
          quadwords.each do |qw|
            emit_u64(qw.lo)
            emit_u64(qw.hi)
          end
          self
        end

        # Convenience helper: Unpacks an array/slice of `Float32` values using the specified `UnpackFormat` (default `V4_32`).
        def unpack_floats(
          vu_addr : UInt16,
          floats : Array(Float32) | Slice(Float32),
          format : UnpackFormat = UnpackFormat::V4_32,
          use_tops : Bool = false,
          irq : Bool = false,
        ) : self
          bpq = format.bytes_per_qword
          total_bytes = floats.size * 4
          if (total_bytes % bpq) != 0 || floats.empty?
            raise ArgumentError.new("Float count (#{floats.size}, #{total_bytes} bytes) must be a positive multiple of #{bpq} bytes for #{format}")
          end
          qwc_count = total_bytes // bpq
          emit_vifcode(VifCode.unpack(format, qwc_count, vu_addr, use_tops: use_tops, irq: irq))
          floats.each do |f|
            emit_word(f.unsafe_as(UInt32))
          end
          self
        end

        # Pads the VIF1 stream with `VIF1 NOP` (`0x00000000`) until aligned to a 128-bit (16-byte / 4-word) quadword boundary.
        @[Citrine::ZeroAllocation]
        def align_to_qword! : self
          while (@word_count & 0x3) != 0
            emit_word(0_u32)
          end
          self
        end

        # Aligns the stream to a 128-bit quadword boundary and returns the written `Bytes` slice.
        @[Citrine::ZeroAllocation]
        def to_slice : Bytes
          align_to_qword!
          @buffer[0, @word_count << 2]
        end

        # Reads the 32-bit word at index `idx`.
        def word_at(idx : Int32) : UInt32
          if idx < 0 || idx >= @word_count
            raise IndexError.new("Word index #{idx} out of bounds (word_count: #{@word_count})")
          end
          IO::ByteFormat::LittleEndian.decode(UInt32, @buffer[idx << 2, 4])
        end
      end

      # =========================================================================
      # Assembled VU1 Microprogram Container (`AssembledProgram`)
      # =========================================================================

      struct AssembledProgram
        getter instructions : Array(MicroInstruction)
        getter labels : Hash(String, Int32)
        getter hazard_report : HazardReport

        def initialize(
          @instructions : Array(MicroInstruction),
          @labels : Hash(String, Int32),
          @hazard_report : HazardReport,
        )
        end

        def size : Int32
          @instructions.size
        end

        def byte_size : Int32
          @instructions.size * 8
        end

        # Returns the 64-bit encoded instruction words.
        def words : Array(UInt64)
          @instructions.map(&.encode)
        end

        # Serializes the assembled 64-bit VLIW instructions to a little-endian `Bytes` slice.
        def to_slice : Bytes
          bytes = Bytes.new(@instructions.size * 8)
          @instructions.each_with_index do |inst, idx|
            IO::ByteFormat::LittleEndian.encode(inst.encode, bytes[idx * 8, 8])
          end
          bytes
        end

        # Packs this microprogram into a 16-byte aligned VIF1 DMA packet (`MPG` + optional `FLUSH` + optional `MSCAL`).
        def pack_vif1(
          dst_addr : UInt16 = 0_u16,
          flush_before : Bool = false,
          mscal : Bool = false,
          exec_addr : UInt16? = nil,
          flush_after : Bool = false,
        ) : Bytes
          packer = VifPacketPacker.new(capacity_qwc: (@instructions.size // 2) + 16)
          packer.flush if flush_before
          packer.mpg(@instructions, dst_addr: dst_addr)
          packer.mscal(exec_addr || dst_addr) if mscal
          packer.flush if flush_after
          packer.to_slice
        end
      end

      # =========================================================================
      # VU1 Dual-Issue Microcode Assembler (`Citrine::Core::VU1::Assembler`)
      # =========================================================================

      class Assembler
        getter instructions : Array(MicroInstruction)
        getter labels : Hash(String, Int32)

        def initialize
          @instructions = [] of MicroInstruction
          @labels = {} of String => Int32
        end

        # Current instruction program counter (in 64-bit VLIW instruction units).
        def pc : Int32
          @instructions.size
        end

        # Defines a symbolic branch target label at the current instruction PC.
        def label(name : String | Symbol) : self
          key = name.to_s
          if @labels.has_key?(key)
            raise ArgumentError.new("Duplicate VU1 microcode label '#{key}'")
          end
          @labels[key] = pc
          self
        end

        # Appends a dual-issue `(upper, lower)` instruction pair at the current PC.
        def emit(
          upper : UpperInstruction = UpperInstruction.nop,
          lower : LowerInstruction = LowerInstruction.nop,
        ) : self
          if pc >= MAX_MICRO_INSTRUCTIONS
            raise IndexError.new("VU1 microprogram exceeds hardware Micro Memory limit (#{MAX_MICRO_INSTRUCTIONS} instructions)")
          end
          @instructions << MicroInstruction.new(upper: upper, lower: lower, pc: pc)
          self
        end

        # Appends an `LOI` immediate float load instruction paired with `upper` (automatically sets `flag_i = true`).
        def emit_loi(
          imm_float : Float32,
          upper : UpperInstruction = UpperInstruction.nop,
        ) : self
          u_with_i = UpperInstruction.new(
            op: upper.op,
            dest: upper.dest,
            fd: upper.fd,
            fs: upper.fs,
            ft: upper.ft,
            bc: upper.bc,
            flag_i: true,
            flag_e: upper.flag_e?,
            flag_m: upper.flag_m?,
            flag_d: upper.flag_d?,
            flag_t: upper.flag_t?
          )
          emit(u_with_i, LowerInstruction.loi(imm_float))
        end

        # Appends a dual-issue `NOP | NOP` instruction (optionally setting the `[E]` program end bit).
        def nop(flag_e : Bool = false) : self
          emit(UpperInstruction.nop(flag_e: flag_e), LowerInstruction.nop)
        end

        # Resolves symbolic branch labels and runs the pipeline & register hazard detector.
        # When `strict_hazards` is true, raises `HazardError` if any error-severity hazard is detected.
        def finalize!(strict_hazards : Bool = true) : AssembledProgram
          resolved = resolve_branches
          report = HazardDetector.analyze(resolved)
          if strict_hazards && report.has_errors?
            raise HazardError.new(report.errors)
          end
          AssembledProgram.new(resolved, @labels.dup, report)
        end

        def build(strict_hazards : Bool = true) : AssembledProgram
          finalize!(strict_hazards: strict_hazards)
        end

        # Resolves any pending symbolic branch labels into 11-bit signed relative offsets (`target_pc - current_pc - 1`).
        private def resolve_branches : Array(MicroInstruction)
          @instructions.map_with_index do |inst, idx|
            if target_name = inst.lower.target_label
              target_pc = @labels[target_name]? || raise ArgumentError.new("Undefined VU1 branch label '#{target_name}' at PC #{idx}")
              rel_offset = target_pc - idx - 1
              if rel_offset < -1024 || rel_offset > 1023
                raise ArgumentError.new("VU1 branch offset (#{rel_offset}) to '#{target_name}' at PC #{idx} exceeds 11-bit signed range (-1024..1023)")
              end
              MicroInstruction.new(upper: inst.upper, lower: inst.lower.with_imm(rel_offset), pc: idx)
            else
              inst
            end
          end
        end

        # =====================================================================
        # Text-Based VLIW Microcode Parser (`Assembler.assemble`)
        # =====================================================================

        # Assembles multi-line VU1 dual-issue VLIW assembly text into an `AssembledProgram`.
        # Each non-empty line may define a label (`loop:`), a dual-issue pair separated by `|`
        # (`MUL.xyzw vf01, vf02, vf03 | LQ.xyzw vf04, 0(vi01)`), or a single Upper/Lower instruction
        # (automatically paired with `NOP`).
        def self.assemble(source : String, strict_hazards : Bool = true) : AssembledProgram
          assembler = Assembler.new
          assembler.parse_and_emit(source)
          assembler.finalize!(strict_hazards: strict_hazards)
        end

        def parse_and_emit(source : String) : self
          source.each_line do |raw_line|
            line = strip_comments(raw_line).strip
            next if line.empty?

            # Extract any leading label definitions (`loop: ...`)
            while match = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*:(.*)$/)
              label(match[1])
              line = match[2].strip
            end
            next if line.empty?

            if pipe_idx = line.index('|')
              upper_str = line[0...pipe_idx].strip
              lower_str = line[(pipe_idx + 1)..].strip
              u_inst, loi_from_u = parse_upper_or_loi(upper_str)
              if lower_str.downcase.starts_with?("loi")
                fval = parse_loi_value(lower_str)
                emit_loi(fval, u_inst)
              elsif fval = loi_from_u
                emit_loi(fval, u_inst)
              else
                l_inst = parse_lower(lower_str)
                emit(u_inst, l_inst)
              end
            else
              # Single instruction on line: determine if Upper, Lower, or LOI
              token = line.split(/\s+/, 2)[0].downcase
              base_op = token.split('.')[0].split('[')[0]
              if base_op == "loi"
                fval = parse_loi_value(line)
                emit_loi(fval, UpperInstruction.nop)
              elsif upper_mnemonic?(base_op)
                u_inst, _ = parse_upper_or_loi(line)
                emit(u_inst, LowerInstruction.nop)
              else
                l_inst = parse_lower(line)
                emit(UpperInstruction.nop, l_inst)
              end
            end
          end
          self
        end

        private def strip_comments(line : String) : String
          if (idx = line.index('#')) || (idx = line.index(';')) || (idx = line.index("//"))
            line[0...idx]
          else
            line
          end
        end

        private def upper_mnemonic?(op : String) : Bool
          case op
          when "nop", "vnop",
               "add", "addi", "addq", "addx", "addy", "addz", "addw",
               "sub", "subi", "subq", "subx", "suby", "subz", "subw",
               "madd", "maddi", "maddq", "maddx", "maddy", "maddz", "maddw",
               "msub", "msubi", "msubq", "msubx", "msuby", "msubz", "msubw",
               "mul", "muli", "mulq", "mulx", "muly", "mulz", "mulw",
               "max", "maxi", "maxx", "maxy", "maxz", "maxw",
               "mini", "minii", "minix", "miniy", "miniz", "miniw",
               "adda", "addai", "addaq", "addax", "adday", "addaz", "addaw",
               "suba", "subai", "subaq", "subax", "subay", "subaz", "subaw",
               "madda", "maddai", "maddaq", "maddax", "madday", "maddaz", "maddaw",
               "msuba", "msubai", "msubaq", "msubax", "msubay", "msubaz", "msubaw",
               "mula", "mulai", "mulaq", "mulax", "mulay", "mulaz", "mulaw",
               "opmula", "opmsub", "abs", "clip", "clipw",
               "ftoi0", "ftoi4", "ftoi12", "ftoi15",
               "itof0", "itof4", "itof12", "itof15"
            true
          else
            false
          end
        end

        private def parse_loi_value(text : String) : Float32
          parts = text.strip.split(/\s+/, 2)
          arg = parts[1]? ? parts[1].strip : "0.0"
          arg.to_f32
        end

        private def parse_upper_or_loi(text : String) : Tuple(UpperInstruction, Float32?)
          parts = text.strip.split(/\s+/, 2)
          head = parts[0]
          args_str = parts[1]? ? parts[1].strip : ""
          args = args_str.split(',').map(&.strip).reject(&.empty?)

          # Extract mode flags like `[E]`, `[M]`, `[D]`, `[T]`, `[I]`
          flag_i = false
          flag_e = false
          flag_m = false
          flag_d = false
          flag_t = false

          if bracket_start = head.index('[')
            if bracket_end = head.index(']', bracket_start)
              flags_str = head[(bracket_start + 1)...bracket_end].downcase
              flag_i = flags_str.includes?('i')
              flag_e = flags_str.includes?('e')
              flag_m = flags_str.includes?('m')
              flag_d = flags_str.includes?('d')
              flag_t = flags_str.includes?('t')
              head = head[0...bracket_start] + head[(bracket_end + 1)..]
            end
          end

          dot_parts = head.downcase.split('.', 2)
          mnemonic = dot_parts[0]
          dest = dot_parts[1]? ? DestMask.parse(dot_parts[1]) : DestMask::XYZW

          if mnemonic == "nop" || mnemonic == "vnop"
            return {UpperInstruction.nop(flag_i: flag_i, flag_e: flag_e, flag_m: flag_m, flag_d: flag_d, flag_t: flag_t), nil}
          end

          op, bc = resolve_upper_op_and_bc(mnemonic)

          fd = 0_u8
          fs = 0_u8
          ft = 0_u8

          case op
          when .add?, .sub?, .madd?, .msub?, .mul?, .max?, .mini?, .opmsub?,
               .addbc?, .subbc?, .maddbc?, .msubbc?, .mulbc?, .maxbc?, .minibc?
            fd = VfReg.parse(args[0]).index
            fs = VfReg.parse(args[1]).index
            ft = VfReg.parse(args[2]).index
          when .addi?, .addq?, .subi?, .subq?, .maddi?, .maddq?, .msubi?, .msubq?,
               .muli?, .mulq?, .maxi?, .minii?
            fd = VfReg.parse(args[0]).index
            fs = VfReg.parse(args[1]).index
          when .adda?, .suba?, .madda?, .msuba?, .mula?, .opmula?,
               .addabc?, .subabc?, .maddabc?, .msubabc?, .mulabc?
            # Accept either `ADDA.xyzw ACC, vf1, vf2` or `ADDA.xyzw vf1, vf2`
            offset = (args.size >= 3 && args[0].downcase.starts_with?("acc")) ? 1 : 0
            fs = VfReg.parse(args[offset]).index
            ft = VfReg.parse(args[offset + 1]).index
          when .addai?, .addaq?, .subai?, .subaq?, .maddai?, .maddaq?, .msubai?, .msubaq?, .mulai?, .mulaq?
            offset = (args.size >= 2 && args[0].downcase.starts_with?("acc")) ? 1 : 0
            fs = VfReg.parse(args[offset]).index
          when .abs?, .ftoi0?, .ftoi4?, .ftoi12?, .ftoi15?, .itof0?, .itof4?, .itof12?, .itof15?
            ft = VfReg.parse(args[0]).index
            fs = VfReg.parse(args[1]).index
          when .clip?
            fs = VfReg.parse(args[0]).index
            ft = VfReg.parse(args[1]).index
            dest = DestMask::XYZ
          else
            # default
          end

          inst = UpperInstruction.new(
            op: op,
            dest: dest,
            fd: fd,
            fs: fs,
            ft: ft,
            bc: bc,
            flag_i: flag_i,
            flag_e: flag_e,
            flag_m: flag_m,
            flag_d: flag_d,
            flag_t: flag_t
          )
          {inst, nil}
        end

        private def resolve_upper_op_and_bc(mnemonic : String) : Tuple(UpperOp, Broadcast)
          case mnemonic
          when "add"           then {UpperOp::ADD, Broadcast::X}
          when "addi"          then {UpperOp::ADDI, Broadcast::X}
          when "addq"          then {UpperOp::ADDQ, Broadcast::X}
          when "addx"          then {UpperOp::ADDBC, Broadcast::X}
          when "addy"          then {UpperOp::ADDBC, Broadcast::Y}
          when "addz"          then {UpperOp::ADDBC, Broadcast::Z}
          when "addw"          then {UpperOp::ADDBC, Broadcast::W}
          when "sub"           then {UpperOp::SUB, Broadcast::X}
          when "subi"          then {UpperOp::SUBI, Broadcast::X}
          when "subq"          then {UpperOp::SUBQ, Broadcast::X}
          when "subx"          then {UpperOp::SUBBC, Broadcast::X}
          when "suby"          then {UpperOp::SUBBC, Broadcast::Y}
          when "subz"          then {UpperOp::SUBBC, Broadcast::Z}
          when "subw"          then {UpperOp::SUBBC, Broadcast::W}
          when "madd"          then {UpperOp::MADD, Broadcast::X}
          when "maddi"         then {UpperOp::MADDI, Broadcast::X}
          when "maddq"         then {UpperOp::MADDQ, Broadcast::X}
          when "maddx"         then {UpperOp::MADDBC, Broadcast::X}
          when "maddy"         then {UpperOp::MADDBC, Broadcast::Y}
          when "maddz"         then {UpperOp::MADDBC, Broadcast::Z}
          when "maddw"         then {UpperOp::MADDBC, Broadcast::W}
          when "msub"          then {UpperOp::MSUB, Broadcast::X}
          when "msubi"         then {UpperOp::MSUBI, Broadcast::X}
          when "msubq"         then {UpperOp::MSUBQ, Broadcast::X}
          when "msubx"         then {UpperOp::MSUBBC, Broadcast::X}
          when "msuby"         then {UpperOp::MSUBBC, Broadcast::Y}
          when "msubz"         then {UpperOp::MSUBBC, Broadcast::Z}
          when "msubw"         then {UpperOp::MSUBBC, Broadcast::W}
          when "mul"           then {UpperOp::MUL, Broadcast::X}
          when "muli"          then {UpperOp::MULI, Broadcast::X}
          when "mulq"          then {UpperOp::MULQ, Broadcast::X}
          when "mulx"          then {UpperOp::MULBC, Broadcast::X}
          when "muly"          then {UpperOp::MULBC, Broadcast::Y}
          when "mulz"          then {UpperOp::MULBC, Broadcast::Z}
          when "mulw"          then {UpperOp::MULBC, Broadcast::W}
          when "max"           then {UpperOp::MAX, Broadcast::X}
          when "maxi"          then {UpperOp::MAXI, Broadcast::X}
          when "maxx"          then {UpperOp::MAXBC, Broadcast::X}
          when "maxy"          then {UpperOp::MAXBC, Broadcast::Y}
          when "maxz"          then {UpperOp::MAXBC, Broadcast::Z}
          when "maxw"          then {UpperOp::MAXBC, Broadcast::W}
          when "mini"          then {UpperOp::MINI, Broadcast::X}
          when "minii"         then {UpperOp::MINII, Broadcast::X}
          when "minix"         then {UpperOp::MINIBC, Broadcast::X}
          when "miniy"         then {UpperOp::MINIBC, Broadcast::Y}
          when "miniz"         then {UpperOp::MINIBC, Broadcast::Z}
          when "miniw"         then {UpperOp::MINIBC, Broadcast::W}
          when "adda"          then {UpperOp::ADDA, Broadcast::X}
          when "addai"         then {UpperOp::ADDAI, Broadcast::X}
          when "addaq"         then {UpperOp::ADDAQ, Broadcast::X}
          when "addax"         then {UpperOp::ADDABC, Broadcast::X}
          when "adday"         then {UpperOp::ADDABC, Broadcast::Y}
          when "addaz"         then {UpperOp::ADDABC, Broadcast::Z}
          when "addaw"         then {UpperOp::ADDABC, Broadcast::W}
          when "suba"          then {UpperOp::SUBA, Broadcast::X}
          when "subai"         then {UpperOp::SUBAI, Broadcast::X}
          when "subaq"         then {UpperOp::SUBAQ, Broadcast::X}
          when "subax"         then {UpperOp::SUBABC, Broadcast::X}
          when "subay"         then {UpperOp::SUBABC, Broadcast::Y}
          when "subaz"         then {UpperOp::SUBABC, Broadcast::Z}
          when "subaw"         then {UpperOp::SUBABC, Broadcast::W}
          when "madda"         then {UpperOp::MADDA, Broadcast::X}
          when "maddai"        then {UpperOp::MADDAI, Broadcast::X}
          when "maddaq"        then {UpperOp::MADDAQ, Broadcast::X}
          when "maddax"        then {UpperOp::MADDABC, Broadcast::X}
          when "madday"        then {UpperOp::MADDABC, Broadcast::Y}
          when "maddaz"        then {UpperOp::MADDABC, Broadcast::Z}
          when "maddaw"        then {UpperOp::MADDABC, Broadcast::W}
          when "msuba"         then {UpperOp::MSUBA, Broadcast::X}
          when "msubai"        then {UpperOp::MSUBAI, Broadcast::X}
          when "msubaq"        then {UpperOp::MSUBAQ, Broadcast::X}
          when "msubax"        then {UpperOp::MSUBABC, Broadcast::X}
          when "msubay"        then {UpperOp::MSUBABC, Broadcast::Y}
          when "msubaz"        then {UpperOp::MSUBABC, Broadcast::Z}
          when "msubaw"        then {UpperOp::MSUBABC, Broadcast::W}
          when "mula"          then {UpperOp::MULA, Broadcast::X}
          when "mulai"         then {UpperOp::MULAI, Broadcast::X}
          when "mulaq"         then {UpperOp::MULAQ, Broadcast::X}
          when "mulax"         then {UpperOp::MULABC, Broadcast::X}
          when "mulay"         then {UpperOp::MULABC, Broadcast::Y}
          when "mulaz"         then {UpperOp::MULABC, Broadcast::Z}
          when "mulaw"         then {UpperOp::MULABC, Broadcast::W}
          when "opmula"        then {UpperOp::OPMULA, Broadcast::X}
          when "opmsub"        then {UpperOp::OPMSUB, Broadcast::X}
          when "abs"           then {UpperOp::ABS, Broadcast::X}
          when "clip", "clipw" then {UpperOp::CLIP, Broadcast::W}
          when "ftoi0"         then {UpperOp::FTOI0, Broadcast::X}
          when "ftoi4"         then {UpperOp::FTOI4, Broadcast::X}
          when "ftoi12"        then {UpperOp::FTOI12, Broadcast::X}
          when "ftoi15"        then {UpperOp::FTOI15, Broadcast::X}
          when "itof0"         then {UpperOp::ITOF0, Broadcast::X}
          when "itof4"         then {UpperOp::ITOF4, Broadcast::X}
          when "itof12"        then {UpperOp::ITOF12, Broadcast::X}
          when "itof15"        then {UpperOp::ITOF15, Broadcast::X}
          else
            raise ArgumentError.new("Unknown VU1 Upper instruction mnemonic '#{mnemonic}'")
          end
        end

        private def parse_lower(text : String) : LowerInstruction
          parts = text.strip.split(/\s+/, 2)
          head = parts[0].downcase
          args_str = parts[1]? ? parts[1].strip : ""
          args = args_str.split(',').map(&.strip).reject(&.empty?)

          dot_parts = head.split('.', 2)
          mnemonic = dot_parts[0]
          dest = dot_parts[1]? ? DestMask.parse(dot_parts[1]) : DestMask::XYZW

          case mnemonic
          when "nop", "vnop"
            LowerInstruction.nop
          when "lq"
            ft = VfReg.parse(args[0]).index
            imm, is = parse_mem_operand(args[1])
            LowerInstruction.new(op: LowerOp::LQ, dest: dest, ft: ft, is: is, imm: imm)
          when "sq"
            fs = VfReg.parse(args[0]).index
            imm, it = parse_mem_operand(args[1])
            LowerInstruction.new(op: LowerOp::SQ, dest: dest, fs: fs, it: it, imm: imm)
          when "lqi"
            ft = VfReg.parse(args[0]).index
            is = parse_inc_dec_vi(args[1])
            LowerInstruction.new(op: LowerOp::LQI, dest: dest, ft: ft, is: is)
          when "sqi"
            fs = VfReg.parse(args[0]).index
            it = parse_inc_dec_vi(args[1])
            LowerInstruction.new(op: LowerOp::SQI, dest: dest, fs: fs, it: it)
          when "lqd"
            ft = VfReg.parse(args[0]).index
            is = parse_inc_dec_vi(args[1])
            LowerInstruction.new(op: LowerOp::LQD, dest: dest, ft: ft, is: is)
          when "sqd"
            fs = VfReg.parse(args[0]).index
            it = parse_inc_dec_vi(args[1])
            LowerInstruction.new(op: LowerOp::SQD, dest: dest, fs: fs, it: it)
          when "ilw"
            it = ViReg.parse(args[0]).index
            imm, is = parse_mem_operand(args[1])
            LowerInstruction.new(op: LowerOp::ILW, dest: dest, it: it, is: is, imm: imm)
          when "isw"
            it = ViReg.parse(args[0]).index
            imm, is = parse_mem_operand(args[1])
            LowerInstruction.new(op: LowerOp::ISW, dest: dest, it: it, is: is, imm: imm)
          when "iadd"
            id = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            it = ViReg.parse(args[2]).index
            LowerInstruction.new(op: LowerOp::IADD, id: id, is: is, it: it)
          when "isub"
            id = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            it = ViReg.parse(args[2]).index
            LowerInstruction.new(op: LowerOp::ISUB, id: id, is: is, it: it)
          when "iaddi"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            imm = parse_int(args[2])
            LowerInstruction.new(op: LowerOp::IADDI, it: it, is: is, imm: imm)
          when "iaddiu"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            imm = parse_int(args[2])
            LowerInstruction.new(op: LowerOp::IADDIU, it: it, is: is, imm: imm)
          when "isubiu"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            imm = parse_int(args[2])
            LowerInstruction.new(op: LowerOp::ISUBIU, it: it, is: is, imm: imm)
          when "iand"
            id = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            it = ViReg.parse(args[2]).index
            LowerInstruction.new(op: LowerOp::IAND, id: id, is: is, it: it)
          when "ior"
            id = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            it = ViReg.parse(args[2]).index
            LowerInstruction.new(op: LowerOp::IOR, id: id, is: is, it: it)
          when "move"
            ft = VfReg.parse(args[0]).index
            fs = VfReg.parse(args[1]).index
            LowerInstruction.new(op: LowerOp::MOVE, dest: dest, ft: ft, fs: fs)
          when "mr32"
            ft = VfReg.parse(args[0]).index
            fs = VfReg.parse(args[1]).index
            LowerInstruction.new(op: LowerOp::MR32, dest: dest, ft: ft, fs: fs)
          when "mfir"
            ft = VfReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            LowerInstruction.new(op: LowerOp::MFIR, dest: dest, ft: ft, is: is)
          when "mtir"
            it = ViReg.parse(args[0]).index
            fs, fsf = parse_vf_with_lane(args[1])
            LowerInstruction.new(op: LowerOp::MTIR, it: it, fs: fs, fsf: fsf)
          when "div"
            offset = (args.size >= 3 && args[0].downcase == "q") ? 1 : 0
            fs, fsf = parse_vf_with_lane(args[offset])
            ft, ftf = parse_vf_with_lane(args[offset + 1])
            LowerInstruction.new(op: LowerOp::DIV, fs: fs, fsf: fsf, ft: ft, ftf: ftf)
          when "sqrt"
            offset = (args.size >= 2 && args[0].downcase == "q") ? 1 : 0
            ft, ftf = parse_vf_with_lane(args[offset])
            LowerInstruction.new(op: LowerOp::SQRT, ft: ft, ftf: ftf)
          when "rsqrt"
            offset = (args.size >= 3 && args[0].downcase == "q") ? 1 : 0
            fs, fsf = parse_vf_with_lane(args[offset])
            ft, ftf = parse_vf_with_lane(args[offset + 1])
            LowerInstruction.new(op: LowerOp::RSQRT, fs: fs, fsf: fsf, ft: ft, ftf: ftf)
          when "waitq"
            LowerInstruction.new(op: LowerOp::WAITQ, dest: DestMask::None)
          when "waitp"
            LowerInstruction.new(op: LowerOp::WAITP, dest: DestMask::None)
          when "xgkick"
            is = ViReg.parse(args[0]).index
            LowerInstruction.new(op: LowerOp::XGKICK, dest: DestMask::None, is: is)
          when "xtop"
            it = ViReg.parse(args[0]).index
            LowerInstruction.new(op: LowerOp::XTOP, dest: DestMask::None, it: it)
          when "xitop"
            it = ViReg.parse(args[0]).index
            LowerInstruction.new(op: LowerOp::XITOP, dest: DestMask::None, it: it)
          when "b"
            imm, lbl = parse_branch_target(args[0])
            LowerInstruction.new(op: LowerOp::B, dest: DestMask::None, imm: imm, target_label: lbl)
          when "bal"
            it = ViReg.parse(args[0]).index
            imm, lbl = parse_branch_target(args[1])
            LowerInstruction.new(op: LowerOp::BAL, dest: DestMask::None, it: it, imm: imm, target_label: lbl)
          when "jr"
            is = ViReg.parse(args[0]).index
            LowerInstruction.new(op: LowerOp::JR, dest: DestMask::None, is: is)
          when "jalr"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            LowerInstruction.new(op: LowerOp::JALR, dest: DestMask::None, it: it, is: is)
          when "ibeq"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            imm, lbl = parse_branch_target(args[2])
            LowerInstruction.new(op: LowerOp::IBEQ, dest: DestMask::None, it: it, is: is, imm: imm, target_label: lbl)
          when "ibne"
            it = ViReg.parse(args[0]).index
            is = ViReg.parse(args[1]).index
            imm, lbl = parse_branch_target(args[2])
            LowerInstruction.new(op: LowerOp::IBNE, dest: DestMask::None, it: it, is: is, imm: imm, target_label: lbl)
          when "ibltz"
            is = ViReg.parse(args[0]).index
            imm, lbl = parse_branch_target(args[1])
            LowerInstruction.new(op: LowerOp::IBLTZ, dest: DestMask::None, is: is, imm: imm, target_label: lbl)
          when "ibgtz"
            is = ViReg.parse(args[0]).index
            imm, lbl = parse_branch_target(args[1])
            LowerInstruction.new(op: LowerOp::IBGTZ, dest: DestMask::None, is: is, imm: imm, target_label: lbl)
          when "iblez"
            is = ViReg.parse(args[0]).index
            imm, lbl = parse_branch_target(args[1])
            LowerInstruction.new(op: LowerOp::IBLEZ, dest: DestMask::None, is: is, imm: imm, target_label: lbl)
          when "ibgez"
            is = ViReg.parse(args[0]).index
            imm, lbl = parse_branch_target(args[1])
            LowerInstruction.new(op: LowerOp::IBGEZ, dest: DestMask::None, is: is, imm: imm, target_label: lbl)
          else
            raise ArgumentError.new("Unknown VU1 Lower instruction mnemonic '#{mnemonic}'")
          end
        end

        private def parse_int(str : String) : Int32
          s = str.strip
          if s.starts_with?("0x") || s.starts_with?("0X")
            s[2..].to_i(16)
          elsif s.starts_with?("-0x") || s.starts_with?("-0X")
            -s[3..].to_i(16)
          else
            s.to_i
          end
        end

        private def parse_mem_operand(str : String) : Tuple(Int32, UInt8)
          s = str.strip
          if match = s.match(/^(-?\d+|0x[0-9a-fA-F]+)?\s*\(\s*(\$?[a-zA-Z0-9]+)\s*\)$/)
            off_s = match[1]?
            imm = (off_s && !off_s.empty?) ? parse_int(off_s) : 0
            vi = ViReg.parse(match[2]).index
            {imm, vi}
          else
            raise ArgumentError.new("Invalid VU1 memory operand '#{str}' (expected imm(viXX))")
          end
        end

        private def parse_inc_dec_vi(str : String) : UInt8
          cleaned = str.strip.gsub(/[()+\-\s]/, "")
          ViReg.parse(cleaned).index
        end

        private def parse_vf_with_lane(str : String) : Tuple(UInt8, Broadcast)
          s = str.strip
          if dot = s.index('.')
            reg_part = s[0...dot]
            lane_part = s[(dot + 1)..]
            {VfReg.parse(reg_part).index, Broadcast.parse(lane_part)}
          elsif s.size > 4 && (s.ends_with?('x') || s.ends_with?('y') || s.ends_with?('z') || s.ends_with?('w')) && s.downcase.starts_with?("vf")
            reg_part = s[0...-1]
            lane_part = s[-1..]
            {VfReg.parse(reg_part).index, Broadcast.parse(lane_part)}
          else
            {VfReg.parse(s).index, Broadcast::X}
          end
        end

        private def parse_branch_target(str : String) : Tuple(Int32, String?)
          s = str.strip
          if s.matches?(/^-?(?:\d+|0x[0-9a-fA-F]+)$/)
            {parse_int(s), nil}
          else
            {0, s}
          end
        end
      end
    end
  end
end
