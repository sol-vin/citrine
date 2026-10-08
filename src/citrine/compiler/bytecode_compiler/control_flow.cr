require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_main_loop(
      call_node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      ctx_name : String? = nil
      if named = call_node.named_args
        named.each do |na|
          if na.name == "context"
            ctx_name = extract_name(na.value)
          end
        end
      end
      if ctx_name.nil? && call_node.args.size > 0
        ctx_name = extract_name(call_node.args.first)
      end
      if ctx_name.nil?
        if (p = @program) && p.vm_contexts.size > 0
          ctx_name = p.vm_contexts.keys.first
        else
          ctx_name = "default"
        end
      end

      # Context switch native call before loop starts
      ctx_id = @program.try(&.vm_contexts[ctx_name]?.try(&.id)) || 1_u16
      subsys_mask = compute_subsys_mask(ctx_name)

      ctx_reg = allocator.alloc_temp
      mask_reg = allocator.alloc_temp
      instructions << Instruction.encode_load_int(ctx_reg, ctx_id.to_u16)
      instructions << Instruction.encode_load_int(mask_reg, (subsys_mask & 0xFFFF_u32).to_u16)
      instructions << Instruction.encode_call_native(ctx_reg, 2_u8, NativeId::ContextSet.value)
      allocator.free_temp(ctx_reg)
      allocator.free_temp(mask_reg)

      old_loop_ctx = @active_loop_context
      old_in_loop = @in_main_loop
      @active_loop_context = ctx_name
      @in_main_loop = true

      loop_break_jumps = [] of Int32
      @loop_break_jumps.push(loop_break_jumps)

      loop_start_offset = instructions.size

      # Check window_open?
      cond_reg = allocator.alloc_temp
      native_id = NativeId::WindowOpen.value
      instructions << Instruction.encode_call_native(cond_reg, 0_u8, native_id)

      # Branch if false to exit
      jump_exit_idx = instructions.size
      instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

      # Body
      body = call_node.block.not_nil!.body
      body_reg = compile_node(body, allocator, instructions, fn)
      allocator.free_temp(body_reg)

      # Loop back
      loop_end_offset = instructions.size
      back_offset = (loop_start_offset - loop_end_offset - 1).to_i16
      instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

      # Patch exit jump
      exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
      instructions[jump_exit_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
      allocator.free_temp(cond_reg)

      # Patch all break / exit jumps!
      loop_break_jumps.each do |j_idx|
        b_offset = (instructions.size - j_idx - 1).to_i16
        instructions[j_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, b_offset)
      end
      @loop_break_jumps.pop

      @active_loop_context = old_loop_ctx
      @in_main_loop = old_in_loop

      ret_reg = allocator.alloc_temp
      instructions << Instruction.encode_load_nil(ret_reg)
      ret_reg
    end

    private def compile_case(
      node : Crystal::Case,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      exit_jumps = [] of Int32

      if cond = node.cond
        cond_reg = compile_node(cond, allocator, instructions, fn)

        node.whens.each do |w|
          body_jump_patches = [] of Int32
          next_when_jump_patches = [] of Int32

          w.conds.each_with_index do |c, c_idx|
            is_last_cond = (c_idx == w.conds.size - 1)

            case c
            when Crystal::RangeLiteral
              from_reg = compile_node(c.from, allocator, instructions, fn)
              to_reg = compile_node(c.to, allocator, instructions, fn)

              ge_reg = allocator.alloc_temp
              instructions << Instruction.encode_cmp(CompareSubOp::Ge, ge_reg, cond_reg, from_reg)

              le_reg = allocator.alloc_temp
              if c.exclusive?
                instructions << Instruction.encode_cmp(CompareSubOp::Lt, le_reg, cond_reg, to_reg)
              else
                instructions << Instruction.encode_cmp(CompareSubOp::Le, le_reg, cond_reg, to_reg)
              end

              range_match = allocator.alloc_temp
              instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::And.value, range_match, ge_reg, le_reg)
              allocator.free_temp(from_reg)
              allocator.free_temp(to_reg)
              allocator.free_temp(ge_reg)
              allocator.free_temp(le_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(range_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(range_match, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(range_match)

            when Crystal::Path, Crystal::Generic, Crystal::Union
              target_types = [] of String
              if c.is_a?(Crystal::Union)
                c.types.each { |t| target_types << t.to_s }
              else
                target_types << c.to_s
              end
              target_ids = [] of UInt32
              target_types.each do |tname|
                if tid = resolve_type_id(tname)
                  matching = @classes.values.select { |cl| cl.ancestor_ids(@classes).includes?(tid) }.map(&.class_id)
                  if matching.empty?
                    target_ids << tid
                  else
                    target_ids.concat(matching)
                  end
                end
              end
              target_ids.uniq!

              type_match = allocator.alloc_temp
              if target_ids.empty?
                instructions << Instruction.encode_load_bool(type_match, false)
              elsif target_ids.size == 1
                tid_reg = allocator.alloc_temp
                instructions << Instruction.encode_load_int(tid_reg, target_ids[0].to_u16)
                seq_base = allocator.alloc_contiguous(2)
                instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                instr_val = Instruction.call_native_raw(type_match, seq_base, NativeId::TypeIsA)
                instructions << Instruction.new(instr_val)
                allocator.free_temp(tid_reg)
                allocator.free_temp(seq_base)
                allocator.free_temp((seq_base + 1).to_u8)
              else
                instructions << Instruction.encode_load_bool(type_match, false)
                tid_jump_ends = [] of Int32
                target_ids.each do |tid|
                  tid_reg = allocator.alloc_temp
                  instructions << Instruction.encode_load_int(tid_reg, tid.to_u16)
                  seq_base = allocator.alloc_contiguous(2)
                  instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                  instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                  cur_check = allocator.alloc_temp
                  instr_val = Instruction.call_native_raw(cur_check, seq_base, NativeId::TypeIsA)
                  instructions << Instruction.new(instr_val)
                  allocator.free_temp(tid_reg)
                  allocator.free_temp(seq_base)
                  allocator.free_temp((seq_base + 1).to_u8)

                  j_next = instructions.size
                  instructions << Instruction.encode_jump_if_false(cur_check, 0_i16)
                  instructions << Instruction.encode_load_bool(type_match, true)
                  j_done = instructions.size
                  instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
                  tid_jump_ends << j_done
                  instructions[j_next] = Instruction.encode_jump_if_false(cur_check, (instructions.size - j_next - 1).to_i16)
                  allocator.free_temp(cur_check)
                end
                tid_end_pos = instructions.size
                tid_jump_ends.each do |tje|
                  instructions[tje] = Instruction.encode_branch(Opcode::Jump, 0_u8, (tid_end_pos - tje - 1).to_i16)
                end
              end

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(type_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(type_match, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(type_match)

            else
              val_reg = compile_node(c, allocator, instructions, fn)
              eq_reg = allocator.alloc_temp
              instructions << Instruction.encode_cmp(CompareSubOp::Eq, eq_reg, cond_reg, val_reg)
              allocator.free_temp(val_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(eq_reg, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(eq_reg, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(eq_reg)
            end
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_jump_if_true(instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_jump_if_false(instructions[np].dst, (after_pos - np - 1).to_i16)
          end
        end

        allocator.free_temp(cond_reg)
      else
        # Condition-less case
        node.whens.each do |w|
          body_jump_patches = [] of Int32
          next_when_jump_patches = [] of Int32

          w.conds.each_with_index do |c, c_idx|
            is_last = (c_idx == w.conds.size - 1)
            cond_res = compile_node(c, allocator, instructions, fn)
            if is_last
              j = instructions.size
              instructions << Instruction.encode_jump_if_false(cond_res, 0_i16)
              next_when_jump_patches << j
            else
              j = instructions.size
              instructions << Instruction.encode_jump_if_true(cond_res, 0_i16)
              body_jump_patches << j
            end
            allocator.free_temp(cond_res)
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_jump_if_true(instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_jump_if_false(instructions[np].dst, (after_pos - np - 1).to_i16)
          end
        end
      end

      if el = node.else
        if !el.is_a?(Crystal::Nop)
          el_reg = compile_node(el, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, el_reg, 0_u8)
          allocator.free_temp(el_reg)
        else
          instructions << Instruction.encode_load_nil(dest)
        end
      else
        instructions << Instruction.encode_load_nil(dest)
      end

      end_pos = instructions.size
      exit_jumps.each do |ej|
        instructions[ej] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - ej - 1).to_i16)
      end

      dest
    end
  end
end
