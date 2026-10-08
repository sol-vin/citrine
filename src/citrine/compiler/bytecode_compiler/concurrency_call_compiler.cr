require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_concurrency_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String
    ) : UInt8?
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

      nil
    end
  end
end
