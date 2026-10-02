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

      # Pass 2: Dead Code Elimination (unreachable instructions after Return/Jump)
      insts = run_dead_code_elimination(insts)

      # Pass 3: NOP Compaction & Jump Offset Fixup
      insts = run_nop_compaction(insts)

      insts
    end

    private def run_constant_folding(instructions : Array(Instruction)) : Array(Instruction)
      result = instructions.dup
      jump_targets = collect_jump_targets(instructions)
      known_ints = Hash(UInt8, Int32).new

      result.each_with_index do |inst, idx|
        # Invalidate known registers if this instruction is a jump target
        if jump_targets.includes?(idx)
          known_ints.clear
        end

        case inst.opcode
        when Opcode::LoadInt
          raw_val = inst.imm16.to_i32
          val = raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val
          known_ints[inst.dst] = val

        when Opcode::Move
          if inst.dst == inst.a
            # Redundant self-move: Move R, R -> NOP
            result[idx] = Instruction.encode_abc(Opcode::Nop, 0_u8, 0_u8, 0_u8)
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
              result[idx] = Instruction.encode_ab_imm(Opcode::LoadInt, dst, (sum & 0xFFFF).to_u16)
              known_ints[dst] = sum
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 0
            # x + 0 -> Move dst, x
            result[idx] = Instruction.encode_abc(Opcode::Move, dst, a, 0_u8)
            if known_ints.has_key?(a)
              known_ints[dst] = known_ints[a]
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(a) && known_ints[a] == 0
            # 0 + x -> Move dst, x
            result[idx] = Instruction.encode_abc(Opcode::Move, dst, b, 0_u8)
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
              result[idx] = Instruction.encode_ab_imm(Opcode::LoadInt, dst, (diff & 0xFFFF).to_u16)
              known_ints[dst] = diff
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 0
            # x - 0 -> Move dst, x
            result[idx] = Instruction.encode_abc(Opcode::Move, dst, a, 0_u8)
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
              result[idx] = Instruction.encode_ab_imm(Opcode::LoadInt, dst, (prod & 0xFFFF).to_u16)
              known_ints[dst] = prod
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(b) && known_ints[b] == 1
            # x * 1 -> Move dst, x
            result[idx] = Instruction.encode_abc(Opcode::Move, dst, a, 0_u8)
            if known_ints.has_key?(a)
              known_ints[dst] = known_ints[a]
            else
              known_ints.delete(dst)
            end
          elsif known_ints.has_key?(a) && known_ints[a] == 1
            # 1 * x -> Move dst, x
            result[idx] = Instruction.encode_abc(Opcode::Move, dst, b, 0_u8)
            if known_ints.has_key?(b)
              known_ints[dst] = known_ints[b]
            else
              known_ints.delete(dst)
            end
          elsif (known_ints.has_key?(b) && known_ints[b] == 0) || (known_ints.has_key?(a) && known_ints[a] == 0)
            # x * 0 -> LoadInt dst, 0
            result[idx] = Instruction.encode_ab_imm(Opcode::LoadInt, dst, 0_u16)
            known_ints[dst] = 0
          else
            known_ints.delete(dst)
          end

        when Opcode::Call, Opcode::CallNative, Opcode::Yield, Opcode::ResumeFiber, Opcode::SpawnFiber
          # External side effects: clear all known values
          known_ints.clear

        when Opcode::Jump, Opcode::JumpIfTrue, Opcode::JumpIfFalse
          known_ints.clear

        else
          # Any other instruction modifying dst
          known_ints.delete(inst.dst)
        end
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

        if dead
          result[idx] = Instruction.encode_abc(Opcode::Nop, 0_u8, 0_u8, 0_u8)
        elsif inst.opcode == Opcode::Return || inst.opcode == Opcode::Jump
          dead = true
        end
      end

      result
    end

    private def run_nop_compaction(instructions : Array(Instruction)) : Array(Instruction)
      has_nops = instructions.any? { |i| i.opcode == Opcode::Nop }
      return instructions unless has_nops

      # Map old indices to new indices
      new_indices = Array(Int32).new(instructions.size, -1)
      cur = 0
      instructions.each_with_index do |inst, old_idx|
        if inst.opcode != Opcode::Nop
          new_indices[old_idx] = cur
          cur += 1
        end
      end

      compacted = Array(Instruction).new(cur)

      instructions.each_with_index do |inst, old_idx|
        next if inst.opcode == Opcode::Nop

        case inst.opcode
        when Opcode::Jump, Opcode::JumpIfTrue, Opcode::JumpIfFalse
          old_target = old_idx + 1 + inst.branch_offset.to_i32
          # If target was a NOP, find next valid instruction
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
          compacted << Instruction.encode_branch(inst.opcode, inst.dst, new_offset)
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
        when Opcode::Jump, Opcode::JumpIfTrue, Opcode::JumpIfFalse
          target = idx + 1 + inst.branch_offset.to_i32
          targets.add(target) if target >= 0 && target <= instructions.size
        end
      end
      targets
    end
  end
end
