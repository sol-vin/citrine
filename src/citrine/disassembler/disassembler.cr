require "../compiler/opcode"
require "../compiler/source_map"
require "../ast/types"

module Citrine
  class Disassembler
    getter io : IO
    getter source_map : SourceMap?

    struct FnDesc
      property name_idx : UInt32
      property argc : UInt8
      property num_registers : UInt8
      property code_offset : UInt32
      property instruction_count : UInt32

      def initialize(@name_idx : UInt32, @argc : UInt8, @num_registers : UInt8, @code_offset : UInt32, @instruction_count : UInt32)
      end
    end

    def initialize(@io : IO = STDOUT, @source_map : SourceMap? = nil)
    end

    def disassemble_file(path : String)
      bytes = File.read(path).to_slice
      disassemble(bytes)
    end

    def disassemble(bytes : Bytes)
      io_in = IO::Memory.new(bytes)

      # Header
      magic = io_in.read_string(4)
      unless magic == "CBC1"
        @io.puts "Error: Invalid magic header '#{magic}' (expected 'CBC1')"
        return
      end

      version = io_in.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      num_functions = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_constants = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_strings = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

      @io.puts "; Citrine Bytecode (.cbc) Disassembly"
      @io.puts "; Version: #{version} | Functions: #{num_functions} | Constants: #{num_constants} | Strings: #{num_strings}\n"

      # Read Strings
      strings = [] of String
      num_strings.times do |i|
        len = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        s = io_in.read_string(len)
        strings << s
        @io.puts "; String [#{i}]: \"#{s}\""
      end
      @io.puts ""

      # Read Constants
      num_constants.times do |i|
        type_val = io_in.read_byte || 0_u8
        type = ConstType.from_value(type_val)
        case type
        when ConstType::Int32
          val = io_in.read_bytes(Int32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: Int32(#{val})"
        when ConstType::Float32
          val = io_in.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: Float32(#{val})"
        when ConstType::Vec2
          x = io_in.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          y = io_in.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: Vec2(#{x}, #{y})"
        when ConstType::Color
          val = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: Color(0x#{val.to_s(16)})"
        when ConstType::String
          idx = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: StringRef(\"#{strings[idx]? || ""}\")"
        else
          val = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          @io.puts "; Const [#{i}]: Raw(0x#{val.to_s(16)})"
        end
      end
      @io.puts ""

      # Function Descriptors
      fn_descs = [] of FnDesc
      num_functions.times do
        name_idx = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        argc = io_in.read_byte || 0_u8
        num_regs = io_in.read_byte || 0_u8
        offset = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        count = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        fn_descs << FnDesc.new(name_idx, argc, num_regs, offset, count)
      end

      # Instructions
      fn_descs.each_with_index do |f, fn_idx|
        fn_name = strings[f.name_idx]? || "fn_#{fn_idx}"
        @io.puts ".function #{fn_name} (registers: #{f.num_registers}, args: #{f.argc}, instructions: #{f.instruction_count})"

        f.instruction_count.times do |i|
          raw_instr = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          instr = Instruction.new(raw_instr)
          op = instr.opcode
          dst = instr.dst
          a = instr.a
          b = instr.b
          imm16 = instr.imm16

          # Source line resolution
          loc_str = ""
          if sm = @source_map
            if loc = sm.resolve(i.to_i32)
              loc_str = " ; #{File.basename(loc.file)}:#{loc.line}"
            end
          end

          case op
          when Opcode::CallNative
            native_id = NativeId.from_value(b.to_u16)
            @io.puts sprintf("  %04d: %-14s R%d, native:%s (base: R%d)%s", i, op.to_s, dst, native_id.to_s, a, loc_str)
          when Opcode::LoadInt
            @io.puts sprintf("  %04d: %-14s R%d, %d%s", i, op.to_s, dst, imm16.to_i16, loc_str)
          when Opcode::LoadConst
            @io.puts sprintf("  %04d: %-14s R%d, const[%d]%s", i, op.to_s, dst, imm16, loc_str)
          when Opcode::Jump
            @io.puts sprintf("  %04d: %-14s offset:%+d (target: %04d)%s", i, op.to_s, instr.branch_offset, i + 1 + instr.branch_offset, loc_str)
          when Opcode::JumpIfFalse, Opcode::JumpIfTrue
            @io.puts sprintf("  %04d: %-14s R%d, offset:%+d (target: %04d)%s", i, op.to_s, dst, instr.branch_offset, i + 1 + instr.branch_offset, loc_str)
          when Opcode::Return
            @io.puts sprintf("  %04d: %-14s R%d%s", i, op.to_s, dst, loc_str)
          else
            @io.puts sprintf("  %04d: %-14s R%d, R%d, R%d%s", i, op.to_s, dst, a, b, loc_str)
          end
        end
        @io.puts ""
      end
    end
  end
end
