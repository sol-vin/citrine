require "../mips/mips_emitter"
require "../compiler/opcode"
require "./rodata_segment_builder"

module Citrine
  module ISO
    # Translates Citrine-32 bytecode (.cbc) into native MIPS R5900 machine code
    # for direct execution on the PlayStation 2 Emotion Engine CPU (294.912 MHz).
    #
    # Architecture:
    # - Functions map to individual MIPS subroutines with label `fn_{idx}`
    # - Virtual registers $r0..$r255 map to zero-wait-state Scratchpad RAM (SPRAM)
    #   activation frames addressed via base register $k0 (starts at 0x70000400).
    # - Subroutine calls allocate an activation frame at $k0 + (caller_num_regs * 4),
    #   preserving caller frames across deep recursion and coroutine switches.
    # - Native API calls (CallNative) dispatch directly to leaf runtime routines
    #   in RuntimeSubroutines (GS drawing, input, audio, objects, arrays).
    class MipsCompiler
      alias MipsEmitter = Citrine::MIPS::MipsEmitter
      include Citrine::MIPS

      REG_BASE_SPRAM = 0x70000400_u32

      struct FunctionMeta
        property name : String
        property argc : UInt8
        property num_regs : UInt8
        property offset : UInt32
        property count : UInt32

        def initialize(@name, @argc, @num_regs, @offset, @count)
        end
      end

      struct ConstMeta
        property type : UInt8
        property u32_val : UInt32
        property str_val : String
        property f32_val : Float32

        def initialize(@type, @u32_val = 0_u32, @str_val = "", @f32_val = 0.0_f32)
        end
      end

      getter fns = [] of FunctionMeta
      getter constants = [] of ConstMeta
      getter strings = [] of String
      getter raw_instructions = [] of UInt32
      getter func_table_addr : UInt32 = 0_u32
      getter main_fn_idx : Int32? = nil

      def self.compile(
        cbc_bytes : Bytes,
        emitter : MipsEmitter,
        rodata : RodataResult
      ) : MipsCompiler?
        compiler = new
        compiler.load_cbc(cbc_bytes)
        compiler.compile_all(emitter, rodata)
        compiler
      end

      def load_cbc(bytes : Bytes)
        return if bytes.size < 20
        magic = String.new(bytes[0, 4])
        return unless magic == "CBC1" || magic == "CBC2"

        io = IO::Memory.new(bytes)
        io.read_string(4) # magic
        io.read_bytes(UInt16, IO::ByteFormat::LittleEndian) # version
        num_fns = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        num_consts = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        num_strings = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

        @strings.clear
        num_strings.times do
          len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          @strings << io.read_string(len)
        end

        @constants.clear
        num_consts.times do
          ctype = io.read_byte.not_nil!
          case ctype
          when 2 # Int32
            v = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
            @constants << ConstMeta.new(ctype, (v.to_i64 & 0xFFFFFFFF_u64).to_u32)
          when 5 # Color
            v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            @constants << ConstMeta.new(ctype, v)
          when 6 # StringRef
            s_idx = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
            @constants << ConstMeta.new(ctype, 0_u32, str_val: @strings[s_idx]? || "")
          when 3 # Float32
            f = io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
            b = Bytes.new(4)
            IO::ByteFormat::LittleEndian.encode(f, b)
            u = IO::ByteFormat::LittleEndian.decode(UInt32, b)
            @constants << ConstMeta.new(ctype, u, f32_val: f)
          when 1 # Bool
            b_val = io.read_byte.not_nil!
            @constants << ConstMeta.new(ctype, b_val.to_u32)
          else
            v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            @constants << ConstMeta.new(ctype, v)
          end
        end

        @fns.clear
        num_fns.times do
          n_idx = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          argc = io.read_byte.not_nil!
          num_regs = io.read_byte.not_nil!
          off = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          cnt = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          fname = @strings[n_idx]? || "fn_#{n_idx}"
          @fns << FunctionMeta.new(fname, argc, num_regs, off, cnt)
        end

        instructions_start = io.pos
        @raw_instructions.clear
        total_words = (bytes.size - instructions_start) // 4
        total_words.times do
          @raw_instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        end

        @main_fn_idx = @fns.index { |f| f.name == "__main__" }
      end

      def compile_all(emitter : MipsEmitter, rodata : RodataResult)
        return if @fns.empty?

        # Function Pointer Table Jump Trampoline (strictly 8 bytes per entry)
        emitter.label("citrine_func_table")
        @fns.each_with_index do |_, i|
          emitter.j("fn_#{i}")
          emitter.nop
        end

        # Compile each function
        @fns.each_with_index do |fn_meta, fn_idx|
          compile_function(fn_idx, fn_meta, emitter, rodata)
        end

        # Emit string literals
        @constants.each_with_index do |cm, const_idx|
          if cm.type == 6 # StringRef
            emitter.label("str_const_#{const_idx}")
            emitter.emit_string(cm.str_val)
          end
        end
      end

      private def compile_function(
        fn_idx : Int32,
        fn : FunctionMeta,
        emitter : MipsEmitter,
        rodata : RodataResult
      )
        emitter.label("fn_#{fn_idx}")
        emitter.addiu(SP, SP, -32)
        emitter.sw(RA, 28, SP)


        instr_slice = @raw_instructions[fn.offset, fn.count]

        # Scan for branch targets to emit labels
        targets = Set(Int32).new
        instr_slice.each_with_index do |raw, pc|
          instr = Instruction.new(raw)
          op = instr.opcode
          case op
          when Opcode::Jump
            tgt = pc + 1 + instr.jump_offset24
            targets << tgt if tgt >= 0 && tgt < fn.count
          when Opcode::BranchZ, Opcode::LoopDecBr
            tgt = pc + 1 + instr.branch_offset
            targets << tgt if tgt >= 0 && tgt < fn.count
          when Opcode::BranchCmp
            tgt = pc + 1 + instr.offset8.to_i32
            targets << tgt if tgt >= 0 && tgt < fn.count
          end
        end

        instr_slice.each_with_index do |raw, pc|
          if targets.includes?(pc)
            emitter.label("fn_#{fn_idx}_pc_#{pc}")
          end

          instr = Instruction.new(raw)
          emit_instruction(fn_idx, pc, instr, fn, emitter, rodata)
        end

        # Default fallthrough return if not explicitly returned
        if targets.includes?(fn.count.to_i32)
          emitter.label("fn_#{fn_idx}_pc_#{fn.count}")
        end
        emitter.move(V0, ZERO)
        emitter.lw(RA, 28, SP)
        emitter.addiu(SP, SP, 32)
        emitter.jr(RA)
        emitter.nop
      end


      private def emit_instruction(
        fn_idx : Int32,
        pc : Int32,
        instr : Instruction,
        fn : FunctionMeta,
        emitter : MipsEmitter,
        rodata : RodataResult
      )
        op = instr.opcode
        dst = instr.dst
        a = instr.a
        b = instr.b
        subop = instr.subop

        case op
        when Opcode::Sys
          case subop
          when 0 # Nop
            emitter.nop
          when 1 # Halt
            emitter.jump("frame_loop")
            emitter.nop
          when 2 # Break
            emitter.break_inst
          else
            emitter.nop
          end

        when Opcode::Move
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.sw(T0, (dst.to_i32 * 4), FP)

        when Opcode::LoadImm
          case subop
          when 0 # Nil
            emitter.sw(ZERO, (dst.to_i32 * 4), FP)
          when 1 # Bool
            emitter.ori(T0, ZERO, instr.imm16.to_i32)
            emitter.sw(T0, (dst.to_i32 * 4), FP)
          when 2, 3, 5 # Int16, UInt16, Zero
            emitter.li(T0, instr.imm16.to_i32)
            emitter.sw(T0, (dst.to_i32 * 4), FP)
          when 4 # Upper16
            emitter.lui(T0, instr.imm16.to_i32)
            emitter.sw(T0, (dst.to_i32 * 4), FP)
          when 6 # MinusOne
            emitter.li(T0, -1)
            emitter.sw(T0, (dst.to_i32 * 4), FP)
          else
            emitter.li(T0, instr.imm16.to_i32)
            emitter.sw(T0, (dst.to_i32 * 4), FP)
          end

        when Opcode::LoadConst
          const_idx = instr.imm16.to_i32
          if const_idx >= 0 && const_idx < @constants.size
            cm = @constants[const_idx]
            case cm.type
            when 6 # StringRef
              emitter.la(T0, "str_const_#{const_idx}")
              emitter.sw(T0, (dst.to_i32 * 4), FP)
            else # Number, Color, etc.
              emitter.li(T0, cm.u32_val)
              emitter.sw(T0, (dst.to_i32 * 4), FP)
            end
          else
            emitter.sw(ZERO, (dst.to_i32 * 4), FP)
          end

        when Opcode::Add
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          emitter.addu(T2, T0, T1)
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Sub
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          emitter.subu(T2, T0, T1)
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Mul
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          emitter.mult(T0, T1)
          emitter.mflo(T2)
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::DivMod
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          div_lbl = "div_ok_#{fn_idx}_#{pc}"
          emitter.bnez(T1, div_lbl)
          emitter.nop
          emitter.ori(T1, ZERO, 1) # Guard divide-by-zero
          emitter.label(div_lbl)
          emitter.divu(T0, T1)
          if subop == 0 || subop == 2 # Div
            emitter.mflo(T2)
          else # Mod
            emitter.mfhi(T2)
          end
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Bitwise
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          case subop
          when 0 # And
            emitter.and_(T2, T0, T1)
          when 1 # Or
            emitter.or_(T2, T0, T1)
          when 2 # Xor
            emitter.xor_(T2, T0, T1)
          when 3 # Nor
            emitter.nor(T2, T0, T1)
          else
            emitter.and_(T2, T0, T1)
          end
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Shift
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          case subop
          when 0 # Sll
            emitter.sllv(T2, T0, T1)
          when 1 # Srl
            emitter.srlv(T2, T0, T1)
          when 2 # Sra
            emitter.srav(T2, T0, T1)
          else
            emitter.sllv(T2, T0, T1)
          end
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Compare
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.lw(T1, (b.to_i32 * 4), FP)
          case subop
          when 0 # Eq
            cmp_eq_lbl = "cmp_eq_fast_#{fn_idx}_#{pc}"
            cmp_done_lbl = "cmp_eq_done_#{fn_idx}_#{pc}"
            emitter.beq(T0, T1, cmp_eq_lbl)
            emitter.nop
            emitter.lui(T2, 0x0050)
            emitter.sltu(T3, T0, T2)
            emitter.bnez(T3, "cmp_eq_fail_#{fn_idx}_#{pc}")
            emitter.nop
            emitter.sltu(T3, T1, T2)
            emitter.bnez(T3, "cmp_eq_fail_#{fn_idx}_#{pc}")
            emitter.nop
            emitter.move(A0, T0)
            emitter.move(A1, T1)
            emitter.call("Citrine_StrCmp")
            emitter.sw(V0, (dst.to_i32 * 4), FP)
            emitter.jump(cmp_done_lbl)
            emitter.nop
            emitter.label("cmp_eq_fail_#{fn_idx}_#{pc}")
            emitter.sw(ZERO, (dst.to_i32 * 4), FP)
            emitter.jump(cmp_done_lbl)
            emitter.nop
            emitter.label(cmp_eq_lbl)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, (dst.to_i32 * 4), FP)
            emitter.label(cmp_done_lbl)
          when 1 # Ne
            cmp_ne_lbl = "cmp_ne_fast_#{fn_idx}_#{pc}"
            cmp_ne_done = "cmp_ne_done_#{fn_idx}_#{pc}"
            emitter.beq(T0, T1, cmp_ne_lbl)
            emitter.nop
            emitter.lui(T2, 0x0050)
            emitter.sltu(T3, T0, T2)
            emitter.bnez(T3, "cmp_ne_pass_#{fn_idx}_#{pc}")
            emitter.nop
            emitter.sltu(T3, T1, T2)
            emitter.bnez(T3, "cmp_ne_pass_#{fn_idx}_#{pc}")
            emitter.nop
            emitter.move(A0, T0)
            emitter.move(A1, T1)
            emitter.call("Citrine_StrCmp")
            emitter.xori(T2, V0, 1)
            emitter.sw(T2, (dst.to_i32 * 4), FP)
            emitter.jump(cmp_ne_done)
            emitter.nop
            emitter.label("cmp_ne_pass_#{fn_idx}_#{pc}")
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, (dst.to_i32 * 4), FP)
            emitter.jump(cmp_ne_done)
            emitter.nop
            emitter.label(cmp_ne_lbl)
            emitter.sw(ZERO, (dst.to_i32 * 4), FP)
            emitter.label(cmp_ne_done)
          when 2 # Lt
            emitter.slt(T2, T0, T1)
          when 3 # Le
            emitter.slt(T2, T1, T0)
            emitter.xori(T2, T2, 1)
          when 4 # Gt
            emitter.slt(T2, T1, T0)
          when 5 # Ge
            emitter.slt(T2, T0, T1)
            emitter.xori(T2, T2, 1)
          else
            emitter.slt(T2, T0, T1)
          end
          emitter.sw(T2, (dst.to_i32 * 4), FP)

        when Opcode::Jump
          target_pc = pc + 1 + instr.jump_offset24
          emitter.jump("fn_#{fn_idx}_pc_#{target_pc}")
          emitter.nop

        when Opcode::BranchZ
          target_pc = pc + 1 + instr.branch_offset
          emitter.lw(T0, (dst.to_i32 * 4), FP)
          if subop == 0 # Truthy
            emitter.bnez(T0, "fn_#{fn_idx}_pc_#{target_pc}")
          else # Falsy
            emitter.beqz(T0, "fn_#{fn_idx}_pc_#{target_pc}")
          end
          emitter.nop

        when Opcode::BranchCmp
          target_pc = pc + 1 + instr.offset8.to_i32
          emitter.lw(T0, (dst.to_i32 * 4), FP)
          emitter.lw(T1, (a.to_i32 * 4), FP)
          case subop
          when 0 # Beq
            emitter.beq(T0, T1, "fn_#{fn_idx}_pc_#{target_pc}")
          when 1 # Bne
            emitter.bne(T0, T1, "fn_#{fn_idx}_pc_#{target_pc}")
          when 2 # Blt
            emitter.slt(T2, T0, T1)
            emitter.bnez(T2, "fn_#{fn_idx}_pc_#{target_pc}")
          when 3 # Ble
            emitter.slt(T2, T1, T0)
            emitter.beqz(T2, "fn_#{fn_idx}_pc_#{target_pc}")
          when 4 # Bgt
            emitter.slt(T2, T1, T0)
            emitter.bnez(T2, "fn_#{fn_idx}_pc_#{target_pc}")
          when 5 # Bge
            emitter.slt(T2, T0, T1)
            emitter.beqz(T2, "fn_#{fn_idx}_pc_#{target_pc}")
          else
            emitter.beq(T0, T1, "fn_#{fn_idx}_pc_#{target_pc}")
          end
          emitter.nop

        when Opcode::Call
          target_fn = instr.imm16.to_i32
          target_argc = (target_fn >= 0 && target_fn < @fns.size) ? @fns[target_fn].argc.to_i32 : 0
          frame_advance = fn.num_regs.to_i32 * 4

          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.sw(FP, 24, SP)

          # Copy arguments: caller registers (dst + 1 + i) -> callee registers i
          target_argc.times do |i|
            arg_src = (dst.to_i32 + 1 + i) * 4
            arg_dst = frame_advance + (i * 4)
            emitter.lw(T0, arg_src, FP)
            emitter.sw(T0, arg_dst, FP)
          end

          # Advance frame pointer
          emitter.addiu(FP, FP, frame_advance)
          emitter.jal("fn_#{target_fn}")
          emitter.nop

          # Restore frame pointer and return address
          emitter.lw(FP, 24, SP)
          emitter.lw(RA, 28, SP)
          emitter.addiu(SP, SP, 32)

          # Store return value (V0) to caller's destination register
          emitter.sw(V0, (dst.to_i32 * 4), FP)

        when Opcode::Return
          emitter.lw(V0, (dst.to_i32 * 4), FP)
          emitter.lw(RA, 28, SP)
          emitter.addiu(SP, SP, 32)
          emitter.jr(RA)
          emitter.nop

        when Opcode::CallNative
          emit_native_call(fn_idx, pc, instr, emitter)

        when Opcode::FiberOp
          case subop
          when 0 # Spawn
            fib_fn = instr.imm16.to_i32
            emitter.li(A0, fib_fn)
            emitter.lw(A1, ((dst.to_i32 + 1) * 4), FP) # arg
            emitter.call("Citrine_FiberSpawn")
            emitter.sw(V0, (dst.to_i32 * 4), FP)
          when 1 # Yield
            emitter.call("Citrine_FiberYield")
          else
            emitter.nop
          end

        when Opcode::FloatAlu
          emitter.lw(T0, (a.to_i32 * 4), FP)
          emitter.sw(T0, (dst.to_i32 * 4), FP)

        else
          emitter.nop
        end
      end

      private def emit_native_call(
        fn_idx : Int32,
        pc : Int32,
        instr : Instruction,
        emitter : MipsEmitter
      )
        dst = instr.dst.to_i32
        base = instr.a.to_i32
        native_id = instr.b > 0 ? instr.b.to_i32 : (instr.imm16.to_i32 & 0xFF)

        case native_id
        when 1 # InitWindow
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_InitWindow")
          emitter.sw(V0, (dst * 4), FP)

        when 2 # CloseWindow
          emitter.call("Citrine_CloseWindow")
          emitter.sw(V0, (dst * 4), FP)

        when 3 # WindowOpen
          emitter.ori(V0, ZERO, 1) # Always open on PS2
          emitter.sw(V0, (dst * 4), FP)

        when 4 # SetTargetFPS
          emitter.ori(V0, ZERO, 60)
          emitter.sw(V0, (dst * 4), FP)

        when 5 # GetFPS
          emitter.ori(V0, ZERO, 60)
          emitter.sw(V0, (dst * 4), FP)

        when 6 # GetDeltaTime
          emitter.lui(V0, 0x3C88)
          emitter.ori(V0, V0, 0x8889)
          emitter.sw(V0, (dst * 4), FP)

        when 35 # LoadSound
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_LoadSound")
          emitter.sw(V0, (dst * 4), FP)

        when 36 # PlaySound
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_PlaySound")
          emitter.sw(V0, (dst * 4), FP)

        when 37 # StopSound
          emitter.call("Citrine_StopSound")
          emitter.sw(V0, (dst * 4), FP)

        when 43 # GetAnalog(port, axis)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_GetAnalog")
          emitter.sw(V0, (dst * 4), FP)

        when 44 # SetRumble(port, small, large)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_SetRumble")
          emitter.sw(V0, (dst * 4), FP)

        when 65 # Sleep(frames)
          emitter.lw(T4, (base * 4), FP)
          emitter.bgtz(T4, "sleep_start_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.ori(T4, ZERO, 1)
          emitter.label("sleep_start_#{fn_idx}_#{pc}")
          emitter.label("sleep_loop_#{fn_idx}_#{pc}")
          emitter.vsync_wait("slp_#{fn_idx}_#{pc}")
          emitter.addiu(T4, T4, -1)
          emitter.bgtz(T4, "sleep_loop_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.sw(ZERO, (dst * 4), FP)

        when 99 # Panic(msg)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("citrine_vm_panic")

        when 10 # BeginDrawing
          emitter.call("Citrine_BeginDrawing")
          emitter.sw(V0, (dst * 4), FP)

        when 11 # EndDrawing
          emitter.call("Citrine_EndDrawing")
          emitter.sw(V0, (dst * 4), FP)

        when 12 # ClearBackground
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ClearBackground")
          emitter.sw(V0, (dst * 4), FP)

        when 20 # DrawRectangle
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawRectangle")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 21 # DrawCircle
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.call("Citrine_DrawCircle")
          emitter.sw(V0, (dst * 4), FP)

        when 22 # DrawLine
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawLine")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 24 # DrawText
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawText")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 30 # LoadTexture
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_LoadTexture")
          emitter.sw(V0, (dst * 4), FP)

        when 31 # DrawTexture
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.ori(A3, ZERO, 128)
          emitter.addiu(SP, SP, -32)
          emitter.ori(T0, ZERO, 128)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 32 # DrawTextureRec
          emitter.lw(A0, (base * 4), FP)        # tex_id
          emitter.lw(A1, ((base + 5) * 4), FP)  # dx
          emitter.lw(A2, ((base + 6) * 4), FP)  # dy
          emitter.lw(A3, ((base + 3) * 4), FP)  # dw
          emitter.lw(T0, ((base + 4) * 4), FP)  # dh
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 33 # UnloadTexture
          emitter.sw(ZERO, (dst * 4), FP)

        when 40 # ButtonDown
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonDown")
          emitter.sw(V0, (dst * 4), FP)

        when 41 # ButtonPressed
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonPressed")
          emitter.sw(V0, (dst * 4), FP)

        when 42 # ButtonReleased
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonReleased")
          emitter.sw(V0, (dst * 4), FP)

        when 45 # ActionPressed
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionPressed")
          emitter.sw(V0, (dst * 4), FP)

        when 46 # ActionDown
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionDown")
          emitter.sw(V0, (dst * 4), FP)

        when 47 # ActionReleased
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionReleased")
          emitter.sw(V0, (dst * 4), FP)

        when 48 # ActionRegister
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ActionRegister")
          emitter.sw(V0, (dst * 4), FP)

        when 70, 71 # Print, DebugLog
          emitter.lw(A0, (base * 4), FP)
          emitter.call("debug_puts")
          emitter.sw(V0, (dst * 4), FP)

        when 120 # ArrayNew(capacity)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayNew")
          emitter.sw(V0, (dst * 4), FP)

        when 121 # ArrayGet(arr, index)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ArrayGet")
          emitter.sw(V0, (dst * 4), FP)

        when 122 # ArraySet(arr, index, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ArraySet")
          emitter.sw(V0, (dst * 4), FP)

        when 123 # ArrayPush(arr, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ArrayPush")
          emitter.sw(V0, (dst * 4), FP)

        when 124 # ArrayPop(arr)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayPop")
          emitter.sw(V0, (dst * 4), FP)

        when 125 # ArraySize(arr_or_str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArraySize")
          emitter.sw(V0, (dst * 4), FP)

        when 126 # ArrayClear(arr)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayClear")
          emitter.sw(V0, (dst * 4), FP)

        when 150 # ObjectNew(class_id, field_count)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ObjectNew")
          emitter.sw(V0, (dst * 4), FP)

        when 151 # ObjectGetField(obj, field_idx)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ObjectGetField")
          emitter.sw(V0, (dst * 4), FP)

        when 152 # ObjectSetField(obj, field_idx, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ObjectSetField")
          emitter.sw(V0, (dst * 4), FP)

        when 180, 181 # ContextSet, ContextClear
          emitter.ori(V0, ZERO, 1)
          emitter.sw(V0, (dst * 4), FP)

        when 186 # StringStrip(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringStrip")
          emitter.sw(V0, (dst * 4), FP)

        when 187 # StringDowncase(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringDowncase")
          emitter.sw(V0, (dst * 4), FP)

        when 188 # StringUpcase(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringUpcase")
          emitter.sw(V0, (dst * 4), FP)

        when 189 # StringIncludes(str, needle)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringIncludes")
          emitter.sw(V0, (dst * 4), FP)

        when 192 # StringStartsWith(str, prefix)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringStartsWith")
          emitter.sw(V0, (dst * 4), FP)

        when 193 # StringEndsWith(str, suffix)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringEndsWith")
          emitter.sw(V0, (dst * 4), FP)

        when 195 # StringConcat(s1, s2)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringConcat")
          emitter.sw(V0, (dst * 4), FP)

        when 196 # ToString(int_val)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ToString")
          emitter.sw(V0, (dst * 4), FP)

        when 160 # PointerMalloc: dest = malloc(count * 4)
          emitter.lw(A0, (base * 4), FP) # element count
          emitter.sll(A0, A0, 2)         # bytes = count * 4
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0)       # current heap_ptr
          emitter.bnez(V0, "malloc_heap_ok_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.lui(V0, 0x0022)        # default heap base 0x00220000
          emitter.label("malloc_heap_ok_#{fn_idx}_#{pc}")
          emitter.addiu(T1, A0, 15)
          emitter.andi(T1, T1, 0xFFF0)   # 16-byte align
          emitter.addu(T2, V0, T1)
          emitter.sw(T2, 0x8C, T0)       # store updated heap_ptr
          # zero allocated memory
          emitter.move(T3, V0)
          emitter.label("malloc_zero_loop_#{fn_idx}_#{pc}")
          emitter.beqz(T1, "malloc_zero_done_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.sw(ZERO, 0, T3)
          emitter.addiu(T3, T3, 4)
          emitter.addiu(T1, T1, -4)
          emitter.jump("malloc_zero_loop_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.label("malloc_zero_done_#{fn_idx}_#{pc}")
          emitter.sw(V0, (dst * 4), FP)

        when 161 # PointerGet: dest = *(ptr + idx * 4)
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.sll(T1, T1, 2)
          emitter.addu(T0, T0, T1)             # address
          emitter.lw(V0, 0, T0)                # load word from address
          emitter.sw(V0, (dst * 4), FP)

        when 162 # PointerSet: *(ptr + idx * 4) = val
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.lw(T2, ((base + 2) * 4), FP) # val
          emitter.sll(T1, T1, 2)
          emitter.addu(T0, T0, T1)
          emitter.sw(T2, 0, T0)                # store word
          emitter.sw(T2, (dst * 4), FP)

        when 163 # PointerOffset: dest = ptr + idx * 4
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.sll(T1, T1, 2)
          emitter.addu(V0, T0, T1)
          emitter.sw(V0, (dst * 4), FP)

        when 164, 165, 166, 167 # PointerAddress, PointerNew, BoxNew, BoxUnbox
          emitter.lw(T0, (base * 4), FP)
          emitter.sw(T0, (dst * 4), FP)

        when 168 # PointerFree
          emitter.sw(ZERO, (dst * 4), FP)

        when 170 # TypeIsA
          emitter.ori(V0, ZERO, 1)
          emitter.sw(V0, (dst * 4), FP)

        when 171 # TypeAsCast
          emitter.lw(T0, (base * 4), FP)
          emitter.sw(T0, (dst * 4), FP)

        when 220 # AudioPlayCDDA
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_PlaySound")
          emitter.sw(V0, (dst * 4), FP)

        when 221 # AudioStopCDDA
          emitter.call("Citrine_StopSound")
          emitter.sw(V0, (dst * 4), FP)

        when 222 # AudioGetCDDAStatus
          emitter.call("Citrine_GetCDDAStatus")
          emitter.sw(V0, (dst * 4), FP)

        when 223 # AudioSetVolume
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_SetVolume")
          emitter.sw(V0, (dst * 4), FP)

        when 224 # AudioSeekStream
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_AudioSeekStream")
        when 237 # DrawTexturePro
          emitter.lw(A0, (base * 4), FP)        # tex_id
          emitter.lw(A1, ((base + 5) * 4), FP)  # dx
          emitter.lw(A2, ((base + 6) * 4), FP)  # dy
          emitter.lw(A3, ((base + 7) * 4), FP)  # dw
          emitter.lw(T0, ((base + 8) * 4), FP)  # dh
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)

        when 245 # CpuCycleCount: mfc0 $v0, $9
          emitter.emit((0x10_u32 << 26) | (2_u32 << 16) | (9_u32 << 11))
          emitter.sw(V0, (dst * 4), FP)

        when 246 # CdvdSeekEntropy
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_CdvdSeekEntropy")
          emitter.sw(V0, (dst * 4), FP)

        else
          emitter.sw(ZERO, (dst * 4), FP)
        end
      end
    end
  end
end
