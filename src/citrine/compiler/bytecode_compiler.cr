require "compiler/crystal/syntax"
require "./opcode"
require "./register_alloc"
require "./source_map"
require "./budget_checker"
require "../ast/types"
require "../parser/dsl_parser"

module Citrine
  class CompiledFunction
    property name : String
    property argc : UInt8
    property num_registers : UInt8
    property code_offset : UInt32 = 0_u32
    property instruction_count : UInt32 = 0_u32
    property instructions : Array(Instruction)

    def initialize(@name : String, @argc : UInt8 = 0_u8)
      @num_registers = @argc
      @instructions = [] of Instruction
    end
  end

  enum ConstType : UInt8
    Nil     = 0
    Bool    = 1
    Int32   = 2
    Float32 = 3
    Vec2    = 4
    Color   = 5
    String  = 6
  end

  struct ConstValue
    getter type : ConstType
    getter int_val : Int32
    getter uint_val : UInt32
    getter float_val : Float32
    getter float_val2 : Float32
    getter str_val : String

    def initialize(
      @type : ConstType,
      @int_val : Int32 = 0,
      @uint_val : UInt32 = 0_u32,
      @float_val : Float32 = 0.0_f32,
      @float_val2 : Float32 = 0.0_f32,
      @str_val : String = ""
    )
    end
  end

  class BytecodeCompiler
    MAGIC = "CBC1"

    getter source_map : SourceMap
    getter constants : Array(ConstValue)
    getter strings : Array(String)
    getter functions : Array(CompiledFunction)
    getter filename : String?

    def initialize(@filename : String? = nil)
      @source_map = SourceMap.new
      @constants = [] of ConstValue
      @strings = [] of String
      @functions = [] of CompiledFunction
    end

    def compile(program : ParsedProgram) : Bytes
      # 1. Compile helper functions / methods
      program.defs.each do |name, def_node|
        compile_function(def_node)
      end

      # 2. Compile main function
      main_fn = CompiledFunction.new("__main__", 0_u8)
      allocator = RegisterAllocator.new
      fn_instructions = [] of Instruction

      # Compile top level nodes
      program.top_level_nodes.each do |node|
        compile_node(node, allocator, fn_instructions, main_fn)
      end

      # Compile main loop if present
      if loop_body = program.main_loop_body
        compile_main_loop(loop_body, allocator, fn_instructions, main_fn)
      end

      # Return at end of main
      ret_reg = allocator.alloc_temp
      fn_instructions << Instruction.encode_abc(Opcode::LoadNil, ret_reg, 0_u8, 0_u8)
      fn_instructions << Instruction.encode_abc(Opcode::Return, ret_reg, 0_u8, 0_u8)
      main_fn.num_registers = allocator.max_registers
      main_fn.instructions = fn_instructions
      @functions << main_fn

      # 3. Assemble binary bytecode (.cbc)
      serialize_bytecode
    end

    private def compile_function(node : Crystal::Def)
      arg_names = node.args.map(&.name)
      fn = CompiledFunction.new(node.name, arg_names.size.to_u8)
      allocator = RegisterAllocator.new(arg_names)
      instructions = [] of Instruction

      arg_names.each_with_index do |name, idx|
        @source_map.record_register(node.name, idx, name)
      end

      # Compile function body
      ret_reg = compile_node(node.body, allocator, instructions, fn)
      instructions << Instruction.encode_abc(Opcode::Return, ret_reg, 0_u8, 0_u8)

      fn.num_registers = allocator.max_registers
      fn.instructions = instructions
      @functions << fn
    end

    private def compile_main_loop(
      body : Crystal::ASTNode,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    )
      loop_start_offset = instructions.size

      # Check window_open?
      cond_reg = allocator.alloc_temp
      native_id = NativeId::WindowOpen.value
      instructions << Instruction.encode_ab_imm(Opcode::CallNative, cond_reg, native_id)

      # Branch if false to exit
      jump_exit_idx = instructions.size
      instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

      # Body
      body_reg = compile_node(body, allocator, instructions, fn)
      allocator.free_temp(body_reg)

      # Loop back
      loop_end_offset = instructions.size
      back_offset = (loop_start_offset - loop_end_offset - 1).to_i16
      instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

      # Patch exit jump
      exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
      instructions[jump_exit_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)
      allocator.free_temp(cond_reg)
    end

    private def compile_node(
      node : Crystal::ASTNode,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      record_location(node, instructions.size, fn.name)

      case node
      when Crystal::Expressions
        last_reg = 0_u8
        node.expressions.each_with_index do |child, idx|
          reg = compile_node(child, allocator, instructions, fn)
          if idx == node.expressions.size - 1
            last_reg = reg
          else
            allocator.free_temp(reg)
          end
        end
        last_reg

      when Crystal::Assign
        target_name = node.target.to_s
        val_reg = compile_node(node.value, allocator, instructions, fn)
        local_reg = allocator.allocate_local(target_name)
        instructions << Instruction.encode_abc(Opcode::Move, local_reg, val_reg, 0_u8)
        @source_map.record_register(fn.name, local_reg.to_i32, target_name)
        allocator.free_temp(val_reg)
        local_reg

      when Crystal::Var
        name = node.name
        if reg = allocator.get_local(name)
          reg
        else
          # Unknown local, allocate
          reg = allocator.allocate_local(name)
          instructions << Instruction.encode_abc(Opcode::LoadNil, reg, 0_u8, 0_u8)
          reg
        end

      when Crystal::NumberLiteral
        dest = allocator.alloc_temp
        if node.kind == :i32 || node.kind == :i64 || node.value.includes?(".") == false
          val = node.value.to_i32
          if val >= -32768 && val <= 32767
            instructions << Instruction.encode_ab_imm(Opcode::LoadInt, dest, val.to_u16)
          else
            const_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: val))
            instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
          end
        else
          fval = node.value.to_f32
          const_idx = add_constant(ConstValue.new(ConstType::Float32, float_val: fval))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        end
        dest

      when Crystal::StringLiteral
        dest = allocator.alloc_temp
        str_idx = add_string(node.value)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: node.value))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest

      when Crystal::BoolLiteral
        dest = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, dest, node.value ? 1_u16 : 0_u16)
        dest

      when Crystal::NilLiteral
        dest = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest

      when Crystal::And
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Or
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfTrue, dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_branch(Opcode::JumpIfTrue, dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Not
        dest = allocator.alloc_temp
        inner_reg = compile_node(node.exp, allocator, instructions, fn)
        # Not: if true -> false, if false -> true
        # Compare with false/nil
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, false_reg, 0_u16)
        instructions << Instruction.encode_abc(Opcode::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        dest

      when Crystal::If
        dest = allocator.alloc_temp
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_else_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        # Then branch
        then_reg = compile_node(node.then, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, then_reg, 0_u8)
        allocator.free_temp(then_reg)
        jump_end_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

        # Patch else
        else_target_offset = (instructions.size - jump_else_idx - 1).to_i16
        instructions[jump_else_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, else_target_offset)

        # Else branch
        if node.else && !node.else.is_a?(Crystal::Nop)
          else_reg = compile_node(node.else, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, else_reg, 0_u8)
          allocator.free_temp(else_reg)
        end

        # Patch end
        end_offset = (instructions.size - jump_end_idx - 1).to_i16
        instructions[jump_end_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, end_offset)

        allocator.free_temp(cond_reg)
        dest

      when Crystal::While
        dest = allocator.alloc_temp
        loop_start = instructions.size
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_exit_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        compile_node(node.body, allocator, instructions, fn)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
        instructions[jump_exit_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)

        allocator.free_temp(cond_reg)
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest

      when Crystal::Call
        compile_call(node, allocator, instructions, fn)

      when Crystal::Path
        # Constant reference e.g. Button::Cross, Color::Red
        dest = allocator.alloc_temp
        val = resolve_constant_path(node)
        const_idx = add_constant(val)
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest

      else
        dest = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest
      end
    end

    private def compile_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      # Binary and Unary Operators
      if ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">="].includes?(node.name) && node.obj && node.args.size == 1
        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        op = case node.name
             when "+" then Opcode::Add
             when "-" then Opcode::Sub
             when "*" then Opcode::Mul
             when "/" then Opcode::Div
             when "%" then Opcode::Mod
             when "==" then Opcode::Eq
             when "!=" then Opcode::Ne
             when "<" then Opcode::Lt
             when "<=" then Opcode::Le
             when ">" then Opcode::Gt
             when ">=" then Opcode::Ge
             else Opcode::Add
             end
        instructions << Instruction.encode_abc(op, dest, left_reg, right_reg)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        return dest
      elsif node.name == "!" && node.obj
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, false_reg, 0_u16)
        instructions << Instruction.encode_abc(Opcode::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        return dest
      elsif node.name == "-" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Neg, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      end

      # Native API Calls (Citrine.draw_rectangle, etc.)
      obj_str = node.obj ? node.obj.to_s : ""
      if obj_str == "Citrine" || obj_str.empty?
        if native_id = map_native_call(node.name)
          # Compile args into sequential registers
          arg_regs = node.args.map { |a| compile_node(a, allocator, instructions, fn) }
          base_reg = arg_regs.first? || 0_u8

          # Instruction: OP_CALL_NATIVE dest, base_reg, argc | imm16: native_id
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (base_reg.to_u32 << 8) |
                      native_id.value.to_u32
          instructions << Instruction.new(instr_val)
          arg_regs.each { |r| allocator.free_temp(r) }
          return dest
        end

        if node.name == "spawn" && node.block
          # Fiber spawning
          # TODO: compile block as separate function
          instructions << Instruction.encode_abc(Opcode::SpawnFiber, dest, 0_u8, 0_u8)
          return dest
        elsif node.name == "yield"
          instructions << Instruction.encode_abc(Opcode::Yield, 0_u8, 0_u8, 0_u8)
          return dest
        end
      end

      # Vector2 constructors & properties
      if obj_str == "Vector2" && node.name == "new"
        x_reg = compile_node(node.args[0], allocator, instructions, fn)
        y_reg = compile_node(node.args[1], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2New, dest, x_reg, y_reg)
        allocator.free_temp(x_reg)
        allocator.free_temp(y_reg)
        return dest
      end

      if node.name == "x" && node.obj
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2GetX, dest, obj_reg, 0_u8)
        return dest
      elsif node.name == "y" && node.obj
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2GetY, dest, obj_reg, 0_u8)
        return dest
      elsif node.name == "x=" && node.obj && node.args.size > 0
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2SetX, obj_reg, val_reg, 0_u8)
        return obj_reg
      elsif node.name == "y=" && node.obj && node.args.size > 0
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2SetY, obj_reg, val_reg, 0_u8)
        return obj_reg
      end

      # times loop: e.g. 10.times do |i| ... end
      if node.name == "times" && node.obj && (block = node.block)
        count_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, iter_reg, 0_u16)

        if block_arg = block.args.first?
          allocator.allocate_local(block_arg.name)
          local_iter = allocator.get_local(block_arg.name).not_nil!
        else
          local_iter = iter_reg
        end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Lt, cond_reg, iter_reg, count_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        # Assign block arg
        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        # iter += 1
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)
        return dest
      end

      # General call to user function
      arg_regs = node.args.map { |a| compile_node(a, allocator, instructions, fn) }
      base_reg = arg_regs.first? || 0_u8
      func_idx = @functions.index { |f| f.name == node.name } || 0
      instructions << Instruction.encode_abc(Opcode::Call, dest, base_reg, node.args.size.to_u8)
      dest
    end

    private def map_native_call(name : String) : NativeId?
      case name
      when "init_window" then NativeId::InitWindow
      when "close_window" then NativeId::CloseWindow
      when "window_open?" then NativeId::WindowOpen
      when "set_target_fps" then NativeId::SetTargetFPS
      when "get_fps" then NativeId::GetFPS
      when "get_delta_time" then NativeId::GetDeltaTime
      when "begin_drawing" then NativeId::BeginDrawing
      when "end_drawing" then NativeId::EndDrawing
      when "clear_background" then NativeId::ClearBackground
      when "draw_rectangle" then NativeId::DrawRectangle
      when "draw_circle" then NativeId::DrawCircle
      when "draw_line" then NativeId::DrawLine
      when "draw_triangle" then NativeId::DrawTriangle
      when "draw_text" then NativeId::DrawText
      when "load_texture" then NativeId::LoadTexture
      when "draw_texture" then NativeId::DrawTexture
      when "draw_texture_rec" then NativeId::DrawTextureRec
      when "begin_mode_3d" then NativeId::BeginMode3D
      when "end_mode_3d" then NativeId::EndMode3D
      when "draw_cube" then NativeId::DrawCube
      when "draw_cube_wires" then NativeId::DrawCubeWires
      when "draw_grid" then NativeId::DrawGrid
      when "draw_mesh" then NativeId::DrawMesh
      when "button_down?" then NativeId::ButtonDown
      when "button_pressed?" then NativeId::ButtonPressed
      when "button_released?" then NativeId::ButtonReleased
      when "get_analog" then NativeId::GetAnalog
      when "set_rumble" then NativeId::SetRumble
      when "load_sound" then NativeId::LoadSound
      when "play_sound" then NativeId::PlaySound
      when "stop_sound" then NativeId::StopSound
      when "debug_overlay=" then NativeId::SetDebugOverlay
      when "log" then NativeId::Log
      when "panic" then NativeId::Panic
      else nil
      end
    end

    private def resolve_constant_path(node : Crystal::Path) : ConstValue
      str = node.names.join("::")
      case str
      when "Button::Cross" then ConstValue.new(ConstType::Int32, int_val: Button::Cross.value.to_i32)
      when "Button::Circle" then ConstValue.new(ConstType::Int32, int_val: Button::Circle.value.to_i32)
      when "Button::Square" then ConstValue.new(ConstType::Int32, int_val: Button::Square.value.to_i32)
      when "Button::Triangle" then ConstValue.new(ConstType::Int32, int_val: Button::Triangle.value.to_i32)
      when "Button::Up" then ConstValue.new(ConstType::Int32, int_val: Button::Up.value.to_i32)
      when "Button::Down" then ConstValue.new(ConstType::Int32, int_val: Button::Down.value.to_i32)
      when "Button::Left" then ConstValue.new(ConstType::Int32, int_val: Button::Left.value.to_i32)
      when "Button::Right" then ConstValue.new(ConstType::Int32, int_val: Button::Right.value.to_i32)
      when "Button::L1" then ConstValue.new(ConstType::Int32, int_val: Button::L1.value.to_i32)
      when "Button::R1" then ConstValue.new(ConstType::Int32, int_val: Button::R1.value.to_i32)
      when "Button::L2" then ConstValue.new(ConstType::Int32, int_val: Button::L2.value.to_i32)
      when "Button::R2" then ConstValue.new(ConstType::Int32, int_val: Button::R2.value.to_i32)
      when "Button::Start" then ConstValue.new(ConstType::Int32, int_val: Button::Start.value.to_i32)
      when "Button::Select" then ConstValue.new(ConstType::Int32, int_val: Button::Select.value.to_i32)
      when "Color::White" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 255_u8, 255_u8).to_u32)
      when "Color::Black" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Red" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Green" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 255_u8, 0_u8, 255_u8).to_u32)
      when "Color::Blue" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 255_u8, 255_u8).to_u32)
      when "Color::Yellow" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 0_u8, 255_u8).to_u32)
      else ConstValue.new(ConstType::Int32, int_val: 0)
      end
    end

    private def add_constant(val : ConstValue) : Int32
      idx = @constants.index(val)
      return idx if idx
      @constants << val
      @constants.size - 1
    end

    private def add_string(str : String) : Int32
      idx = @strings.index(str)
      return idx if idx
      @strings << str
      @strings.size - 1
    end

    private def record_location(node : Crystal::ASTNode, offset : Int32, fn_name : String)
      if loc = node.location
        @source_map.add(offset, @filename || "main.cr", loc.line_number, loc.column_number, fn_name)
      end
    end

    private def serialize_bytecode : Bytes
      # Ensure all function names are registered in strings table before serialization
      @functions.each do |fn|
        add_string(fn.name)
      end

      io = IO::Memory.new

      # Header
      io.write(MAGIC.to_slice)
      io.write_bytes(1_u16, IO::ByteFormat::LittleEndian) # Version 1
      io.write_bytes(@functions.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(@constants.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(@strings.size.to_u32, IO::ByteFormat::LittleEndian)

      # Strings
      @strings.each do |s|
        bytes = s.to_slice
        io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write(bytes)
      end

      # Constants
      @constants.each do |c|
        io.write_byte(c.type.value)
        case c.type
        when ConstType::Int32, ConstType::String
          io.write_bytes(c.int_val, IO::ByteFormat::LittleEndian)
        when ConstType::Color
          io.write_bytes(c.uint_val, IO::ByteFormat::LittleEndian)
        when ConstType::Float32
          io.write_bytes(c.float_val, IO::ByteFormat::LittleEndian)
        when ConstType::Vec2
          io.write_bytes(c.float_val, IO::ByteFormat::LittleEndian)
          io.write_bytes(c.float_val2, IO::ByteFormat::LittleEndian)
        when ConstType::Bool
          io.write_byte(c.int_val > 0 ? 1_u8 : 0_u8)
        else
          io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        end
      end

      # Function Table & Code
      current_code_offset = 0_u32
      @functions.each do |fn|
        name_idx = add_string(fn.name)
        io.write_bytes(name_idx.to_u32, IO::ByteFormat::LittleEndian)
        io.write_byte(fn.argc)
        io.write_byte(fn.num_registers)
        io.write_bytes(current_code_offset, IO::ByteFormat::LittleEndian)
        io.write_bytes(fn.instructions.size.to_u32, IO::ByteFormat::LittleEndian)
        current_code_offset += fn.instructions.size.to_u32
      end

      # Instructions
      @functions.each do |fn|
        fn.instructions.each do |instr|
          io.write_bytes(instr.raw, IO::ByteFormat::LittleEndian)
        end
      end

      io.to_slice
    end
  end
end
