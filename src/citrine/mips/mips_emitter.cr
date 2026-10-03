module Citrine
  module MIPS
    # MIPS R5900 Register Encodings
    ZERO = 0
    AT   = 1
    V0   = 2;  V1 = 3
    A0   = 4;  A1 = 5;  A2 = 6;  A3 = 7
    T0   = 8;  T1 = 9;  T2 = 10; T3 = 11; T4 = 12; T5 = 13; T6 = 14; T7 = 15
    S0   = 16; S1 = 17; S2 = 18; S3 = 19; S4 = 20; S5 = 21; S6 = 22; S7 = 23
    T8   = 24; T9 = 25
    K0   = 26; K1 = 27
    GP   = 28; SP = 29; FP = 30; RA = 31

    # Emotion Engine MIPS R5900 Instruction Emitter
    class MipsEmitter
      property base_vaddr : UInt32
      getter words = [] of UInt32
      getter labels = {} of String => UInt32
      getter fixups = [] of Tuple(Int32, String, Symbol)

      def initialize(@base_vaddr = 0x00100000_u32)
      end

      def label(name : String)
        @labels[name] = @base_vaddr + (@words.size.to_u32 * 4)
      end

      def emit(word : UInt32)
        @words << word
      end

      def nop
        emit(0x00000000_u32)
      end

      def lui(rt : Int32, imm : Int32)
        emit((0x0F_u32 << 26) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def ori(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0D_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def andi(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0C_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def addiu(rt : Int32, rs : Int32, imm : Int32)
        emit((0x09_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def or_(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x25_u32)
      end

      def and_(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x24_u32)
      end

      def xor_(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x26_u32)
      end

      def nor(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x27_u32)
      end

      def srlv(rd : Int32, rt : Int32, rs : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x06_u32)
      end

      def srl(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | ((sa & 0x1F).to_u32 << 6) | 0x02_u32)
      end

      def sll(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | ((sa & 0x1F).to_u32 << 6) | 0x00_u32)
      end

      def dsll32(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | (sa.to_u32 << 6) | 0x3C_u32)
      end

      def lw(rt : Int32, offset : Int32, base : Int32)
        emit((0x23_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sw(rt : Int32, offset : Int32, base : Int32)
        emit((0x2B_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def ld(rt : Int32, offset : Int32, base : Int32)
        emit((0x37_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sd(rt : Int32, offset : Int32, base : Int32)
        emit((0x3F_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def lbu(rt : Int32, offset : Int32, base : Int32)
        emit((0x24_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def lhu(rt : Int32, offset : Int32, base : Int32)
        emit((0x25_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sb(rt : Int32, offset : Int32, base : Int32)
        emit((0x28_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sh(rt : Int32, offset : Int32, base : Int32)
        emit((0x29_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def slt(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x2A_u32)
      end

      def sltu(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x2B_u32)
      end

      def slti(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0A_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm.to_u32 & 0xFFFF))
      end

      def sltiu(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0B_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm.to_u32 & 0xFFFF))
      end

      def subu(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x23_u32)
      end

      def addu(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x21_u32)
      end

      def multu(rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | 0x19_u32)
      end

      def mflo(rd : Int32)
        emit((rd.to_u32 << 11) | 0x12_u32)
      end

      def mfhi(rd : Int32)
        emit((rd.to_u32 << 11) | 0x10_u32)
      end

      def divu(rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | 0x1B_u32)
      end

      def move(rd : Int32, rs : Int32)
        or_(rd, rs, ZERO)
      end

      def jr(rs : Int32)
        emit((rs.to_u32 << 21) | 0x08_u32)
      end

      def syscall_inst
        emit(0x0000000C_u32)
      end

      def mfc0(rt : Int32, rd : Int32)
        emit((0x10_u32 << 26) | (rt.to_u32 << 16) | (rd.to_u32 << 11))
      end

      def j(target_label : String)
        @fixups << {@words.size, target_label, :j}
        emit(0x08000000_u32)
      end

      def jal(target_label : String)
        @fixups << {@words.size, target_label, :jal}
        emit(0x0C000000_u32)
      end

      def bnez(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bnez}
        emit((0x05_u32 << 26) | (rs.to_u32 << 21))
      end

      def beqz(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :beqz}
        emit((0x04_u32 << 26) | (rs.to_u32 << 21))
      end

      def bne(rs : Int32, rt : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bne}
        emit((0x05_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16))
      end

      def beq(rs : Int32, rt : Int32, target_label : String)
        @fixups << {@words.size, target_label, :beq}
        emit((0x04_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16))
      end

      def resolve!
        @fixups.each do |idx, label_name, type|
          target_vaddr = @labels[label_name]? || raise "Unknown label: #{label_name}"
          inst_vaddr = @base_vaddr + (idx.to_u32 * 4)

          case type
          when :j
            @words[idx] = 0x08000000_u32 | ((target_vaddr >> 2) & 0x03FFFFFF_u32)
          when :jal
            @words[idx] = 0x0C000000_u32 | ((target_vaddr >> 2) & 0x03FFFFFF_u32)
          when :bnez, :beqz, :bne, :beq
            offset_bytes = target_vaddr.to_i32 - (inst_vaddr.to_i32 + 4)
            offset_insts = offset_bytes // 4
            @words[idx] = (@words[idx] & 0xFFFF0000_u32) | ((offset_insts & 0xFFFF).to_u32)
          end
        end
      end

      def pad_to(byte_size : Int32)
        while @words.size * 4 < byte_size
          nop
        end
      end

      def to_slice : Bytes
        io = IO::Memory.new(@words.size * 4)
        @words.each do |w|
          io.write_bytes(w, IO::ByteFormat::LittleEndian)
        end
        io.to_slice
      end
    end
  end
end
