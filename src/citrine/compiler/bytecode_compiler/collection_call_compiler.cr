require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_collection_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String,
    ) : UInt8?
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
        is_io = (io_obj = node.obj) && (
          (io_obj.is_a?(Crystal::Var) && @var_types[io_obj.name]?.try { |t| t.includes?("Memory") || t.includes?("IO") }) ||
          (io_obj.is_a?(Crystal::Call) && io_obj.name == "new" && io_obj.obj.to_s.includes?("Memory")) ||
          (io_obj.is_a?(Crystal::Var) && (io_obj.name.downcase.includes?("mem") || io_obj.name.downcase.includes?("io")))
        )
        unless is_io
          arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArrayClear)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(arr_reg)
          return dest
        end
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

      nil
    end
  end
end
