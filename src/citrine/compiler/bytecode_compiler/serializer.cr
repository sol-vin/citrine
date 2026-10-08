require "compiler/crystal/syntax"
require "./types"
require "../opcode"

module Citrine
  class BytecodeCompiler
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

    private def is_debug_node?(node : Crystal::ASTNode) : Bool
      if node.is_a?(Crystal::Call)
        obj_name = node.obj.try(&.to_s) || ""
        if obj_name == "Citrine" || obj_name.empty?
          return true if node.name == "log" || node.name == "debug_overlay="
        end
        return true if node.name == "citrine_log"
      end
      false
    end

    private def strip_debug_nodes(program : ParsedProgram)
      program.top_level_nodes.reject! { |node| is_debug_node?(node) }
      program.top_level_nodes.map! do |node|
        if node.is_a?(Crystal::Call) && node.name == "main_loop" && (block = node.block)
          block.body = strip_debug_from_node(block.body)
          node
        else
          node
        end
      end

      if loop_body = program.main_loop_body
        program.main_loop_body = strip_debug_from_node(loop_body)
      end

      program.defs.each do |name, def_node|
        if body = def_node.body
          def_node.body = strip_debug_from_node(body)
        end
      end
    end

    private def strip_debug_from_node(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Expressions
        cleaned = node.expressions.reject { |child| is_debug_node?(child) }
        Crystal::Expressions.new(cleaned.map { |child| strip_debug_from_node(child) })
      when Crystal::If
        node.then = strip_debug_from_node(node.then)
        if node_else = node.else
          node.else = strip_debug_from_node(node_else)
        end
        node
      when Crystal::While
        node.body = strip_debug_from_node(node.body)
        node
      else
        is_debug_node?(node) ? Crystal::Nop.new : node
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
      io.write_bytes(2_u16, IO::ByteFormat::LittleEndian) # Version 2
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
