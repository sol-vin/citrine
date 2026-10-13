require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_memory_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String,
    ) : UInt8?
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
                    when "write_byte"     then NativeId::MemoryIOWriteByte
                    when "write", "print" then NativeId::MemoryIOWrite
                    when "puts"           then NativeId::MemoryIOPuts
                    when "to_s"           then NativeId::MemoryIOToS
                    when "rewind"         then NativeId::MemoryIORewind
                    when "pos"            then NativeId::MemoryIOPos
                    when "clear"          then NativeId::MemoryIOClear
                    else                       nil
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

      # Pointer(T).open(size) do |ptr| ... end - block-scoped automatic memory reclamation (RAII)
      if obj_str.starts_with?("Pointer") && node.name == "open" && (block = node.block)
        size_reg = if node.args.size > 0
                     compile_node(node.args[0], allocator, instructions, fn)
                   else
                     r = allocator.alloc_temp
                     instructions << Instruction.encode_load_int(r, 1_u16)
                     r
                   end
        ptr_reg = allocator.alloc_temp
        instr_val = Instruction.call_native_raw(ptr_reg, size_reg, NativeId::PointerMalloc)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(size_reg)

        old_local_reg : UInt8? = nil
        old_var_type : String? = nil
        block_arg_name : String? = nil

        if block_arg = block.args.first?
          block_arg_name = block_arg.name
          old_local_reg = allocator.local_map[block_arg.name]?
          old_var_type = @var_types[block_arg.name]?
          allocator.local_map[block_arg.name] = ptr_reg
          @var_types[block_arg.name] = "Pointer"
        end

        body_dest = compile_node(block.body, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, body_dest, 0_u8) if body_dest

        if b_name = block_arg_name
          if orig_r = old_local_reg
            allocator.local_map[b_name] = orig_r
          else
            allocator.local_map.delete(b_name)
          end
          if orig_t = old_var_type
            @var_types[b_name] = orig_t
          else
            @var_types.delete(b_name)
          end
        end

        # Automatic deallocation at block exit
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        free_val = Instruction.call_native_raw(allocator.alloc_temp, seq_base, NativeId::PointerFree)
        instructions << Instruction.new(free_val)
        allocator.free_temp(seq_base)
        allocator.free_temp(ptr_reg)
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
                  else                             arg_node.to_s
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
                  else                             arg_node.to_s
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
                  else                             arg_node.to_s
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

      nil
    end
  end
end
