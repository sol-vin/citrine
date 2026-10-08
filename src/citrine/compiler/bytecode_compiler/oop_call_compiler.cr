require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_oop_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String
    ) : UInt8?
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
  end
end
