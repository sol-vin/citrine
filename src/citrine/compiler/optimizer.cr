require "./opcode"

module Citrine
  class BytecodeOptimizer
    getter opt_level : Int32
    getter constants : Array(ConstValue)

    def initialize(@constants : Array(ConstValue), @opt_level : Int32 = 1)
    end

    def optimize(instructions : Array(Instruction)) : Array(Instruction)
      return instructions if @opt_level <= 0 || instructions.empty?

      insts = instructions.dup

      # Pass 1: Constant Folding & Algebraic Simplification (peephole)
      insts = run_constant_folding(insts)

      # Pass 2: Citrine-32 Peephole Instruction Fusion (Compare-Branch, Loop-Dec-Branch, MADD)
      insts = run_peephole_fusion(insts)

      # Pass 3: Dead Code Elimination (unreachable instructions after Return/Jump)
      insts = run_dead_code_elimination(insts)

      # Pass 4: NOP Compaction & Jump Offset Fixup
      insts = run_nop_compaction(insts)

      insts
    end

    private def run_constant_folding(instructions : Array(Instruction)) : Array(Instruction)
      result = instructions.dup
      jump_targets = collect_jump_targets(instructions)
      known_ints = Hash(UInt8, Int32).new

      result.each_with_index do |inst, idx|
        if jump_targets.includes?(idx)
          known_ints.clear
        end

        case inst.opcode
        when Opcode::LoadImm
          case inst.subop
          when LoadImmSubOp::Int16.value
            raw_val = inst.imm16.to_i32
            val = raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val
            known_ints[inst.dst] = val
          when LoadImmSubOp::UInt16.value
            known_ints[inst.dst] = inst.imm16.to_i32
          when LoadImmSubOp::Zero.value, LoadImmSubOp::Nil.value
            known_ints[inst.dst] = 0
          when LoadImmSubOp::MinusOne.value
            known_ints[inst.dst] = -1
          when LoadImmSubOp::Bool.value
            known_ints[inst.dst] = inst.imm16 != 0 ? 1 : 0
          else
            known_ints.delete(inst.dst)
          end

        when Opcode::Move
          if inst.dst == inst.a
            result[idx] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
          elsif known_ints.has_key?(inst.a)
            known_ints[inst.dst] = known_ints[inst.a]
          else
            known_ints.delete(inst.dst)
          end

        when Opcode::Add
          dst = inst.dst
          a = inst.a
          b = inst.b
          if known_ints.has_key?(a) && known_ints.has_key?(b)
            sum = known_ints[a] + known_ints[b]
            if sum >= -32768 && sum <= 32767
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (sum & 0xFFFF).to_u16)
              known_ints[dst] = sum
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 0
            result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
            if known_ints.has_key?(a)
              known_ints[dst] = known_ints[a]
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(a) && known_ints[a] == 0
            result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, b, 0_u8)
            if known_ints.has_key?(b)
              known_ints[dst] = known_ints[b]
            else
              known_ints.delete(dst)
            end
          else
            known_ints.delete(dst)
          end

        when Opcode::Sub
          dst = inst.dst
          a = inst.a
          b = inst.b
          if known_ints.has_key?(a) && known_ints.has_key?(b)
            diff = known_ints[a] - known_ints[b]
            if diff >= -32768 && diff <= 32767
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (diff & 0xFFFF).to_u16)
              known_ints[dst] = diff
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 0
            result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
            if known_ints.has_key?(a)
              known_ints[dst] = known_ints[a]
            else
              known_ints.delete(dst)
            end
          else
            known_ints.delete(dst)
          end

        when Opcode::Mul
          dst = inst.dst
          a = inst.a
          b = inst.b
          if known_ints.has_key?(a) && known_ints.has_key?(b)
            prod = known_ints[a] * known_ints[b]
            if prod >= -32768 && prod <= 32767
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (prod & 0xFFFF).to_u16)
              known_ints[dst] = prod
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 1
            result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
            if known_ints.has_key?(a)
              known_ints[dst] = known_ints[a]
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(a) && known_ints[a] == 1
            result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, b, 0_u8)
            if known_ints.has_key?(b)
              known_ints[dst] = known_ints[b]
            else
              known_ints.delete(dst)
            end
          elsif (known_ints.has_key?(b) && known_ints[b] == 0) || (known_ints.has_key?(a) && known_ints[a] == 0)
            result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Zero.value, dst, 0_u16)
            known_ints[dst] = 0
          else
            known_ints.delete(dst)
          end

        when Opcode::Bitwise
          dst = inst.dst
          a = inst.a
          b = inst.b
          subop = inst.subop
          case subop
          when BitwiseSubOp::And.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              val = known_ints[a] & known_ints[b]
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif (known_ints.has_key?(b) && known_ints[b] == 0) || (known_ints.has_key?(a) && known_ints[a] == 0)
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Zero.value, dst, 0_u16)
              known_ints[dst] = 0
            elsif known_ints.has_key?(b) && known_ints[b] == -1
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            elsif known_ints.has_key?(a) && known_ints[a] == -1
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, b, 0_u8)
              if known_ints.has_key?(b)
                known_ints[dst] = known_ints[b]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end

          when BitwiseSubOp::Or.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              val = known_ints[a] | known_ints[b]
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif known_ints.has_key?(b) && known_ints[b] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            elsif known_ints.has_key?(a) && known_ints[a] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, b, 0_u8)
              if known_ints.has_key?(b)
                known_ints[dst] = known_ints[b]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end

          when BitwiseSubOp::Xor.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              val = known_ints[a] ^ known_ints[b]
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif a == b
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Zero.value, dst, 0_u16)
              known_ints[dst] = 0
            elsif known_ints.has_key?(b) && known_ints[b] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            elsif known_ints.has_key?(a) && known_ints[a] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, b, 0_u8)
              if known_ints.has_key?(b)
                known_ints[dst] = known_ints[b]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end
          else
            known_ints.delete(dst)
          end

        when Opcode::Shift
          dst = inst.dst
          a = inst.a
          b = inst.b
          subop = inst.subop
          case subop
          when ShiftSubOp::Sll.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              shamt = known_ints[b] & 31
              val = known_ints[a] << shamt
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif known_ints.has_key?(b) && known_ints[b] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end

          when ShiftSubOp::Srl.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              shamt = known_ints[b] & 31
              val = ((known_ints[a].to_u32) >> shamt).to_i32
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif known_ints.has_key?(b) && known_ints[b] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end

          when ShiftSubOp::Sra.value
            if known_ints.has_key?(a) && known_ints.has_key?(b)
              shamt = known_ints[b] & 31
              val = known_ints[a] >> shamt
              result[idx] = Instruction.encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Int16.value, dst, (val & 0xFFFF).to_u16)
              known_ints[dst] = val
            elsif known_ints.has_key?(b) && known_ints[b] == 0
              result[idx] = Instruction.encode_rrr(Opcode::Move, MoveSubOp::Move32.value, dst, a, 0_u8)
              if known_ints.has_key?(a)
                known_ints[dst] = known_ints[a]
              else
                known_ints.delete(dst)
              end
            else
              known_ints.delete(dst)
            end
          else
            known_ints.delete(dst)
          end

        when Opcode::Call, Opcode::CallNative, Opcode::FiberOp, Opcode::Ps2Hw, Opcode::InlineAsm
          known_ints.clear

        when Opcode::Jump, Opcode::BranchZ, Opcode::BranchCmp, Opcode::LoopDecBr
          known_ints.clear

        else
          known_ints.delete(inst.dst)
        end
      end

      result
    end

    private def run_peephole_fusion(instructions : Array(Instruction)) : Array(Instruction)
      return instructions if instructions.size < 2
      result = instructions.dup
      jump_targets = collect_jump_targets(instructions)
      known_ints = Hash(UInt8, Int32).new

      i = 0
      while i < result.size - 1
        inst1 = result[i]
        inst2 = result[i + 1]

        # Track known integer constants for loop decrement checks
        if inst1.opcode == Opcode::LoadImm
          case inst1.subop
          when LoadImmSubOp::Int16.value
            raw_val = inst1.imm16.to_i32
            known_ints[inst1.dst] = raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val
          when LoadImmSubOp::UInt16.value
            known_ints[inst1.dst] = inst1.imm16.to_i32
          when LoadImmSubOp::Zero.value, LoadImmSubOp::Nil.value
            known_ints[inst1.dst] = 0
          when LoadImmSubOp::MinusOne.value
            known_ints[inst1.dst] = -1
          end
        end

        # Do not fuse if instruction 2 is an explicit jump target
        if jump_targets.includes?(i + 1)
          i += 1
          next
        end

        # 1. Compare-and-Branch Fusion: OP_COMPARE + OP_BRANCH_Z -> OP_BRANCH_CMP
        if inst1.opcode == Opcode::Compare && inst2.opcode == Opcode::BranchZ
          cmp_dst = inst1.dst
          branch_cond = inst2.dst
          if cmp_dst == branch_cond && inst1.subop <= CompareSubOp::Ge.value
            offset = inst2.branch_offset
            if offset >= -128 && offset <= 127
              cmp_op = inst1.subop
              fused_cmp : BranchCmpSubOp? = nil

              if inst2.subop == BranchZSubOp::Truthy.value
                fused_cmp = BranchCmpSubOp.from_value(cmp_op)
              elsif inst2.subop == BranchZSubOp::Falsy.value
                # Invert comparison condition
                fused_cmp = case CompareSubOp.from_value(cmp_op)
                            when CompareSubOp::Eq then BranchCmpSubOp::Bne
                            when CompareSubOp::Ne then BranchCmpSubOp::Beq
                            when CompareSubOp::Lt then BranchCmpSubOp::Bge
                            when CompareSubOp::Le then BranchCmpSubOp::Bgt
                            when CompareSubOp::Gt then BranchCmpSubOp::Ble
                            when CompareSubOp::Ge then BranchCmpSubOp::Blt
                            else nil
                            end
              end

              if fused_cmp
                result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
                result[i + 1] = Instruction.encode_branch_cmp(fused_cmp, inst1.a, inst1.b, offset.to_i8)
                i += 2
                next
              end
            end
          end
        end

        # 2. Loop Decrement & Branch Fusion: OP_SUB(reg, 1) + OP_BRANCH_Z -> OP_LOOP_DEC_BR
        if inst1.opcode == Opcode::Sub && inst2.opcode == Opcode::BranchZ
          reg = inst1.dst
          is_dec_one = (inst1.a == reg) && ((known_ints.has_key?(inst1.b) && known_ints[inst1.b] == 1) || (inst1.subop == SubSubOp::SubImm8.value && inst1.b == 1_u8))
          if is_dec_one && inst2.dst == reg
            mode : LoopDecBrSubOp? = nil
            if inst2.subop == BranchZSubOp::Nonzero.value || inst2.subop == BranchZSubOp::Pos.value
              mode = LoopDecBrSubOp::DecBrNz
            elsif inst2.subop == BranchZSubOp::Zero.value || inst2.subop == BranchZSubOp::Neg.value
              mode = LoopDecBrSubOp::DecBrGez
            end

            if mode
              result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
              result[i + 1] = Instruction.encode_loop_dec_br(mode, reg, inst2.branch_offset)
              i += 2
              next
            end
          end
        end

        # 3. Fused Multiply-Accumulate: OP_MUL + OP_ADD -> OP_FUSED_MADD
        if inst1.opcode == Opcode::Mul && inst2.opcode == Opcode::Add
          prod_reg = inst1.dst
          add_dst = inst2.dst
          if (inst2.a == prod_reg && inst2.b == add_dst) || (inst2.b == prod_reg && inst2.a == add_dst)
            result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
            result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::MaddI32, add_dst, inst1.a, inst1.b)
            i += 2
            next
          end
        end

        # 4. Fused Multiply-Subtract: OP_MUL + OP_SUB -> OP_FUSED_MADD (MsubI32)
        if inst1.opcode == Opcode::Mul && inst2.opcode == Opcode::Sub
          prod_reg = inst1.dst
          sub_dst = inst2.dst
          if inst2.a == sub_dst && inst2.b == prod_reg
            result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
            result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::MsubI32, sub_dst, inst1.a, inst1.b)
            i += 2
            next
          end
        end

        # 5. Fused Float MADD & MSUB: OP_FLOAT_ALU(Mul) + OP_FLOAT_ALU(Add/Sub) -> OP_FUSED_MADD
        if inst1.opcode == Opcode::FloatAlu && inst1.subop == FloatAluSubOp::Fmul.value && inst2.opcode == Opcode::FloatAlu
          prod_reg = inst1.dst
          float_dst = inst2.dst
          if inst2.subop == FloatAluSubOp::Fadd.value && ((inst2.a == prod_reg && inst2.b == float_dst) || (inst2.b == prod_reg && inst2.a == float_dst))
            result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
            result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::MaddF32, float_dst, inst1.a, inst1.b)
            i += 2
            next
          elsif inst2.subop == FloatAluSubOp::Fsub.value && (inst2.a == float_dst && inst2.b == prod_reg)
            result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
            result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::MsubF32, float_dst, inst1.a, inst1.b)
            i += 2
            next
          end
        end

        # 6. Fused Vector2 Dot Product: OP_VEC2_MATH(Mul) + OP_FLOAT_ALU(Add)/OP_ADD -> OP_FUSED_MADD (DotProductVec2)
        if inst1.opcode == Opcode::Vec2Math && inst1.subop == Vec2MathSubOp::Mul.value
          prod_reg = inst1.dst
          if inst2.opcode == Opcode::FloatAlu && inst2.subop == FloatAluSubOp::Fadd.value
            dot_dst = inst2.dst
            if (inst2.a == prod_reg && inst2.b == dot_dst) || (inst2.b == prod_reg && inst2.a == dot_dst)
              result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
              result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::DotProductVec2, dot_dst, inst1.a, inst1.b)
              i += 2
              next
            end
          elsif inst2.opcode == Opcode::Add
            dot_dst = inst2.dst
            if (inst2.a == prod_reg && inst2.b == dot_dst) || (inst2.b == prod_reg && inst2.a == dot_dst)
              result[i] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
              result[i + 1] = Instruction.encode_fused_madd(FusedMaddSubOp::DotProductVec2, dot_dst, inst1.a, inst1.b)
              i += 2
              next
            end
          end
        end

        i += 1
      end

      result
    end

    private def run_dead_code_elimination(instructions : Array(Instruction)) : Array(Instruction)
      result = instructions.dup
      jump_targets = collect_jump_targets(instructions)

      dead = false
      result.each_with_index do |inst, idx|
        if jump_targets.includes?(idx)
          dead = false
        end

        # Redundant unconditional jump to the immediately following instruction
        if inst.opcode == Opcode::Jump
          target = if inst.subop == JumpSubOp::JumpRel24.value
                     idx + 1 + inst.jump_offset24
                   else
                     idx + 1 + inst.branch_offset.to_i32
                   end
          if target == idx + 1
            result[idx] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
            next
          end
        end

        if dead
          result[idx] = Instruction.encode_rrr(Opcode::Sys, SysSubOp::Nop.value, 0_u8, 0_u8, 0_u8)
        elsif inst.opcode == Opcode::Return || inst.opcode == Opcode::Jump
          dead = true
        end
      end

      result
    end

    private def run_nop_compaction(instructions : Array(Instruction)) : Array(Instruction)
      has_nops = instructions.any? { |i| i.opcode == Opcode::Sys && i.subop == SysSubOp::Nop.value }
      return instructions unless has_nops

      # Map old indices to new indices
      new_indices = Array(Int32).new(instructions.size, -1)
      cur = 0
      instructions.each_with_index do |inst, old_idx|
        is_nop = (inst.opcode == Opcode::Sys && inst.subop == SysSubOp::Nop.value)
        if !is_nop
          new_indices[old_idx] = cur
          cur += 1
        end
      end

      compacted = Array(Instruction).new(cur)

      instructions.each_with_index do |inst, old_idx|
        is_nop = (inst.opcode == Opcode::Sys && inst.subop == SysSubOp::Nop.value)
        next if is_nop

        case inst.opcode
        when Opcode::Jump
          old_target = if inst.subop == JumpSubOp::JumpRel24.value
                         old_idx + 1 + inst.jump_offset24
                       else
                         old_idx + 1 + inst.branch_offset.to_i32
                       end

          while old_target < instructions.size && old_target >= 0 && new_indices[old_target] == -1
            old_target += 1
          end

          new_target = if old_target >= instructions.size
                         cur
                       elsif old_target < 0
                         0
                       else
                         new_indices[old_target]
                       end

          new_pc = new_indices[old_idx] + 1
          if inst.subop == JumpSubOp::JumpRel24.value
            new_offset = new_target - new_pc
            compacted << Instruction.encode_jump_rel24(new_offset)
          else
            new_offset = (new_target - new_pc).to_i16
            compacted << Instruction.encode_branch_rel(Opcode::Jump, inst.subop, inst.dst, new_offset)
          end

        when Opcode::BranchZ
          old_target = old_idx + 1 + inst.branch_offset.to_i32
          while old_target < instructions.size && old_target >= 0 && new_indices[old_target] == -1
            old_target += 1
          end

          new_target = if old_target >= instructions.size
                         cur
                       elsif old_target < 0
                         0
                       else
                         new_indices[old_target]
                       end

          new_pc = new_indices[old_idx] + 1
          new_offset = (new_target - new_pc).to_i16
          compacted << Instruction.encode_branch_rel(Opcode::BranchZ, inst.subop, inst.dst, new_offset)

        when Opcode::BranchCmp
          old_target = old_idx + 1 + inst.offset8.to_i32
          while old_target < instructions.size && old_target >= 0 && new_indices[old_target] == -1
            old_target += 1
          end

          new_target = if old_target >= instructions.size
                         cur
                       elsif old_target < 0
                         0
                       else
                         new_indices[old_target]
                       end

          new_pc = new_indices[old_idx] + 1
          new_offset = (new_target - new_pc).to_i8
          compacted << Instruction.encode_branch_cmp(inst.subop, inst.dst, inst.a, new_offset)

        when Opcode::LoopDecBr
          old_target = old_idx + 1 + inst.branch_offset.to_i32
          while old_target < instructions.size && old_target >= 0 && new_indices[old_target] == -1
            old_target += 1
          end

          new_target = if old_target >= instructions.size
                         cur
                       elsif old_target < 0
                         0
                       else
                         new_indices[old_target]
                       end

          new_pc = new_indices[old_idx] + 1
          new_offset = (new_target - new_pc).to_i16
          compacted << Instruction.encode_loop_dec_br(inst.subop, inst.dst, new_offset)

        else
          compacted << inst
        end
      end

      compacted
    end

    private def collect_jump_targets(instructions : Array(Instruction)) : Set(Int32)
      targets = Set(Int32).new
      instructions.each_with_index do |inst, idx|
        case inst.opcode
        when Opcode::Jump
          target = if inst.subop == JumpSubOp::JumpRel24.value
                     idx + 1 + inst.jump_offset24
                   else
                     idx + 1 + inst.branch_offset.to_i32
                   end
          targets.add(target) if target >= 0 && target <= instructions.size

        when Opcode::BranchZ, Opcode::LoopDecBr
          target = idx + 1 + inst.branch_offset.to_i32
          targets.add(target) if target >= 0 && target <= instructions.size

        when Opcode::BranchCmp
          target = idx + 1 + inst.offset8.to_i32
          targets.add(target) if target >= 0 && target <= instructions.size
        end
      end
      targets
    end
  end
end
