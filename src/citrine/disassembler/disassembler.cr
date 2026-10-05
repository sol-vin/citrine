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
      unless magic == "CBC1" || magic == "CBC2"
        @io.puts "Error: Invalid magic header '#{magic}' (expected 'CBC1' or 'CBC2')"
        return
      end

      version = io_in.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      num_functions = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_constants = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_strings = io_in.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

      @io.puts "; Citrine Bytecode (.cbc) Disassembly (Citrine-32 ISA)"
      @io.puts "; Container: #{magic} | Version: #{version} | Functions: #{num_functions} | Constants: #{num_constants} | Strings: #{num_strings}\n"

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
          subop = instr.subop
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
          when Opcode::Sys
            sys_name = case subop
                       when SysSubOp::Nop.value then "Sys.Nop"
                       when SysSubOp::Halt.value then "Sys.Halt"
                       when SysSubOp::Break.value then "Sys.Break"
                       when SysSubOp::Sync.value then "Sys.Sync"
                       when SysSubOp::FlushICache.value then "Sys.FlushICache"
                       when SysSubOp::FlushDCache.value then "Sys.FlushDCache"
                       when SysSubOp::WatchdogReset.value then "Sys.WatchdogReset"
                       when SysSubOp::ProfileMark.value then "Sys.ProfileMark"
                       else "Sys[#{subop}]"
                       end
            @io.puts sprintf("  %04d: %-18s%s", i, sys_name, loc_str)

          when Opcode::Move
            move_name = case subop
                        when MoveSubOp::Move32.value then "Move.32"
                        when MoveSubOp::Move64.value then "Move.64"
                        when MoveSubOp::Move128.value then "Move.128"
                        when MoveSubOp::Cmovz.value then "Move.Cmovz"
                        when MoveSubOp::Cmovn.value then "Move.Cmovn"
                        when MoveSubOp::Swap.value then "Move.Swap"
                        else "Move[#{subop}]"
                        end
            @io.puts sprintf("  %04d: %-18s R%d, R%d%s", i, move_name, dst, a, loc_str)

          when Opcode::LoadImm
            case subop
            when LoadImmSubOp::Nil.value
              @io.puts sprintf("  %04d: %-18s R%d%s", i, "LoadImm.Nil", dst, loc_str)
            when LoadImmSubOp::Bool.value
              @io.puts sprintf("  %04d: %-18s R%d, %s%s", i, "LoadImm.Bool", dst, (imm16 != 0).to_s, loc_str)
            when LoadImmSubOp::Int16.value
              signed_imm = imm16 >= 0x8000 ? imm16.to_i32 - 0x10000 : imm16.to_i32
              @io.puts sprintf("  %04d: %-18s R%d, %d%s", i, "LoadImm.Int16", dst, signed_imm, loc_str)
            when LoadImmSubOp::Zero.value
              @io.puts sprintf("  %04d: %-18s R%d, 0%s", i, "LoadImm.Zero", dst, loc_str)
            when LoadImmSubOp::MinusOne.value
              @io.puts sprintf("  %04d: %-18s R%d, -1%s", i, "LoadImm.MinusOne", dst, loc_str)
            else
              @io.puts sprintf("  %04d: %-18s R%d, imm:0x%04x%s", i, "LoadImm[#{subop}]", dst, imm16, loc_str)
            end

          when Opcode::LoadConst
            @io.puts sprintf("  %04d: %-18s R%d, const[%d]%s", i, "LoadConst.#{subop}", dst, imm16, loc_str)

          when Opcode::Compare
            cmp_str = CompareSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Compare.#{cmp_str}", dst, a, b, loc_str)

          when Opcode::BranchCmp
            cmp_str = BranchCmpSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            target = i + 1 + instr.offset8.to_i32
            @io.puts sprintf("  %04d: %-18s R%d, R%d, offset:%+d (target: %04d)%s", i, "BranchCmp.#{cmp_str}", dst, a, instr.offset8, target, loc_str)

          when Opcode::LoopDecBr
            mode_str = LoopDecBrSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            target = i + 1 + instr.branch_offset.to_i32
            @io.puts sprintf("  %04d: %-18s R%d, offset:%+d (target: %04d)%s", i, "LoopDecBr.#{mode_str}", dst, instr.branch_offset, target, loc_str)

          when Opcode::FusedMadd
            madd_str = FusedMaddSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "FusedMadd.#{madd_str}", dst, a, b, loc_str)

          when Opcode::Jump
            if subop == JumpSubOp::JumpRel24.value
              target = i + 1 + instr.jump_offset24
              @io.puts sprintf("  %04d: %-18s offset:%+d (target: %04d)%s", i, "Jump.Rel24", instr.jump_offset24, target, loc_str)
            else
              target = i + 1 + instr.branch_offset.to_i32
              @io.puts sprintf("  %04d: %-18s offset:%+d (target: %04d)%s", i, "Jump.Rel16", instr.branch_offset, target, loc_str)
            end

          when Opcode::BranchZ
            br_str = BranchZSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            target = i + 1 + instr.branch_offset.to_i32
            @io.puts sprintf("  %04d: %-18s R%d, offset:%+d (target: %04d)%s", i, "BranchZ.#{br_str}", dst, instr.branch_offset, target, loc_str)

          when Opcode::CallNative
            dom_str = CallNativeSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            native_id = NativeId.from_value?(b.to_u16) ? NativeId.from_value(b.to_u16).to_s : b.to_s
            @io.puts sprintf("  %04d: %-18s R%d, native:%s (base: R%d)%s", i, "CallNative.#{dom_str}", dst, native_id, a, loc_str)

          when Opcode::Return
            ret_str = ReturnSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d%s", i, "Return.#{ret_str}", dst, loc_str)

          when Opcode::Call
            call_str = CallSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, fn[%d]%s", i, "Call.#{call_str}", dst, imm16, loc_str)

          when Opcode::InlineAsm
            @io.puts sprintf("  %04d: %-18s R%d, const[%d]%s", i, "InlineAsm.#{subop}", dst, imm16, loc_str)

          when Opcode::Add
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Add.#{subop}", dst, a, b, loc_str)

          when Opcode::Sub
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Sub.#{subop}", dst, a, b, loc_str)

          when Opcode::Mul
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Mul.#{subop}", dst, a, b, loc_str)

          when Opcode::DivMod
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "DivMod.#{subop}", dst, a, b, loc_str)

          when Opcode::Bitwise
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Bitwise.#{subop}", dst, a, b, loc_str)

          when Opcode::Shift
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Shift.#{subop}", dst, a, b, loc_str)

          when Opcode::Vec2Math
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Vec2Math.#{subop}", dst, a, b, loc_str)

          when Opcode::Vec2Prop
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Vec2Prop.#{subop}", dst, a, b, loc_str)

          when Opcode::ColorOp
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "ColorOp.#{subop}", dst, a, b, loc_str)

          when Opcode::Ps2Hw
            hw_str = Ps2HwSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "Ps2Hw.#{hw_str}", dst, a, b, loc_str)

          when Opcode::FiberOp
            fib_str = FiberSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "FiberOp.#{fib_str}", dst, a, b, loc_str)

          when Opcode::ChannelOp
            chan_str = ChannelSubOp.from_value?(subop).try(&.to_s) || subop.to_s
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "ChannelOp.#{chan_str}", dst, a, b, loc_str)

          else
            @io.puts sprintf("  %04d: %-18s R%d, R%d, R%d%s", i, "#{op}[#{subop}]", dst, a, b, loc_str)
          end
        end
        @io.puts ""
      end
    end
  end
end
