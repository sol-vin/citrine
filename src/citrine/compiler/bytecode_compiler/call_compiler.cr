require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
    ) : UInt8
      dest = allocator.alloc_temp

      if node.name == "asm" && (node.obj.nil? || node.obj.to_s == "Citrine")
        asm_lines = [] of String
        node.args.each do |arg|
          if arg.is_a?(Crystal::StringLiteral)
            asm_lines << arg.value
          elsif arg.is_a?(Crystal::StringInterpolation)
            text = String.build do |sb|
              arg.expressions.each do |piece|
                sb << piece.value if piece.is_a?(Crystal::StringLiteral)
              end
            end
            asm_lines << text
          elsif arg.is_a?(Crystal::NumberLiteral)
            asm_lines << arg.value
          else
            compile_error("asm arguments must be string or numeric literals (e.g. asm(\"sync.l\") or asm(0x0000000F))", arg)
          end
        end

        assembled_words = [] of UInt32
        asm_lines.each do |block_text|
          begin
            words = Citrine::MIPS::Assembler.assemble(block_text)
            assembled_words.concat(words)
          rescue ex
            compile_error("Inline assembly syntax error: #{ex.message}", node)
          end
        end

        if assembled_words.empty?
          instructions << Instruction.encode_load_int(dest, 0_u16)
        else
          assembled_words.each_with_index do |word, idx|
            const_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: word.to_i32!, uint_val: word))
            is_last = (idx == assembled_words.size - 1)
            target_dest = is_last ? dest : 0_u8
            instructions << Instruction.encode_ab_imm(Opcode::InlineAsm, target_dest, const_idx.to_u16)
          end
        end
        return dest
      end

      obj_str = node.obj ? node.obj.to_s : ""

      if node.name == "boot_screen" && (obj_str.empty? || obj_str == "Citrine")
        val = node.args.first?.try(&.to_s)
        if val == "false"
          add_string("citrine:boot_screen:false")
        else
          add_string("citrine:boot_screen:true")
        end
        dest = allocator.alloc_temp
        instructions << Instruction.encode_load_nil(dest)
        return dest
      end

      if @in_main_loop
        if node.name == "exit" && (obj_str.empty? || obj_str == "Citrine")
          if @loop_break_jumps.size > 0
            dest = allocator.alloc_temp
            j = instructions.size
            instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
            @loop_break_jumps.last << j
            instructions << Instruction.encode_load_nil(dest)
            return dest
          end
        end
        if (node.name == "switch_context" || node.name == "set_vm_context") && (obj_str.empty? || obj_str == "Citrine")
          compile_error("Safety Error: Cannot switch context inside active main_loop! Exit the loop first.", node)
        end
        if (node.name == "context" || node.name == "vm_context" || node.name == "make_vm_context") && (obj_str.empty? || obj_str == "Citrine")
          compile_error("Compile Error: Context definitions cannot be placed inside main_loop.", node)
        end
        if active_ctx = @active_loop_context
          validate_context_subsystem_call(obj_str, node.name, active_ctx, node)
        end
      end

      is_collection_push = obj_str.downcase.includes?("arr") || obj_str.downcase.includes?("list") ||
                           obj_str.downcase.includes?("io") || obj_str.downcase.includes?("buf") ||
                           (node.obj.is_a?(Crystal::Var) && @var_types[node.obj.as(Crystal::Var).name]?.try { |t| t.starts_with?("Array") || t.includes?("IO") }) ||
                           node.obj.is_a?(Crystal::ArrayLiteral) || node.args.first?.is_a?(Crystal::StringLiteral) ||
                           (node.name == "<<" && node.args.first?.try { |arg| !arg.is_a?(Crystal::NumberLiteral) && !(arg.is_a?(Crystal::Var) && @var_types[arg.as(Crystal::Var).name]? == "Int") })

      if ["+", "-", "*", "/", "//", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&*", "&+", "&-"].includes?(node.name) && node.obj && node.args.size == 1 && !(node.name == "<<" && is_collection_push)
        is_string_add = (node.name == "+") && (
          node.obj.is_a?(Crystal::StringLiteral) || node.obj.is_a?(Crystal::StringInterpolation) ||
          node.args[0].is_a?(Crystal::StringLiteral) || node.args[0].is_a?(Crystal::StringInterpolation) ||
          (node.obj.is_a?(Crystal::Var) && @var_types[node.obj.as(Crystal::Var).name]? == "String") ||
          (node.args[0].is_a?(Crystal::Var) && @var_types[node.args[0].as(Crystal::Var).name]? == "String") ||
          (node.obj.is_a?(Crystal::Call) && node.obj.as(Crystal::Call).name == "to_s") ||
          (node.args[0].is_a?(Crystal::Call) && node.args[0].as(Crystal::Call).name == "to_s")
        )
        if is_string_add
          left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          right_reg = compile_node(node.args[0], allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, left_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, right_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::StringConcat)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(left_reg)
          allocator.free_temp(right_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end

        if (node.name == "/" || node.name == "//" || node.name == "%") && node.args[0].is_a?(Crystal::NumberLiteral)
          num_str = node.args[0].as(Crystal::NumberLiteral).value
          if num_str == "0" || num_str == "0.0"
            compile_error("Division by zero is undefined", node)
          end
        end

        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        op, subop = case node.name
                    when "+", "&+" then {Opcode::Add, AddSubOp::AddI32.value}
                    when "-", "&-" then {Opcode::Sub, SubSubOp::SubI32.value}
                    when "*", "&*" then {Opcode::Mul, MulSubOp::MulLo.value}
                    when "/", "//" then {Opcode::DivMod, DivModSubOp::DivS32.value}
                    when "%"       then {Opcode::DivMod, DivModSubOp::ModS32.value}
                    when "&"       then {Opcode::Bitwise, BitwiseSubOp::And.value}
                    when "|"       then {Opcode::Bitwise, BitwiseSubOp::Or.value}
                    when "^"       then {Opcode::Bitwise, BitwiseSubOp::Xor.value}
                    when "<<"      then {Opcode::Shift, ShiftSubOp::Sll.value}
                    when ">>"      then {Opcode::Shift, ShiftSubOp::Sra.value}
                    when "=="      then {Opcode::Compare, CompareSubOp::Eq.value}
                    when "!="      then {Opcode::Compare, CompareSubOp::Ne.value}
                    when "<"       then {Opcode::Compare, CompareSubOp::Lt.value}
                    when "<="      then {Opcode::Compare, CompareSubOp::Le.value}
                    when ">"       then {Opcode::Compare, CompareSubOp::Gt.value}
                    when ">="      then {Opcode::Compare, CompareSubOp::Ge.value}
                    else                {Opcode::Add, AddSubOp::AddI32.value}
                    end
        instructions << Instruction.encode_rrr(op, subop, dest, left_reg, right_reg)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        return dest
      elsif node.name == "!" && node.obj
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_bool(false_reg, false)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        return dest
      elsif node.name == "nil?" && node.obj
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        nil_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_nil(nil_reg)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, obj_reg, nil_reg)
        allocator.free_temp(obj_reg)
        allocator.free_temp(nil_reg)
        return dest
      elsif node.name == "not_nil!" && node.obj
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
        allocator.free_temp(obj_reg)
        return dest
      elsif node.name == "-" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_rrr(Opcode::Sub, SubSubOp::NegI32.value, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      elsif node.name == "~" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Nor.value, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      elsif node.name == "clamp" && node.obj && node.args.size == 2
        val_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        min_reg = compile_node(node.args[0], allocator, instructions, fn)
        max_reg = compile_node(node.args[1], allocator, instructions, fn)

        instructions << Instruction.encode_abc(Opcode::Move, dest, val_reg, 0_u8)

        # If dest < min_reg -> dest = min_reg
        cmp_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cmp_reg, dest, min_reg)
        skip_min_j = instructions.size
        instructions << Instruction.encode_branch(Opcode::BranchZ, cmp_reg, 0_i16)
        instructions << Instruction.encode_abc(Opcode::Move, dest, min_reg, 0_u8)
        instructions[skip_min_j] = Instruction.encode_branch(Opcode::BranchZ, cmp_reg, (instructions.size - skip_min_j - 1).to_i16)

        # If dest > max_reg -> dest = max_reg
        instructions << Instruction.encode_cmp(CompareSubOp::Gt, cmp_reg, dest, max_reg)
        skip_max_j = instructions.size
        instructions << Instruction.encode_branch(Opcode::BranchZ, cmp_reg, 0_i16)
        instructions << Instruction.encode_abc(Opcode::Move, dest, max_reg, 0_u8)
        instructions[skip_max_j] = Instruction.encode_branch(Opcode::BranchZ, cmp_reg, (instructions.size - skip_max_j - 1).to_i16)

        allocator.free_temp(cmp_reg)
        allocator.free_temp(max_reg)
        allocator.free_temp(min_reg)
        allocator.free_temp(val_reg)
        return dest
      end

      # Number conversions: .to_i, .to_i32, .to_i64, .to_u8, .to_u16, .to_u32, .to_u64, .to_f, .to_f32, .to_f64
      if ["to_i", "to_i32", "to_i64", "to_u8", "to_u16", "to_u32", "to_u64", "to_f", "to_f32", "to_f64"].includes?(node.name) && node.obj && node.args.empty?
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        if ["to_i", "to_i32", "to_i64", "to_u8", "to_u16", "to_u32", "to_u64"].includes?(node.name)
          instructions << Instruction.encode_abc(Opcode::FloatAlu, dest, obj_reg, 0_u8, subop: FloatAluSubOp::FcvtSW.value)
        else
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
        end
        allocator.free_temp(obj_reg)
        return dest
      end

      # Main loop
      if node.name == "main_loop" && (obj_str.empty? || obj_str == "Citrine") && node.block
        loop_ret = compile_main_loop(node, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, loop_ret, 0_u8)
        allocator.free_temp(loop_ret)
        return dest
      end

      # Concurrency: spawn
      if (node.name == "spawn" || ((obj_str == "Citrine" || obj_str == "Fiber") && node.name == "spawn")) && node.block
        return compile_spawn(node, allocator, instructions, fn)
      end

      # Concurrency calls (yield, Channel.new, send, receive, try_receive, size, capacity)
      if conc_dest = compile_concurrency_call(node, allocator, instructions, fn, dest, obj_str)
        return conc_dest
      end

      # Controller and Input Action calls
      if ctrl_dest = compile_controller_call(node, allocator, instructions, fn, dest, obj_str)
        return ctrl_dest
      end

      # Native API Calls (Citrine.draw_rectangle, GL.begin, etc.)
      is_gl_obj = obj_str == "Citrine::GL" || obj_str == "GL"
      is_pad_obj = obj_str == "Citrine" || obj_str.empty? || is_gl_obj || obj_str.includes?("VirtualPad") || obj_str.includes?("VU0") || obj_str.includes?("Audio") || obj_str.includes?("Compute") || obj_str.includes?("Shader") || obj_str.includes?("Draw2D") || obj_str.includes?("Draw3D")
      if is_pad_obj
        if native_id = map_native_call(node.name, is_gl_obj)
          validate_native_call_arity(native_id, node.name, node.args.size, node)

          if (native_id == NativeId::ButtonPressed || native_id == NativeId::ButtonDown || native_id == NativeId::ButtonReleased)
            if node.args.size != 2
              compile_error("Citrine.#{node.name} requires explicit port and button: Citrine.#{node.name}(port, button), Citrine.player(port).#{node.name}(button), or Action.is_pressed?(action)", node)
            end
            check_port_literal(node.args[0], node.name, node)
          elsif native_id == NativeId::GetAnalog
            check_port_literal(node.args[0], "get_analog", node)
            if node.args[1].is_a?(Crystal::NumberLiteral)
              axis_val = node.args[1].as(Crystal::NumberLiteral).value.to_i?
              if axis_val.nil? || axis_val < 0 || axis_val > 3
                compile_error("Invalid analog axis #{node.args[1].as(Crystal::NumberLiteral).value}. Valid axes are 0 (LX), 1 (LY), 2 (RX), 3 (RY).", node)
              end
            end
          elsif native_id == NativeId::SetRumble
            check_port_literal(node.args[0], "set_rumble", node)
          end

          if @release_mode && (native_id == NativeId::Log || native_id == NativeId::DebugLog || native_id == NativeId::SetDebugOverlay)
            instructions << Instruction.encode_load_nil(dest)
            return dest
          end

          # Compile args into sequential registers
          arg_regs = node.args.map { |a| compile_node(a, allocator, instructions, fn) }
          base_reg = if arg_regs.empty?
                       0_u8
                     elsif arg_regs.size == 1
                       arg_regs[0]
                     elsif (0...arg_regs.size - 1).all? { |i| arg_regs[i + 1] == arg_regs[i] + 1 }
                       arg_regs[0]
                     else
                       seq_base = allocator.alloc_contiguous(arg_regs.size)
                       arg_regs.each_with_index do |src, i|
                         dst = (seq_base + i).to_u8
                         instructions << Instruction.encode_abc(Opcode::Move, dst, src, 0_u8)
                       end
                       seq_base
                     end

          # Instruction: OP_CALL_NATIVE dest, base_reg, argc | imm16: native_id
          instr_val = Instruction.call_native_raw(dest, base_reg, native_id)
          instructions << Instruction.new(instr_val)
          arg_regs.each { |r| allocator.free_temp(r) }
          if !arg_regs.empty? && base_reg != arg_regs[0]
            arg_regs.size.times do |i|
              allocator.free_temp((base_reg + i).to_u8)
            end
          end
          return dest
        end
      end

      # Vector2 constructors & properties
      if obj_str == "Vector2" && node.name == "new"
        x_reg = compile_node(node.args[0], allocator, instructions, fn)
        y_reg = compile_node(node.args[1], allocator, instructions, fn)
        instructions << Instruction.encode_vec2_new(dest, x_reg, y_reg)
        allocator.free_temp(x_reg)
        allocator.free_temp(y_reg)
        return dest
      end

      # Color constructors: Color.new(r, g, b, a = 255) or Color.new(packed_u32)
      if (obj_str == "Color" || obj_str == "Citrine::Color") && node.name == "new"
        if node.args.size == 1 && node.args[0].is_a?(Crystal::NumberLiteral)
          num_str = node.args[0].as(Crystal::NumberLiteral).value.gsub("_", "")
          val = if num_str.starts_with?("0x") || num_str.starts_with?("0X")
                  num_str[2..-1].to_u32?(16) || 0_u32
                else
                  num_str.to_u32? || 0_u32
                end
          c_idx = add_constant(ConstValue.new(ConstType::Color, uint_val: val))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, c_idx.to_u16)
          return dest
        end

        all_literals = node.args.all? { |a| a.is_a?(Crystal::NumberLiteral) }
        if all_literals
          parse_u8 = ->(arg : Crystal::ASTNode?, default_val : UInt8) : UInt8 {
            if arg.is_a?(Crystal::NumberLiteral)
              clean = arg.value.gsub(/[^0-9]/, "")
              clean.to_u8? || default_val
            else
              default_val
            end
          }
          r = parse_u8.call(node.args[0]?, 0_u8)
          g = parse_u8.call(node.args[1]?, 0_u8)
          b = parse_u8.call(node.args[2]?, 0_u8)
          a = node.args.size >= 4 ? parse_u8.call(node.args[3]?, 255_u8) : 255_u8
          packed = ColorVal.new(r, g, b, a).to_u32
          c_idx = add_constant(ConstValue.new(ConstType::Color, uint_val: packed))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, c_idx.to_u16)
          return dest
        else
          r_reg = node.args.size > 0 ? compile_node(node.args[0], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          g_reg = node.args.size > 1 ? compile_node(node.args[1], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          b_reg = node.args.size > 2 ? compile_node(node.args[2], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          a_reg = node.args.size > 3 ? compile_node(node.args[3], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 255_u16)
            t
          end

          shift8 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift8, 8_u16)
          g_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, g_sh, g_reg, shift8)

          shift16 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift16, 16_u16)
          b_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, b_sh, b_reg, shift16)

          shift24 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift24, 24_u16)
          a_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, a_sh, a_reg, shift24)

          t1 = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, t1, r_reg, g_sh)
          t2 = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, t2, t1, b_sh)
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, dest, t2, a_sh)

          allocator.free_temp(r_reg)
          allocator.free_temp(g_reg)
          allocator.free_temp(b_reg)
          allocator.free_temp(a_reg)
          allocator.free_temp(shift8)
          allocator.free_temp(g_sh)
          allocator.free_temp(shift16)
          allocator.free_temp(b_sh)
          allocator.free_temp(shift24)
          allocator.free_temp(a_sh)
          allocator.free_temp(t1)
          allocator.free_temp(t2)
          return dest
        end
      end

      has_class_method = @functions.any? { |f| f.name.ends_with?("##{node.name}") }
      if !has_class_method
        if node.name == "x" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_vec2_get_x(dest, obj_reg)
          return dest
        elsif node.name == "y" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_vec2_get_y(dest, obj_reg)
          return dest
        elsif node.name == "x=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_vec2_set_x(obj_reg, val_reg)
          return obj_reg
        elsif node.name == "y=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_vec2_set_y(obj_reg, val_reg)
          return obj_reg
        end
      end

      # Memory Calls (IO::Memory, Pointer, Box, Context arenas, GC, Memory stats)
      if mem_dest = compile_memory_call(node, allocator, instructions, fn, dest, obj_str)
        return mem_dest
      end

      # Collection Calls (arrays, ranges, static arrays, map, select, each)
      if coll_dest = compile_collection_call(node, allocator, instructions, fn, dest, obj_str)
        return coll_dest
      end

      # String Calls (Regex, string helpers, Enums, to_s)
      if str_dest = compile_string_call(node, allocator, instructions, fn, dest, obj_str)
        return str_dest
      end

      # Object-Oriented Calls (Classes, super, instance methods, properties, free functions)
      compile_oop_call(node, allocator, instructions, fn, dest, obj_str)
    end
  end
end
