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

      def xori(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0E_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
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

      def sllv(rd : Int32, rt : Int32, rs : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x04_u32)
      end

      def srlv(rd : Int32, rt : Int32, rs : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x06_u32)
      end

      def srav(rd : Int32, rt : Int32, rs : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x07_u32)
      end

      def srl(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | ((sa & 0x1F).to_u32 << 6) | 0x02_u32)
      end

      def sra(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | ((sa & 0x1F).to_u32 << 6) | 0x03_u32)
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

      # Load Quadword (128-bit) - EE MIPS R5900
      def lq(rt : Int32, offset : Int32, base : Int32)
        emit((0x1E_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      # Store Quadword (128-bit) - EE MIPS R5900
      def sq(rt : Int32, offset : Int32, base : Int32)
        emit((0x1F_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end


      def lb(rt : Int32, offset : Int32, base : Int32)
        emit((0x20_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
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

      def mult(rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | 0x18_u32)
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

      def jalr(rs : Int32, rd : Int32 = RA)
        emit((rs.to_u32 << 21) | (rd.to_u32 << 11) | 0x09_u32)
      end

      def syscall_inst
        emit(0x0000000C_u32)
      end

      def break_inst
        emit(0x0000000D_u32)
      end

      def mfc0(rt : Int32, rd : Int32)
        emit((0x10_u32 << 26) | (rt.to_u32 << 16) | (rd.to_u32 << 11))
      end

      def mtc0(rt : Int32, rd : Int32)
        emit((0x10_u32 << 26) | (0x04_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11))
      end

      def sync_p
        emit(0x0000040F_u32)
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

      def bgez(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bgez}
        emit((0x01_u32 << 26) | (rs.to_u32 << 21) | (0x01_u32 << 16))
      end

      def bltz(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bltz}
        emit((0x01_u32 << 26) | (rs.to_u32 << 21) | (0x00_u32 << 16))
      end

      def bgtz(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bgtz}
        emit((0x07_u32 << 26) | (rs.to_u32 << 21))
      end

      def blez(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :blez}
        emit((0x06_u32 << 26) | (rs.to_u32 << 21))
      end

      def bal(target_label : String)
        @fixups << {@words.size, target_label, :bal}
        emit((0x01_u32 << 26) | (0x11_u32 << 16))
      end

      # Performs branch delay slot optimization pass:
      # If a branch or jump at index `i` is followed by a `nop` at `i + 1`,
      # and the preceding instruction at `i - 1` is safe to move into the delay slot:
      # 1. Swaps `cand` into `i + 1` (replacing `nop`)
      # 2. Removes `cand` at `i - 1`
      # 3. Updates all label addresses and fixup indices accordingly.
      # Must be called BEFORE resolve!.
      def optimize_delay_slots! : Int32
        optimized_count = 0
        i = 1

        label_addrs = @labels.values.to_set
        delay_slots = Set(Int32).new

        while i < @words.size - 1
          branch_word = @words[i]
          next_word = @words[i + 1]

          if next_word == 0_u32 && is_branch_or_jump?(branch_word)
            cand_idx = i - 1
            cand_word = @words[cand_idx]

            cand_vaddr = @base_vaddr + (cand_idx.to_u32 * 4)
            branch_vaddr = @base_vaddr + (i.to_u32 * 4)
            delay_vaddr = @base_vaddr + ((i + 1).to_u32 * 4)

            if !delay_slots.includes?(cand_idx) &&
               !label_addrs.includes?(cand_vaddr) &&
               !label_addrs.includes?(branch_vaddr) &&
               !label_addrs.includes?(delay_vaddr) &&
               !@fixups.any? { |fidx, _, _| fidx == cand_idx } &&
               can_fill_delay_slot?(cand_word, branch_word)

              # Relocate cand_word into delay slot (replacing nop at i + 1)
              @words[i + 1] = cand_word
              # Delete cand_word at i - 1
              @words.delete_at(cand_idx)

              # Update all labels with virtual address > cand_vaddr: subtract 4 bytes
              @labels.each do |lname, laddr|
                if laddr > cand_vaddr
                  @labels[lname] = laddr - 4_u32
                end
              end
              label_addrs = @labels.values.to_set

              # Update fixups:
              # For any fixup with index == i: it was at i, now at i - 1
              # For any fixup with index > i: index decreases by 1
              @fixups.map! do |fidx, flabel, ftype|
                if fidx == i
                  {fidx - 1, flabel, ftype}
                elsif fidx > i
                  {fidx - 1, flabel, ftype}
                else
                  {fidx, flabel, ftype}
                end
              end

              # Mark the new delay slot position (which is now at index i)
              delay_slots.add(i)

              optimized_count += 1
              # The branch is now at index i - 1, its delay slot is at i.
              # Proceed to i + 1 for subsequent instructions
              i += 1
              next
            end
          end

          i += 1
        end

        optimized_count
      end

      private def is_branch_or_jump?(word : UInt32) : Bool
        opcode = (word >> 26) & 0x3F
        case opcode
        when 0x00 # SPECIAL: jr (0x08), jalr (0x09)
          funct = word & 0x3F
          funct == 0x08_u32 || funct == 0x09_u32
        when 0x01 # REGIMM: bltz (0x00), bgez (0x01), bal (0x11)
          rt = (word >> 16) & 0x1F
          rt == 0x00_u32 || rt == 0x01_u32 || rt == 0x11_u32
        when 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 # j, jal, beq, bne, blez, bgtz
          true
        else
          false
        end
      end

      private def branch_reads_registers(word : UInt32) : Array(Int32)
        opcode = (word >> 26) & 0x3F
        rs = ((word >> 21) & 0x1F).to_i
        rt = ((word >> 16) & 0x1F).to_i

        case opcode
        when 0x00 # SPECIAL: jr, jalr
          funct = word & 0x3F
          (funct == 0x08_u32 || funct == 0x09_u32) ? [rs] : [] of Int32
        when 0x01 # REGIMM: bltz, bgez, bal
          [rs]
        when 0x02, 0x03 # j, jal
          [] of Int32
        when 0x04, 0x05 # beq, bne
          [rs, rt]
        when 0x06, 0x07 # blez, bgtz
          [rs]
        else
          [] of Int32
        end
      end

      private def branch_writes_registers(word : UInt32) : Array(Int32)
        opcode = (word >> 26) & 0x3F
        case opcode
        when 0x03 # jal
          [31]
        when 0x01 # REGIMM: bal
          rt = ((word >> 16) & 0x1F).to_i
          rt == 0x11 ? [31] : [] of Int32
        when 0x00 # SPECIAL: jalr
          funct = word & 0x3F
          if funct == 0x09
            rd = ((word >> 11) & 0x1F).to_i
            rd > 0 ? [rd] : [31]
          else
            [] of Int32
          end
        else
          [] of Int32
        end
      end

      private def instruction_writes_register(word : UInt32) : Int32?
        opcode = (word >> 26) & 0x3F
        case opcode
        when 0x00 # SPECIAL
          funct = word & 0x3F
          case funct
          when 0x08 # jr
            nil
          when 0x09 # jalr (writes rd, default RA=31)
            rd = ((word >> 11) & 0x1F).to_i
            rd > 0 ? rd : 31
          when 0x18, 0x19, 0x1A, 0x1B, 0x0C, 0x0D # mult, multu, div, divu, syscall, break
            nil
          else
            rd = ((word >> 11) & 0x1F).to_i
            rd > 0 ? rd : nil
          end
        when 0x01 # REGIMM: bal writes RA (31)
          rt = ((word >> 16) & 0x1F).to_i
          rt == 0x11 ? 31 : nil
        when 0x03 # jal
          31
        when 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F # addi, addiu, slti, sltiu, andi, ori, xori, lui
          rt = ((word >> 16) & 0x1F).to_i
          rt > 0 ? rt : nil
        when 0x1E, 0x20, 0x21, 0x23, 0x24, 0x25, 0x37 # loads: lq, lb, lh, lw, lbu, lhu, ld
          rt = ((word >> 16) & 0x1F).to_i
          rt > 0 ? rt : nil
        else
          nil
        end
      end

      private def instruction_reads_registers(word : UInt32) : Array(Int32)
        opcode = (word >> 26) & 0x3F
        rs = ((word >> 21) & 0x1F).to_i
        rt = ((word >> 16) & 0x1F).to_i

        case opcode
        when 0x00 # SPECIAL
          funct = word & 0x3F
          case funct
          when 0x00, 0x02, 0x03 # sll, srl, sra (reads rt)
            rt > 0 ? [rt] : [] of Int32
          when 0x10, 0x12 # mfhi, mflo
            [] of Int32
          when 0x08, 0x09 # jr, jalr (reads rs)
            rs > 0 ? [rs] : [] of Int32
          else
            reads = [] of Int32
            reads << rs if rs > 0
            reads << rt if rt > 0
            reads
          end
        when 0x0F # lui (reads nothing)
          [] of Int32
        when 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E # addi, addiu, slti, sltiu, andi, ori, xori
          rs > 0 ? [rs] : [] of Int32
        when 0x1E, 0x20, 0x21, 0x23, 0x24, 0x25, 0x37 # loads: base = rs (including lq)
          rs > 0 ? [rs] : [] of Int32
        when 0x1F, 0x28, 0x29, 0x2B, 0x3F # stores: reads rt and base rs (including sq)
          reads = [] of Int32
          reads << rs if rs > 0
          reads << rt if rt > 0
          reads
        else
          reads = [] of Int32
          reads << rs if rs > 0
          reads << rt if rt > 0
          reads
        end
      end

      private def can_fill_delay_slot?(cand_word : UInt32, branch_word : UInt32) : Bool
        return false if cand_word == 0_u32 # Don't relocate nop into nop
        return false if is_branch_or_jump?(cand_word)

        cand_opcode = (cand_word >> 26) & 0x3F
        return false if cand_opcode == 0x10 || cand_opcode == 0x12 # COP0, COP2
        if cand_opcode == 0x00
          funct = cand_word & 0x3F
          return false if funct == 0x0C || funct == 0x0D # syscall, break
          return false if cand_word == 0x0000040F_u32     # sync.p
        end

        branch_reads = branch_reads_registers(branch_word)
        branch_writes = branch_writes_registers(branch_word)

        if wr = instruction_writes_register(cand_word)
          return false if branch_reads.includes?(wr)
        end

        branch_writes.each do |bw|
          if wr = instruction_writes_register(cand_word)
            return false if wr == bw
          end
          cand_reads = instruction_reads_registers(cand_word)
          return false if cand_reads.includes?(bw)
        end

        true
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
          when :bnez, :beqz, :bne, :beq, :bgez, :bltz, :bgtz, :blez, :bal
            offset_bytes = target_vaddr.to_i32 - (inst_vaddr.to_i32 + 4)
            offset_insts = offset_bytes // 4
            @words[idx] = (@words[idx] & 0xFFFF0000_u32) | ((offset_insts & 0xFFFF).to_u32)
          when :hi16
            @words[idx] = (@words[idx] & 0xFFFF0000_u32) | ((target_vaddr >> 16) & 0xFFFF_u32)
          when :lo16
            @words[idx] = (@words[idx] & 0xFFFF0000_u32) | (target_vaddr & 0xFFFF_u32)
          end
        end
      end


      # --- MIPS Macro DSL & Assembly Idiom Helpers ---

      # Loads the 32-bit address of a label into register rt via %hi/%lo fixups
      def la(rt : Int32, label_name : String)
        @fixups << {@words.size, label_name, :hi16}
        lui(rt, 0)
        @fixups << {@words.size, label_name, :lo16}
        ori(rt, rt, 0)
      end

      # Emits a null-terminated 4-byte aligned ASCII string literal directly into words
      def emit_string(str : String)
        bytes = str.to_slice
        i = 0
        while i < bytes.size
          b0 = bytes[i].to_u32
          b1 = (i + 1 < bytes.size) ? bytes[i + 1].to_u32 : 0_u32
          b2 = (i + 2 < bytes.size) ? bytes[i + 2].to_u32 : 0_u32
          b3 = (i + 3 < bytes.size) ? bytes[i + 3].to_u32 : 0_u32
          emit(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
          i += 4
        end
        if (bytes.size % 4) == 0
          emit(0x00000000_u32)
        end
      end

      # Loads a 32-bit or 16-bit immediate value into register rt
      def li(rt : Int32, val : UInt32 | Int32)
        u = val.is_a?(Int32) ? (val.to_i64 & 0xFFFFFFFF_i64).to_u32 : val
        if u <= 0xFFFF_u32
          ori(rt, ZERO, u.to_i32)
        elsif (u & 0xFFFF_u32) == 0_u32
          lui(rt, (u >> 16).to_i32)
        elsif (u & 0x8000_u32) == 0 && (u <= 0x7FFF_u32)
          addiu(rt, ZERO, u.to_i32)
        else
          lui(rt, (u >> 16).to_i32)
          ori(rt, rt, (u & 0xFFFF_u32).to_i32)
        end
      end

      # Safe subroutine call (jal + branch delay slot nop)
      def call(label_name : String)
        jal(label_name)
        nop
      end

      # Safe unconditional jump (j + branch delay slot nop)
      def jump(label_name : String)
        j(label_name)
        nop
      end

      # Safe subroutine return (jr $ra + branch delay slot nop)
      def ret
        jr(RA)
        nop
      end

      # Load word from SPRAM (Base register T0 = 0x70000000)
      def spram_read(rt : Int32, offset : Int32, base : Int32 = T0)
        lw(rt, offset, base)
      end

      # Store word to SPRAM (Base register T0 = 0x70000000)
      def spram_write(rt : Int32, offset : Int32, base : Int32 = T0)
        sw(rt, offset, base)
      end

      # Kicks DMA Channel 2 from fixed address with fixed QWC
      def dma02_kick(madr_addr : UInt32, qwc : UInt16 | Int32)
        call("dma02_wait")
        lui(T8, 0x1000)
        ori(T8, T8, 0xa000)
        li(T7, madr_addr)
        sw(T7, 0x10, T8)
        ori(T6, ZERO, qwc.to_i32)
        sw(T6, 0x20, T8)
        ori(T5, ZERO, 0x101)
        sw(T5, 0x00, T8)
        call("dma02_wait")
      end

      # Kicks DMA Channel 2 using registers for MADR and QWC
      def dma02_kick_reg(madr_reg : Int32, qwc_reg : Int32)
        call("dma02_wait")
        lui(T8, 0x1000)
        ori(T8, T8, 0xa000)
        sw(madr_reg, 0x10, T8)
        sw(qwc_reg, 0x20, T8)
        ori(T5, ZERO, 0x101)
        sw(T5, 0x00, T8)
        call("dma02_wait")
      end

      # Standard VSync spin-wait on GS_CSR (0x12001000) bit 3
      def vsync_wait(label_prefix : String = "vsync")
        lui(V1, 0x1200)
        ori(V1, V1, 0x1000)
        ori(V0, ZERO, 8)
        sd(V0, 0, V1)
        lui(T1, 0x0020)
        lbl_spin = "#{label_prefix}_spin"
        lbl_done = "#{label_prefix}_done"
        label(lbl_spin)
        ld(V0, 0, V1)
        andi(V0, V0, 8)
        bnez(V0, lbl_done)
        addiu(T1, T1, -1)
        bnez(T1, lbl_spin)
        nop
        label(lbl_done)
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

