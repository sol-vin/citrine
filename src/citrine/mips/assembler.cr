module Citrine
  module MIPS
    # In-memory assembler for MIPS R5900, COP0, and COP2 (VU0 Macro Mode).
    # Converts human-readable assembly strings into 32-bit Little-Endian machine words.
    class Assembler
      GPR_MAP = {
        "zero" => 0, "r0" => 0, "0" => 0,
        "at" => 1, "r1" => 1, "1" => 1,
        "v0" => 2, "r2" => 2, "2" => 2,
        "v1" => 3, "r3" => 3, "3" => 3,
        "a0" => 4, "r4" => 4, "4" => 4,
        "a1" => 5, "r5" => 5, "5" => 5,
        "a2" => 6, "r6" => 6, "6" => 6,
        "a3" => 7, "r7" => 7, "7" => 7,
        "t0" => 8, "r8" => 8, "8" => 8,
        "t1" => 9, "r9" => 9, "9" => 9,
        "t2" => 10, "r10" => 10, "10" => 10,
        "t3" => 11, "r11" => 11, "11" => 11,
        "t4" => 12, "r12" => 12, "12" => 12,
        "t5" => 13, "r13" => 13, "13" => 13,
        "t6" => 14, "r14" => 14, "14" => 14,
        "t7" => 15, "r15" => 15, "15" => 15,
        "s0" => 16, "r16" => 16, "16" => 16,
        "s1" => 17, "r17" => 17, "17" => 17,
        "s2" => 18, "r18" => 18, "18" => 18,
        "s3" => 19, "r19" => 19, "19" => 19,
        "s4" => 20, "r20" => 20, "20" => 20,
        "s5" => 21, "r21" => 21, "21" => 21,
        "s6" => 22, "r22" => 22, "22" => 22,
        "s7" => 23, "r23" => 23, "23" => 23,
        "t8" => 24, "r24" => 24, "24" => 24,
        "t9" => 25, "r25" => 25, "25" => 25,
        "k0" => 26, "r26" => 26, "26" => 26,
        "k1" => 27, "r27" => 27, "27" => 27,
        "gp" => 28, "r28" => 28, "28" => 28,
        "sp" => 29, "r29" => 29, "29" => 29,
        "fp" => 30, "s8" => 30, "r30" => 30, "30" => 30,
        "ra" => 31, "r31" => 31, "31" => 31,
      }

      # Assembles a single line or multiline block of assembly instructions into 32-bit machine words.
      def self.assemble(text : String) : Array(UInt32)
        words = [] of UInt32
        text.each_line do |line|
          line = line.strip
          # Strip comments
          if (idx = line.index('#')) || (idx = line.index(';')) || (idx = line.index("//"))
            line = line[0...idx].strip
          end
          next if line.empty?

          # Handle multiple statements separated by semicolon
          sub_lines = line.split(';')
          sub_lines.each do |sub|
            sub = sub.strip
            next if sub.empty?
            words << assemble_line(sub)
          end
        end
        words
      end

      # Assembles a single normalized instruction line into a 32-bit word.
      def self.assemble_line(line : String) : UInt32
        line = line.strip
        # Check if line is a raw hex number (e.g. 0x0000000F or 15)
        clean_num = line.gsub(/_[a-zA-Z0-9]+$/, "")
        if clean_num.starts_with?("0x") || clean_num.starts_with?("0X")
          return clean_num[2..].to_u32(16)
        end
        if clean_num.matches?(/^\d+$/)
          return clean_num.to_u32
        end

        parts = line.split(/\s+/, 2)
        mnemonic = parts[0].downcase
        args_str = parts[1]? ? parts[1].strip : ""
        args = split_args(args_str)

        case mnemonic
        when "nop"
          0x00000000_u32

        # --- Synchronization & System ---
        when "sync", "sync.l"
          0x0000000F_u32
        when "sync.p"
          0x0000040F_u32

        # --- COP0 System Control (Cycle Counter, etc.) ---
        when "mfc0"
          # mfc0 $rt, $rd (e.g. mfc0 $v0, $9)
          rt = parse_gpr(args[0])
          rd = parse_cop0_reg(args[1])
          (0x10_u32 << 26) | (rt.to_u32 << 16) | (rd.to_u32 << 11)

        when "mtc0"
          rt = parse_gpr(args[0])
          rd = parse_cop0_reg(args[1])
          (0x10_u32 << 26) | (0x04_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11)

        # --- Data Prefetch ---
        when "pref"
          # pref hint, offset(base)
          hint = parse_imm(args[0]) & 0x1F
          offset, base = parse_offset_base(args[1])
          (0x33_u32 << 26) | (base.to_u32 << 21) | (hint.to_u32 << 16) | (offset & 0xFFFF).to_u32

        # --- 128-bit Quadword Memory Moves ---
        when "lq"
          # lq $rt, offset($base)
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x1E_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        when "sq"
          # sq $rt, offset($base)
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x1F_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        # --- 32-bit & 64-bit Memory Moves ---
        when "lw"
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x23_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        when "sw"
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x2B_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        when "ld"
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x37_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        when "sd"
          rt = parse_gpr(args[0])
          offset, base = parse_offset_base(args[1])
          (0x3F_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | (offset & 0xFFFF).to_u32

        # --- Immediate Arithmetic & Logic ---
        when "lui"
          rt = parse_gpr(args[0])
          imm = parse_imm(args[1])
          (0x0F_u32 << 26) | (rt.to_u32 << 16) | (imm & 0xFFFF).to_u32

        when "addiu"
          rt = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          imm = parse_imm(args[2])
          (0x09_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm & 0xFFFF).to_u32

        when "ori"
          rt = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          imm = parse_imm(args[2])
          (0x0D_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm & 0xFFFF).to_u32

        when "andi"
          rt = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          imm = parse_imm(args[2])
          (0x0C_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm & 0xFFFF).to_u32

        when "xori"
          rt = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          imm = parse_imm(args[2])
          (0x0E_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | (imm & 0xFFFF).to_u32

        # --- Register Register Arithmetic & Logic ---
        when "addu"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x21_u32

        when "subu"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x23_u32

        when "or"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x25_u32

        when "and"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x24_u32

        when "xor"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x26_u32

        when "nor"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          rt = parse_gpr(args[2])
          (rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x27_u32

        when "move"
          rd = parse_gpr(args[0])
          rs = parse_gpr(args[1])
          (rs.to_u32 << 21) | (rd.to_u32 << 11) | 0x25_u32 # or rd, rs, zero

        # --- Shifts ---
        when "sll"
          rd = parse_gpr(args[0])
          rt = parse_gpr(args[1])
          sa = parse_imm(args[2]) & 0x1F
          (rt.to_u32 << 16) | (rd.to_u32 << 11) | (sa.to_u32 << 6) | 0x00_u32

        when "srl"
          rd = parse_gpr(args[0])
          rt = parse_gpr(args[1])
          sa = parse_imm(args[2]) & 0x1F
          (rt.to_u32 << 16) | (rd.to_u32 << 11) | (sa.to_u32 << 6) | 0x02_u32

        when "sra"
          rd = parse_gpr(args[0])
          rt = parse_gpr(args[1])
          sa = parse_imm(args[2]) & 0x1F
          (rt.to_u32 << 16) | (rd.to_u32 << 11) | (sa.to_u32 << 6) | 0x03_u32

        # --- COP2 / VU0 Macro Mode ---
        when "qmfc2"
          # qmfc2 $rt, vf_s
          rt = parse_gpr(args[0])
          vs = parse_vu_vf(args[1])
          (0x12_u32 << 26) | (rt.to_u32 << 16) | (vs.to_u32 << 11)

        when "qmtc2"
          # qmtc2 $rt, vf_s
          rt = parse_gpr(args[0])
          vs = parse_vu_vf(args[1])
          (0x12_u32 << 26) | (0x04_u32 << 21) | (rt.to_u32 << 16) | (vs.to_u32 << 11)

        when "cfc2"
          rt = parse_gpr(args[0])
          vi = parse_vu_vi(args[1])
          (0x12_u32 << 26) | (0x02_u32 << 21) | (rt.to_u32 << 16) | (vi.to_u32 << 11)

        when "ctc2"
          rt = parse_gpr(args[0])
          vi = parse_vu_vi(args[1])
          (0x12_u32 << 26) | (0x06_u32 << 21) | (rt.to_u32 << 16) | (vi.to_u32 << 11)

        when "vadd.xyzw", "vadd"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x28, vd, vs, vt, 0x0F)

        when "vsub.xyzw", "vsub"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x2C, vd, vs, vt, 0x0F)

        when "vmul.xyzw", "vmul"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x2A, vd, vs, vt, 0x0F)

        when "vmula.xyzw", "vmula"
          vs = parse_vu_vf(args[0])
          vt = parse_vu_vf(args[1])
          encode_vu0_macro(0x3E, 0x0A, vs, vt, 0x0F)

        when "vmadd.xyzw", "vmadd"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x29, vd, vs, vt, 0x0F)

        when "vmax.xyzw", "vmax"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x2B, vd, vs, vt, 0x0F)

        when "vmin.xyzw", "vmin"
          vd = parse_vu_vf(args[0])
          vs = parse_vu_vf(args[1])
          vt = parse_vu_vf(args[2])
          encode_vu0_macro(0x2F, vd, vs, vt, 0x0F)

        else
          raise "Citrine::MIPS::Assembler: Unrecognized assembly instruction '#{mnemonic}' in '#{line}'"
        end
      end

      # Encodes a VU0 macro mode instruction (Opcode 0x12, bit 25 = 1)
      private def self.encode_vu0_macro(func : UInt32, vd : Int32, vs : Int32, vt : Int32, dest_mask : UInt32 = 0x0F) : UInt32
        # Format: [0x12:6][1:1][dest_mask:4][vt:5][vs:5][vd:5][func:6]
        (0x12_u32 << 26) | (1_u32 << 25) | (dest_mask << 21) |
          (vt.to_u32 << 16) | (vs.to_u32 << 11) | (vd.to_u32 << 6) | func
      end

      private def self.split_args(args_str : String) : Array(String)
        args_str.split(',').map(&.strip).reject(&.empty?)
      end

      private def self.parse_gpr(reg_str : String) : Int32
        cleaned = reg_str.strip.lstrip('$')
        if reg = GPR_MAP[cleaned.downcase]?
          reg
        else
          raise "Citrine::MIPS::Assembler: Unknown GPR register '#{reg_str}'"
        end
      end

      private def self.parse_cop0_reg(reg_str : String) : Int32
        cleaned = reg_str.strip.lstrip('$')
        case cleaned.downcase
        when "count", "9"
          9
        when "compare", "11"
          11
        when "status", "12"
          12
        when "cause", "13"
          13
        when "epc", "14"
          14
        when "prid", "15"
          15
        else
          if num = cleaned.to_i?
            num
          else
            raise "Citrine::MIPS::Assembler: Unknown COP0 register '#{reg_str}'"
          end
        end
      end

      private def self.parse_vu_vf(reg_str : String) : Int32
        cleaned = reg_str.strip.lstrip('$').downcase
        if cleaned.starts_with?("vf")
          num = cleaned[2..].to_i? || raise "Invalid VU0 vector register '#{reg_str}'"
          if num >= 0 && num <= 31
            return num
          end
        elsif num = cleaned.to_i?
          return num if num >= 0 && num <= 31
        end
        raise "Citrine::MIPS::Assembler: Expected VU0 vector register (vf0..vf31), got '#{reg_str}'"
      end

      private def self.parse_vu_vi(reg_str : String) : Int32
        cleaned = reg_str.strip.lstrip('$').downcase
        if cleaned.starts_with?("vi")
          num = cleaned[2..].to_i? || raise "Invalid VU0 integer register '#{reg_str}'"
          return num if num >= 0 && num <= 15
        elsif num = cleaned.to_i?
          return num if num >= 0 && num <= 15
        end
        raise "Citrine::MIPS::Assembler: Expected VU0 integer register (vi0..vi15), got '#{reg_str}'"
      end

      private def self.parse_imm(imm_str : String) : Int32
        imm_str = imm_str.strip
        if imm_str.starts_with?("0x") || imm_str.starts_with?("0X")
          imm_str[2..].to_i(16)
        else
          imm_str.to_i
        end
      end

      # Parses memory offset-base format like "16($sp)", "0($a0)", "-4($s0)", or "($t0)"
      private def self.parse_offset_base(str : String) : Tuple(Int32, Int32)
        str = str.strip
        if match = str.match(/^(-?\d+|0x[0-9a-fA-F]+)?\s*\(\s*(\$?[a-zA-Z0-9]+)\s*\)$/)
          offset_str = match[1]?
          offset = (offset_str && !offset_str.empty?) ? parse_imm(offset_str) : 0
          base = parse_gpr(match[2])
          {offset, base}
        else
          raise "Citrine::MIPS::Assembler: Expected offset(base) format (e.g. 0($a0)), got '#{str}'"
        end
      end
    end
  end
end
