require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_string_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String
    ) : UInt8?
      # Enum.new(val) constructor
      if node.name == "new" && @enums.has_key?(obj_str) && node.args.size > 0
        arg_reg = compile_node(node.args.first, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, arg_reg, 0_u8)
        allocator.free_temp(arg_reg)
        return dest
      end

      # .to_s on any value/expression
      if node.name == "to_s" && node.args.empty? && node.obj
        obj = node.obj.not_nil!
        if obj.is_a?(Crystal::StringLiteral)
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        elsif obj.is_a?(Crystal::Var) && @var_types[obj.name]? == "String"
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        else
          hint = 0_u16
          if obj.is_a?(Crystal::BoolLiteral) || (obj.is_a?(Crystal::Var) && @var_types[obj.name]? == "Bool")
            hint = 2_u16
          end
          val_reg = compile_node(obj, allocator, instructions, fn)
          res_reg = emit_to_string(val_reg, hint, allocator, instructions)
          instructions << Instruction.encode_abc(Opcode::Move, dest, res_reg, 0_u8)
          allocator.free_temp(res_reg)
          return dest
        end
      end

      # Regex.new(pattern)
      if (obj_str == "Regex" || obj_str.ends_with?("::Regex")) && node.name == "new" && node.args.size > 0
        pat_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, pat_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::RegexNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(pat_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # Regex match / =~ operator: regex =~ str or str =~ regex
      if node.name == "=~" && node.obj && node.args.size == 1
        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, left_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, right_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::RegexMatch)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Regex#matches? or Regex#match
      if (node.name == "matches?" || node.name == "match") && node.obj && node.args.size == 1
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        str_reg = compile_node(node.args[0], allocator, instructions, fn)
        match_pos = allocator.alloc_temp
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, obj_reg, 0_u8)
        instr_val = Instruction.call_native_raw(match_pos, seq_base, NativeId::RegexMatch)
        instructions << Instruction.new(instr_val)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instructions << Instruction.encode_cmp(CompareSubOp::Ge, dest, match_pos, zero_reg)
        allocator.free_temp(obj_reg)
        allocator.free_temp(str_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        allocator.free_temp(match_pos)
        allocator.free_temp(zero_reg)
        return dest
      end

      # String helper methods: strip, downcase, upcase
      if ["strip", "downcase", "upcase"].includes?(node.name) && node.obj && node.args.empty?
        s_op = case node.name
               when "strip" then NativeId::StringStrip
               when "downcase" then NativeId::StringDowncase
               when "upcase" then NativeId::StringUpcase
               else NativeId::StringStrip
               end
        str_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, s_op)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(str_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # String helper methods: starts_with?, ends_with?, includes?, split
      if ["starts_with?", "ends_with?", "includes?", "split"].includes?(node.name) && node.obj
        s_op = case node.name
               when "starts_with?" then NativeId::StringStartsWith
               when "ends_with?" then NativeId::StringEndsWith
               when "includes?" then NativeId::StringIncludes
               when "split" then NativeId::StringSplit
               else NativeId::StringIncludes
               end
        str_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        arg_reg = if node.args.size > 0
                    compile_node(node.args[0], allocator, instructions, fn)
                  else
                    sp_reg = allocator.alloc_temp
                    sp_idx = add_string(" ")
                    c_idx = add_constant(ConstValue.new(ConstType::String, int_val: sp_idx, str_val: " "))
                    instructions << Instruction.encode_ab_imm(Opcode::LoadConst, sp_reg, c_idx.to_u16)
                    sp_reg
                  end
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, arg_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, s_op)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(str_reg)
        allocator.free_temp(arg_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      nil
    end
  end
end
