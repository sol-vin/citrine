require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_controller_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction,
      dest : UInt8,
      obj_str : String
    ) : UInt8?
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
                    when "button_released?" then NativeId::ButtonReleased
                    else                         nil
                    end
        if native_id
          instr_val = Instruction.call_native_raw(dest, seq_base, native_id)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(ctrl_reg)
          allocator.free_temp(btn_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end
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

      nil
    end
  end
end
