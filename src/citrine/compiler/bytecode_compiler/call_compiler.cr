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
      fn : CompiledFunction
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
                    else {Opcode::Add, AddSubOp::AddI32.value}
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

      # Concurrency: yield
      if node.name == "yield" && (obj_str.empty? || obj_str == "Citrine" || obj_str == "Fiber")
        instructions << Instruction.encode_yield
        return dest
      end

      # Concurrency: Channel.new(cap)
      if (obj_str.includes?("Channel") || node.name == "channel_new") && (node.name == "new" || node.name == "channel_new")
        cap_reg = if node.args.size > 0
                    compile_node(node.args[0], allocator, instructions, fn)
                  else
                    r = allocator.alloc_temp
                    instructions << Instruction.encode_load_int(r, 32_u16)
                    r
                  end
        instr_val = Instruction.call_native_raw(dest, cap_reg, NativeId::ChannelNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cap_reg)
        return dest
      end

      # Concurrency: ch.send(val)
      if node.name == "send" && node.obj && node.args.size == 1
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        arg0 = allocator.alloc_temp
        arg1 = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, arg0, ch_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, arg1, val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, arg0, NativeId::ChannelSend)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        allocator.free_temp(val_reg)
        allocator.free_temp(arg0)
        allocator.free_temp(arg1)
        return dest
      end

      # Concurrency: ch.receive
      if node.name == "receive" && node.obj
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelReceive)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.try_receive
      if node.name == "try_receive" && node.obj
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelTryReceive)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.size / ch.count
      is_chan = obj_str.downcase.includes?("chan") || (node.obj.is_a?(Crystal::Var) && @var_types[node.obj.as(Crystal::Var).name]?.try(&.downcase.includes?("chan")) == true)
      if is_chan && node.obj && (node.name == "size" || node.name == "count") && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelCount)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.capacity
      if is_chan && node.name == "capacity" && node.obj && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelCapacity)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Controller handles: Citrine.player(port) or Citrine.pad(port)
      if (obj_str == "Citrine" || obj_str.empty?) && (node.name == "player" || node.name == "pad")
        if node.args.size != 1
          compile_error("Citrine.#{node.name} requires exactly 1 argument: (port)", node)
        end
        check_port_literal(node.args[0], node.name, node)
        port_reg = compile_node(node.args[0], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, port_reg, 0_u8)
        allocator.free_temp(port_reg)
        return dest
      end

      # Controller Method Calls on Controller instance (e.g. p1.button_pressed?(Button::Cross))
      if (node.name == "button_pressed?" || node.name == "button_down?" || node.name == "button_released?") && node.obj && obj_str != "Citrine" && !obj_str.includes?("VirtualPad")
        if node.args.size != 1
          compile_error("Controller##{node.name} requires exactly 1 argument: (button)", node)
        end
        ctrl_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        btn_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ctrl_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, btn_reg, 0_u8)
        native_id = case node.name
                    when "button_pressed?"  then NativeId::ButtonPressed
                    when "button_down?"     then NativeId::ButtonDown
                    else                         NativeId::ButtonReleased
                    end
        instr_val = Instruction.call_native_raw(dest, seq_base, native_id)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctrl_reg)
        allocator.free_temp(btn_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Godot-style InputMap Action queries (Action.is_pressed?, Action.is_down?, Action.is_released?)
      if (obj_str == "Action" || obj_str == "Citrine::Action")
        if ["is_pressed?", "is_down?", "is_released?", "is_action_just_pressed", "is_action_pressed", "is_action_just_released"].includes?(node.name)
          if node.args.size != 1
            compile_error("Action.#{node.name} requires exactly 1 argument: (action)", node)
          end
          act_reg = compile_node(node.args[0], allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(1)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, act_reg, 0_u8)
          native_id = case node.name
                      when "is_pressed?", "is_action_just_pressed" then NativeId::ActionPressed
                      when "is_down?", "is_action_pressed"         then NativeId::ActionDown
                      when "is_released?", "is_action_just_released" then NativeId::ActionReleased
                      else                                         nil
                      end
          if native_id
            instr_val = Instruction.call_native_raw(dest, seq_base, native_id)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(act_reg)
            allocator.free_temp(seq_base)
            return dest
          end
        end
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


      # times loop: e.g. 10.times do |i| ... end
      if node.name == "times" && node.obj && (block = node.block)
        count_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        if block_arg = block.args.first?
          allocator.allocate_local(block_arg.name)
          local_iter = allocator.get_local(block_arg.name).not_nil!
        else
          local_iter = iter_reg
        end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, count_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Assign block arg
        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        # iter += 1
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
        return dest
      end

      # Array / Pointer index read: arr[idx], arr[idx]? or ptr[idx]
      if (node.name == "[]" || node.name == "[]?") && node.obj && node.args.size == 1
        bracket_recv_type = if node.obj.is_a?(Crystal::Var)
                              @var_types[node.obj.as(Crystal::Var).name]?
                            elsif node.obj.is_a?(Crystal::InstanceVar)
                              @var_types[node.obj.as(Crystal::InstanceVar).name]?
                            elsif node.obj.is_a?(Crystal::Path)
                              node.obj.as(Crystal::Path).names.last
                            elsif node.obj.is_a?(Crystal::Call) && (c = node.obj.as(Crystal::Call))
                              if (c.name == "new" || c.name == "malloc") && c.obj.to_s.includes?("Pointer")
                                "Pointer"
                              else
                                nil
                              end
                            else
                              nil
                            end

        if bracket_recv_type
          clean_vtype = bracket_recv_type.split("(").first.strip
          clean_vtype = clean_vtype[2..-1] if clean_vtype.starts_with?("::")
          if clean_vtype.starts_with?("Pointer")
            ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
            idx_reg = compile_node(node.args[0], allocator, instructions, fn)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
            instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerGet)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(ptr_reg)
            allocator.free_temp(idx_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)
            return dest
          end

          custom_bracket_method = nil
          if !clean_vtype.starts_with?("Array") && !clean_vtype.starts_with?("StaticArray")
            cands = [clean_vtype, clean_vtype.split("::").last]
            cands.each do |c|
              if @functions.any? { |f| f.name == "#{c}##{node.name}" }
                custom_bracket_method = "#{c}##{node.name}"
                break
              end
            end
          end

          if custom_bracket_method && (f_idx = @functions.index { |f| f.name == custom_bracket_method })
            obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
            call_base = allocator.alloc_call_frame(node.args.size + 2)
            dest_call = call_base
            instructions << Instruction.encode_abc(Opcode::Move, (dest_call + 1).to_u8, obj_reg, 0_u8)
            allocator.free_temp(obj_reg)
            node.args.each_with_index do |arg, i|
              arg_reg = compile_node(arg, allocator, instructions, fn)
              target_reg = (dest_call + 2_u8 + i.to_u8).to_u8
              instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
              allocator.free_temp(arg_reg)
            end
            instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, f_idx.to_u16)
            (node.args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
            instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
            allocator.free_temp(dest_call)
            return dest
          end
        end

        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        idx_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array / Pointer index write: arr[idx] = val or ptr[idx] = val
      if node.name == "[]=" && node.obj && node.args.size == 2
        bracket_recv_type = if node.obj.is_a?(Crystal::Var)
                              @var_types[node.obj.as(Crystal::Var).name]?
                            elsif node.obj.is_a?(Crystal::InstanceVar)
                              @var_types[node.obj.as(Crystal::InstanceVar).name]?
                            elsif node.obj.is_a?(Crystal::Path)
                              node.obj.as(Crystal::Path).names.last
                            elsif node.obj.is_a?(Crystal::Call) && (c = node.obj.as(Crystal::Call))
                              if (c.name == "new" || c.name == "malloc") && c.obj.to_s.includes?("Pointer")
                                "Pointer"
                              else
                                nil
                              end
                            else
                              nil
                            end

        if bracket_recv_type
          clean_vtype = bracket_recv_type.split("(").first.strip
          clean_vtype = clean_vtype[2..-1] if clean_vtype.starts_with?("::")
          if clean_vtype.starts_with?("Pointer")
            ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
            idx_reg = compile_node(node.args[0], allocator, instructions, fn)
            val_reg = compile_node(node.args[1], allocator, instructions, fn)
            seq_base = allocator.alloc_contiguous(3)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
            instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerSet)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(ptr_reg)
            allocator.free_temp(idx_reg)
            allocator.free_temp(val_reg)
            3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
            return dest
          end
        end

        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        idx_reg = compile_node(node.args[0], allocator, instructions, fn)
        val_reg = compile_node(node.args[1], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArraySet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(val_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
        return dest
      end

      # Array push: arr << val or arr.push(val)
      if (node.name == "push" || node.name == "<<") && node.obj && node.args.size == 1
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayPush)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(val_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array pop: arr.pop
      if node.name == "pop" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArrayPop)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array size: arr.size / arr.length
      if (node.name == "size" || node.name == "length") && node.obj && node.args.empty?
        has_custom_size = false
        sz_recv_type = if node.obj.is_a?(Crystal::Var)
                         @var_types[node.obj.as(Crystal::Var).name]?
                       elsif node.obj.is_a?(Crystal::InstanceVar)
                         @var_types[node.obj.as(Crystal::InstanceVar).name]?
                       elsif node.obj.is_a?(Crystal::Path)
                         node.obj.as(Crystal::Path).names.last
                       else
                         nil
                       end
        if sz_recv_type
          clean_recv = sz_recv_type.split("(").first.strip
          clean_recv = clean_recv[2..-1] if clean_recv.starts_with?("::")
          if !clean_recv.starts_with?("Array") && !clean_recv.starts_with?("StaticArray")
            cands = [clean_recv, clean_recv.split("::").last]
            cands.each do |c|
              if @functions.any? { |f| f.name == "#{c}##{node.name}" } || @classes[c]?.try(&.methods.has_key?(node.name))
                has_custom_size = true
                break
              end
            end
          end
        end

        unless has_custom_size
          arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArraySize)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(arr_reg)
          return dest
        end
      end

      # Array clear: arr.clear
      if node.name == "clear" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArrayClear)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array first: arr.first
      if node.name == "first" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array last: arr.last
      if node.name == "last" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        sz_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(sz_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        idx_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Sub, idx_reg, sz_reg, one_reg)
        allocator.free_temp(sz_reg)
        allocator.free_temp(one_reg)

        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array empty?: arr.empty?
      if node.name == "empty?" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        sz_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(sz_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, sz_reg, zero_reg)
        allocator.free_temp(arr_reg)
        allocator.free_temp(sz_reg)
        allocator.free_temp(zero_reg)
        return dest
      end

      # Range each: (min..max).each do |i| ... end
      range_target = if node.obj.is_a?(Crystal::RangeLiteral)
                       node.obj.as(Crystal::RangeLiteral)
                     elsif node.obj.is_a?(Crystal::Expressions) && node.obj.as(Crystal::Expressions).expressions.size == 1 && node.obj.as(Crystal::Expressions).expressions.first.is_a?(Crystal::RangeLiteral)
                       node.obj.as(Crystal::Expressions).expressions.first.as(Crystal::RangeLiteral)
                     else
                       nil
                     end

      if node.name == "each" && range_target && (block = node.block)
        range = range_target
        from_reg = compile_node(range.from, allocator, instructions, fn)
        to_reg = compile_node(range.to, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, iter_reg, from_reg, 0_u8)

        local_iter = if block_arg = block.args.first?
                       allocator.allocate_local(block_arg.name)
                       allocator.get_local(block_arg.name).not_nil!
                     else
                       iter_reg
                     end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        if range.exclusive?
          instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, to_reg)
        else
          instructions << Instruction.encode_cmp(CompareSubOp::Le, cond_reg, iter_reg, to_reg)
        end
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
        allocator.free_temp(from_reg)
        allocator.free_temp(to_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)
        return dest
      end

      # Array each: arr.each do |item| ... end
      if node.name == "each" && node.obj && (block = node.block)
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        size_reg = allocator.alloc_temp
        instr_val = Instruction.call_native_raw(size_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(instr_val)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = Instruction.call_native_raw(block_item_reg, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)
        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)
        return dest
      end

      # Array map: arr.map do |x| ... end
      if node.name == "map" && node.obj && (block = node.block)
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        size_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(size_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)

        # Allocate result array
        res_arr = allocator.alloc_temp
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, cap_reg, size_reg, 0_u8)
        new_instr = Instruction.call_native_raw(res_arr, cap_reg, NativeId::ArrayNew)
        instructions << Instruction.new(new_instr)
        allocator.free_temp(cap_reg)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Item = arr[iter]
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = Instruction.call_native_raw(block_item_reg, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        # Evaluate mapped value
        mapped_val_reg = compile_node(block.body, allocator, instructions, fn)

        # Push to res_arr
        push_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, push_base, res_arr, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (push_base + 1).to_u8, mapped_val_reg, 0_u8)
        dummy_dest = allocator.alloc_temp
        push_instr = Instruction.call_native_raw(dummy_dest, push_base, NativeId::ArrayPush)
        instructions << Instruction.new(push_instr)
        allocator.free_temp(mapped_val_reg)
        allocator.free_temp(push_base)
        allocator.free_temp((push_base + 1).to_u8)
        allocator.free_temp(dummy_dest)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)

        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)

        instructions << Instruction.encode_abc(Opcode::Move, dest, res_arr, 0_u8)
        allocator.free_temp(res_arr)
        return dest
      end

      # Array select / find_all: arr.select do |x| ... end
      if (node.name == "select" || node.name == "find_all") && node.obj && (block = node.block)
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        size_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(size_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)

        # Allocate result array
        res_arr = allocator.alloc_temp
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, cap_reg, size_reg, 0_u8)
        new_instr = Instruction.call_native_raw(res_arr, cap_reg, NativeId::ArrayNew)
        instructions << Instruction.new(new_instr)
        allocator.free_temp(cap_reg)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Item = arr[iter]
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = Instruction.call_native_raw(block_item_reg, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        # Evaluate predicate value
        pred_val_reg = compile_node(block.body, allocator, instructions, fn)

        skip_push_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(pred_val_reg, 0_i16)

        # Push to res_arr
        push_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, push_base, res_arr, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (push_base + 1).to_u8, block_item_reg, 0_u8)
        dummy_dest = allocator.alloc_temp
        push_instr = Instruction.call_native_raw(dummy_dest, push_base, NativeId::ArrayPush)
        instructions << Instruction.new(push_instr)
        allocator.free_temp(push_base)
        allocator.free_temp((push_base + 1).to_u8)
        allocator.free_temp(dummy_dest)

        instructions[skip_push_idx] = Instruction.encode_jump_if_false(pred_val_reg, (instructions.size - skip_push_idx - 1).to_i16)
        allocator.free_temp(pred_val_reg)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)

        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)

        instructions << Instruction.encode_abc(Opcode::Move, dest, res_arr, 0_u8)
        allocator.free_temp(res_arr)
        return dest
      end

      # StaticArray.new / StaticArray(...)
      if obj_str.starts_with?("StaticArray") && node.name == "new"
        sz = 4
        if obj_str =~ /\((\w+),\s*(\d+)\)/
          sz = $2.to_i
        end
        sz_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(sz_reg, sz.to_u16)
        def_val_reg = if node.args.size > 0
                        compile_node(node.args[0], allocator, instructions, fn)
                      else
                        r = allocator.alloc_temp
                        instructions << Instruction.encode_load_nil(r)
                        r
                      end
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, sz_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, def_val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::StaticArrayNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(sz_reg)
        allocator.free_temp(def_val_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # IO::Memory.new
      if (obj_str == "IO::Memory" || obj_str.includes?("Memory")) && node.name == "new"
        arg0 = if node.args.size > 0
                 compile_node(node.args[0], allocator, instructions, fn)
               else
                 r = allocator.alloc_temp
                 instructions << Instruction.encode_load_int(r, 64_u16)
                 r
               end
        instr_val = Instruction.call_native_raw(dest, arg0, NativeId::MemoryIONew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arg0)
        return dest
      end

      # IO::Memory methods
      is_io = (io_obj = node.obj) && (
        (io_obj.is_a?(Crystal::Var) && @var_types[io_obj.name]?.try { |t| t.includes?("Memory") || t.includes?("IO") }) ||
        (io_obj.is_a?(Crystal::Call) && io_obj.name == "new" && io_obj.obj.to_s.includes?("Memory")) ||
        (io_obj.is_a?(Crystal::Var) && (io_obj.name.downcase.includes?("mem") || io_obj.name.downcase.includes?("io")))
      )
      if node.obj && is_io && ["to_s", "write_byte", "write", "print", "puts", "rewind", "pos", "clear"].includes?(node.name)
        native_op = case node.name
                    when "write_byte" then NativeId::MemoryIOWriteByte
                    when "write", "print" then NativeId::MemoryIOWrite
                    when "puts" then NativeId::MemoryIOPuts
                    when "to_s" then NativeId::MemoryIOToS
                    when "rewind" then NativeId::MemoryIORewind
                    when "pos" then NativeId::MemoryIOPos
                    when "clear" then NativeId::MemoryIOClear
                    else nil
                    end
        if native_op && (node.name == "to_s" || node.name == "rewind" || node.name == "pos" || node.name == "clear" || !node.args.empty?)
          io_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          if node.args.empty?
            instr_val = Instruction.call_native_raw(dest, io_reg, native_op)
            instructions << Instruction.new(instr_val)
          else
            val_reg = compile_node(node.args[0], allocator, instructions, fn)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, io_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, val_reg, 0_u8)
            instr_val = Instruction.call_native_raw(dest, seq_base, native_op)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(val_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)
          end
          allocator.free_temp(io_reg)
          return dest
        end
      end

      # Pointer value dereference or Enum value getter: ptr.value / enum.value
      if node.name == "value" && node.obj && node.args.empty?
        obj = node.obj.not_nil!
        is_pointer = (obj.is_a?(Crystal::Var) && @var_types[obj.name]?.try(&.starts_with?("Pointer"))) ||
                     (obj.is_a?(Crystal::Call) && obj.name == "malloc")
        if !is_pointer
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        end

        ptr_reg = compile_node(obj, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Pointer value assignment: ptr.value = val
      if node.name == "value=" && node.obj && node.args.size == 1
        ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerSet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(val_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
        return dest
      end

      # Pointer address: ptr.address
      if node.name == "address" && node.obj && node.args.empty?
        ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ptr_reg, NativeId::PointerAddress)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        return dest
      end

      # Pointer(T).malloc(size)
      if obj_str.starts_with?("Pointer") && node.name == "malloc"
        size_reg = if node.args.size > 0
                     compile_node(node.args[0], allocator, instructions, fn)
                   else
                     r = allocator.alloc_temp
                     instructions << Instruction.encode_load_int(r, 1_u16)
                     r
                   end
        instr_val = Instruction.call_native_raw(dest, size_reg, NativeId::PointerMalloc)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(size_reg)
        return dest
      end

      # Pointer(T).new(addr)
      if obj_str.starts_with?("Pointer") && node.name == "new" && node.args.size > 0
        addr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, addr_reg, NativeId::PointerNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(addr_reg)
        return dest
      end

      # Box(T).box(val)
      if obj_str.starts_with?("Box") && node.name == "box" && node.args.size > 0
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, val_reg, NativeId::BoxNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(val_reg)
        return dest
      end

      # Box(T).unbox(ptr)
      if obj_str.starts_with?("Box") && node.name == "unbox" && node.args.size > 0
        ptr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ptr_reg, NativeId::BoxUnbox)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        return dest
      end

      # Context with block auto-cleanup: vm_context(:name) do ... end
      if node.name == "vm_context" && (obj_str.empty? || obj_str == "Citrine") && (block = node.block)
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextSet)
        instructions << Instruction.new(instr_val)

        # Compile body of block inside context
        compile_node(block.body, allocator, instructions, fn)

        # Auto-rewind/clear context arena on block exit
        clear_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextClear)
        instructions << Instruction.new(clear_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Context Clear: clear_vm_context(:name) / reset_vm_context(:name)
      if (node.name == "clear_vm_context" || node.name == "reset_vm_context") && (obj_str.empty? || obj_str == "Citrine")
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextClear)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Memory Stats: Citrine::Memory.stats / Citrine::Memory.heap_bytes / memory_stats
      if ((node.name == "stats" || node.name == "heap_bytes") && obj_str.ends_with?("Memory")) || node.name == "memory_stats"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instr_val = Instruction.call_native_raw(dest, zero_reg, NativeId::MemoryStats)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(zero_reg)
        return dest
      end

      # Context Switch: set_vm_context(:name) / vm_context(:name)
      if (node.name == "set_vm_context" || node.name == "vm_context") && (obj_str.empty? || obj_str == "Citrine")
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextSet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Pointer.free(ptr) or ptr.free
      if (node.name == "free") && ((obj_str.starts_with?("Pointer") && node.args.size > 0) || node.obj)
        ptr_target = (obj_str.starts_with?("Pointer") && node.args.size > 0) ? node.args[0] : node.obj.not_nil!
        ptr_reg = compile_node(ptr_target, allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerFree)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # GC.collect
      if (obj_str == "GC" || obj_str.ends_with?("::GC")) && node.name == "collect"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instr_val = Instruction.call_native_raw(dest, zero_reg, NativeId::GCCycle)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(zero_reg)
        return dest
      end

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

      # Class instantiation: Foo.new(...)
      if @classes.has_key?(obj_str) && node.name == "new"
        cls_info = @classes[obj_str]
        if cls_info.is_abstract
          panic_str = "Cannot instantiate abstract class #{obj_str}"
          s_idx = add_string(panic_str)
          c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: panic_str))
          p_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, p_reg, c_idx.to_u16)
          instr_val = Instruction.call_native_raw(dest, p_reg, NativeId::Panic)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(p_reg)
          return dest
        end
        cid_reg = allocator.alloc_temp
        cnt_reg = allocator.alloc_temp
        is_struct_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(cid_reg, cls_info.class_id.to_u16)
        f_count = cls_info.fields.size > 0 ? cls_info.fields.size : 1
        instructions << Instruction.encode_load_int(cnt_reg, f_count.to_u16)
        instructions << Instruction.encode_load_int(is_struct_reg, cls_info.is_struct ? 1_u16 : 0_u16)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, cid_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, cnt_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, is_struct_reg, 0_u8)
        obj_val = Instruction.call_native_raw(dest, seq_base, NativeId::ObjectNew)
        instructions << Instruction.new(obj_val)
        allocator.free_temp(cid_reg)
        allocator.free_temp(cnt_reg)
        allocator.free_temp(is_struct_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }

        # Call initialize if present
        init_name = "#{obj_str}#initialize"
        if init_idx = @functions.index { |f| f.name == init_name }
          call_base = allocator.alloc_call_frame(node.args.size + 2)
          instructions << Instruction.encode_abc(Opcode::Move, (call_base + 1).to_u8, dest, 0_u8)
          node.args.each_with_index do |arg, i|
            arg_reg = compile_node(arg, allocator, instructions, fn)
            target_reg = (call_base + 2_u8 + i.to_u8).to_u8
            instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
            allocator.free_temp(arg_reg)
          end
          dummy_dest = call_base
          instructions << Instruction.encode_ab_imm(Opcode::Call, dummy_dest, init_idx.to_u16)
          (node.args.size + 1).times { |i| allocator.free_temp((call_base + 1_u8 + i.to_u8).to_u8) }
          allocator.free_temp(dummy_dest)
        end
        return dest
      end

      # Yield / with self yield block inlining
      block_target_name : String? = nil
      if !obj_str.empty?
        @classes.each do |cname, _|
          cand = "#{cname}##{node.name}"
          if @program_defs.has_key?(cand)
            block_target_name = cand
            break
          end
        end
      end
      block_target_name ||= node.name if @program_defs.has_key?(node.name)

      if block_target_name && (def_node = @program_defs[block_target_name]?) && (block = node.block)
        if has_yield_node?(def_node.body)
          return inline_block_call(node, def_node, block, allocator, instructions, fn)
        end
      end

      # Super call: super / super(args...)
      if node.name == "super"
        cls = @current_class
        unless cls && (sc_name = cls.superclass_name)
          compile_error("Cannot call super outside of a subclass method", node)
        end
        m_name = @current_method_name || compile_error("super called outside of a method", node)

        # Look up method in ancestor classes
        super_f_idx : Int32? = nil
        curr_sc : String? = sc_name
        while curr_sc
          cand = "#{curr_sc}##{m_name}"
          if idx = @functions.index { |f| f.name == cand }
            super_f_idx = idx
            break
          end
          curr_sc = @classes[curr_sc]?.try(&.superclass_name)
        end

        unless super_f_idx
          compile_error("super: method '#{m_name}' not found in any superclass of #{cls.name}", node)
        end

        self_reg = @current_self_reg || allocator.get_local("self") || 0_u8

        call_base = allocator.alloc_call_frame(node.args.size + 2)
        instructions << Instruction.encode_abc(Opcode::Move, (call_base + 1).to_u8, self_reg, 0_u8)

        node.args.each_with_index do |arg, i|
          arg_reg = compile_node(arg, allocator, instructions, fn)
          target_reg = (call_base + 2_u8 + i.to_u8).to_u8
          instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
          allocator.free_temp(arg_reg)
        end

        dest_call = call_base
        instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, super_f_idx.to_u16)
        (node.args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
        instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
        allocator.free_temp(dest_call)
        return dest
      end

      # Instance method call: obj.method(args...)
      if node.obj && !node.obj.is_a?(Crystal::Path)
        recv_type : String? = nil
        case recv_node = node.obj
        when Crystal::Var
          if recv_node.name == "self" && @current_class
            recv_type = @current_class.try(&.name)
          else
            recv_type = @var_types[recv_node.name]?
          end
        when Crystal::Self
          if @current_class
            recv_type = @current_class.try(&.name)
          end
        when Crystal::Call
          if (recv_node.name == "new" || recv_node.name == "malloc") && (r_obj = recv_node.obj)
            recv_type = r_obj.to_s
          elsif recv_node.name == "as" && recv_node.args.size > 0
            recv_type = recv_node.args.first.to_s
          end
        when Crystal::Cast
          recv_type = recv_node.to.to_s
        when Crystal::NilableCast
          recv_type = recv_node.to.to_s
        end

        matched_method : String? = nil
        if recv_type
          clean_recv = recv_type.split("(").first.strip
          clean_recv = clean_recv[2..-1] if clean_recv.starts_with?("::")
          curr_cls : String? = clean_recv
          while curr_cls
            cand = "#{curr_cls}##{node.name}"
            if @functions.any? { |f| f.name == cand }
              matched_method = cand
              break
            end
            curr_cls = @classes[curr_cls]?.try(&.superclass_name)
          end
        end

        unless matched_method
          @classes.each do |cname, _|
            cand = "#{cname}##{node.name}"
            if @functions.any? { |f| f.name == cand }
              matched_method = cand
              break
            end
          end
        end

        if matched_method && (f_idx = @functions.index { |f| f.name == matched_method })
          effective_args = node.args.dup
          if def_node = @program_defs[matched_method]?
            raw_params = def_node.args.reject { |a| a.name == "self" }
            if effective_args.size < raw_params.size
              raw_params[effective_args.size..-1].each do |param|
                if def_val = param.default_value
                  effective_args << def_val
                end
              end
            end
          end

          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          call_base = allocator.alloc_call_frame(effective_args.size + 2)
          dest_call = call_base
          instructions << Instruction.encode_abc(Opcode::Move, (dest_call + 1).to_u8, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          effective_args.each_with_index do |arg, i|
            arg_reg = compile_node(arg, allocator, instructions, fn)
            target_reg = (dest_call + 2_u8 + i.to_u8).to_u8
            instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
            allocator.free_temp(arg_reg)
          end
          instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, f_idx.to_u16)
          (effective_args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
          instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
          allocator.free_temp(dest_call)
          return dest
        end
      end

      # Class property getter / setter access
      clean_prop_name = node.name.ends_with?("=") ? node.name[0...-1] : node.name
      prop_cls = obj_str
      prop_offset : Int32? = nil
      while !prop_cls.empty?
        if off = @class_prop_offsets["#{prop_cls}::#{clean_prop_name}"]?
          prop_offset = off
          break
        end
        prop_cls = @classes[prop_cls]?.try(&.superclass_name) || ""
      end

      if prop_offset
        addr_val = CLASS_PROP_BASE + (prop_offset.to_u32 * 4)
        if node.name.ends_with?("=") && node.args.size == 1
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          addr_reg = allocator.alloc_temp
          idx_reg = allocator.alloc_temp
          instructions << Instruction.encode_load_int(idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerSet)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          allocator.free_temp(val_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return dest
        elsif node.args.empty?
          addr_reg = allocator.alloc_temp
          idx_reg = allocator.alloc_temp
          instructions << Instruction.encode_load_int(idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerGet)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end
      end

      # Implicit self instance method call: func(args...) within a class instance method
      if node.obj.nil? && (cls = @current_class) && (self_reg = @current_self_reg)
        self_cls : String? = cls.name
        matched_self_method : String? = nil
        while self_cls
          cand = "#{self_cls}##{node.name}"
          if @functions.any? { |f| f.name == cand }
            matched_self_method = cand
            break
          end
          self_cls = @classes[self_cls]?.try(&.superclass_name)
        end

        if matched_self_method && (f_idx = @functions.index { |f| f.name == matched_self_method })
          call_base = allocator.alloc_call_frame(node.args.size + 2)
          dest_call = call_base
          instructions << Instruction.encode_abc(Opcode::Move, (dest_call + 1).to_u8, self_reg, 0_u8)
          node.args.each_with_index do |arg, i|
            arg_reg = compile_node(arg, allocator, instructions, fn)
            target_reg = (dest_call + 2_u8 + i.to_u8).to_u8
            instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
            allocator.free_temp(arg_reg)
          end
          instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, f_idx.to_u16)
          (node.args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
          instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
          allocator.free_temp(dest_call)
          return dest
        end
      end

      # User function or module function call: func(args...) / Mod.func(args...)
      target_func_name = if !obj_str.empty?
                           "#{obj_str}.#{node.name}"
                         else
                           node.name
                         end

      func_idx = nil
      if !obj_str.empty?
        parts = obj_str.split("::")
        parts.size.times do |i|
          cand_prefix = parts[i..-1].join("::")
          [".", "::"].each do |sep|
            cand_name = "#{cand_prefix}#{sep}#{node.name}"
            if idx = @functions.index { |f| f.name == cand_name }
              func_idx = idx
              break
            end
          end
          break if func_idx
        end
      end

      if (obj_str.empty? || obj_str == "self") && (ns = @current_namespace)
        parts = ns.split("::")
        parts.size.times do |i|
          cand_prefix = parts[0..(parts.size - 1 - i)].join("::")
          [".", "::"].each do |sep|
            cand_name = "#{cand_prefix}#{sep}#{node.name}"
            if idx = @functions.index { |f| f.name == cand_name }
              func_idx = idx
              break
            end
          end
          break if func_idx
        end
      end

      func_idx ||= @functions.index { |f| f.name == target_func_name } ||
                   @functions.index { |f| f.name == "#{obj_str}::#{node.name}" } ||
                   @functions.index { |f| f.name == node.name }

      if func_idx
        func_name = @functions[func_idx].name
        def_node = @program_defs[func_name]? ||
                   @program_defs[node.name]? ||
                   @program_defs[target_func_name]? ||
                   @program_defs["#{obj_str}::#{node.name}"]?

        effective_args = node.args.dup
        if def_node
          raw_params = def_node.args.reject { |a| a.name == "self" }
          if effective_args.size < raw_params.size
            raw_params[effective_args.size..-1].each do |param|
              if def_val = param.default_value
                effective_args << def_val
              end
            end
          end
        end

        call_base = allocator.alloc_call_frame(effective_args.size + 1)
        dest_call = call_base
        effective_args.each_with_index do |arg, i|
          arg_reg = compile_node(arg, allocator, instructions, fn)
          target_reg = (dest_call + 1_u8 + i.to_u8).to_u8
          instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
          allocator.free_temp(arg_reg)
        end
        instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, func_idx.to_u16)
        effective_args.size.times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
        instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
        allocator.free_temp(dest_call)
        return dest
      end

      instructions << Instruction.encode_load_nil(dest)
      dest
    end

    private def compile_spawn(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      block = node.block
      unless block
        instructions << Instruction.encode_load_nil(dest)
        return dest
      end

      captured_vars = [] of String
      collect_free_vars(block.body, allocator, Set(String).new, captured_vars)

      all_arg_names = block.args.map(&.name) + captured_vars
      fiber_fn_name = "__fiber_#{@functions.size}"
      fiber_fn = CompiledFunction.new(fiber_fn_name, all_arg_names.size.to_u8)
      fiber_allocator = RegisterAllocator.new(all_arg_names)
      fiber_instructions = [] of Instruction

      all_arg_names.each_with_index do |name, idx|
        @source_map.record_register(fiber_fn_name, idx, name)
      end

      # Compile fiber body
      ret_reg = compile_node(block.body, fiber_allocator, fiber_instructions, fiber_fn)
      fiber_instructions << Instruction.encode_abc(Opcode::Return, ret_reg, 0_u8, 0_u8)
      fiber_fn.num_registers = fiber_allocator.max_registers
      fiber_fn.instructions = fiber_instructions

      func_idx = @functions.size
      @functions << fiber_fn

      # Evaluate explicit arguments first
      arg_offset = 0
      node.args.each_with_index do |arg, i|
        reg = compile_node(arg, allocator, instructions, fn)
        target_reg = dest + 1_u8 + arg_offset.to_u8
        instructions << Instruction.encode_abc(Opcode::Move, target_reg, reg, 0_u8)
        allocator.free_temp(reg)
        arg_offset += 1
      end

      # Pass captured outer variables
      captured_vars.each do |cvar|
        if outer_reg = allocator.get_local(cvar)
          target_reg = dest + 1_u8 + arg_offset.to_u8
          instructions << Instruction.encode_abc(Opcode::Move, target_reg, outer_reg, 0_u8)
          arg_offset += 1
        end
      end

      instructions << Instruction.encode_spawn_fiber(dest, func_idx.to_u16)
      dest
    end
  end
end
