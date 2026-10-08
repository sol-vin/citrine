require "../mips/mips_emitter"
require "./pad_runtime_payload"
require "./subroutines/*"

module Citrine
  module ISO
    # Provides reusable leaf MIPS R5900 runtime subroutines and native API stubs
    # for PlayStation 2 Emotion Engine execution.
    class RuntimeSubroutines
      alias MipsEmitter = Citrine::MIPS::MipsEmitter
      include Citrine::MIPS
      STUB_NAMES = [
        "Citrine_VM_Run",
        "Citrine_InitWindow",
        "Citrine_CloseWindow",
        "Citrine_BeginDrawing",
        "Citrine_EndDrawing",
        "Citrine_ClearBackground",
        "Citrine_DrawRectangle",
        "Citrine_DrawCircle",
        "Citrine_DrawLine",
        "Citrine_DrawText",
        "Citrine_BeginMode3D",
        "Citrine_EndMode3D",
        "Citrine_DrawCube",
        "Citrine_DrawCubeWires",
        "Citrine_DrawGrid",
        "Citrine_DrawMesh",
        "Citrine_LoadModel",
        "Citrine_DrawModel",
        "Citrine_DrawModelEx",
        "Citrine_UnloadModel",
        "Citrine_DrawTriangle3D",
        "Citrine_DrawBillboard",
        "Citrine_LoadTexture",
        "Citrine_DrawTexture",
        "Citrine_ButtonDown",
        "Citrine_ButtonPressed",
        "Citrine_ButtonReleased",
        "Citrine_GetAnalog",
        "Citrine_SetRumble",
        "Citrine_ActionRegister",
        "Citrine_ActionPressed",
        "Citrine_ActionDown",
        "Citrine_ActionReleased",
        "Citrine_LoadSound",
        "Citrine_PlaySound",
        "Citrine_StopSound",
        "Citrine_PlayCDDA",
        "Citrine_StopCDDA",
        "Citrine_GetCDDAStatus",
        "Citrine_SetVolume",
        "Citrine_AudioSeekStream",
        "Citrine_PauseStream",
        "Citrine_ResumeStream",
        "Citrine_CdvdSeekEntropy",
        "citrine_vm_panic",
        "Citrine_ObjectNew",
        "Citrine_ObjectGetField",
        "Citrine_ObjectSetField",
        "Citrine_StructCopy",
        "Citrine_ArrayNew",
        "Citrine_StaticArrayNew",
        "Citrine_ArrayGet",
        "Citrine_ArraySet",
        "Citrine_ArrayPush",
        "Citrine_ArrayPop",
        "Citrine_ArrayClear",
        "Citrine_ArraySize",
        "Citrine_ToString",
        "Citrine_StringAlloc",
        "Citrine_StrCmp",
        "Citrine_StringStrip",
        "Citrine_StringUpcase",
        "Citrine_StringDowncase",
        "Citrine_StringStartsWith",
        "Citrine_StringEndsWith",
        "Citrine_StringIncludes",
        "Citrine_StringConcat",
        "Citrine_FiberSpawn",
        "Citrine_FiberYield",
        "Citrine_StepFibers",
      ]

      # Emits DMAC Channel 2 wait loop
      def self.emit_dma02_wait(emitter : MipsEmitter)
        emitter.label("dma02_wait")
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.label("dma02_wait_loop")
        emitter.lw(T9, 0, T8)
        emitter.andi(T9, T9, 0x100)
        emitter.bnez(T9, "dma02_wait_loop")
        emitter.nop
        emitter.jr(RA)
        emitter.nop
      end

      # Emits DMAC master reset
      def self.emit_dma_reset(emitter : MipsEmitter)
        emitter.label("dma_reset")
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.sw(ZERO, 0, T8)
        emitter.sw(ZERO, 0x10, T8)
        emitter.sw(ZERO, 0x30, T8)
        emitter.sw(ZERO, 0x40, T8)
        emitter.sw(ZERO, 0x50, T8)
        emitter.lui(T7, 0x1000)
        emitter.ori(T7, T7, 0xe000)
        emitter.ori(T6, ZERO, 0xff1f)
        emitter.sw(T6, 0x10, T7)
        emitter.sw(ZERO, 0, T7)
        emitter.sw(ZERO, 0x20, T7)
        emitter.sw(ZERO, 0x30, T7)
        emitter.sw(ZERO, 0x40, T7)
        emitter.sw(ZERO, 0x50, T7)
        emitter.lw(T6, 0, T7)
        emitter.ori(T6, T6, 1)
        emitter.sw(T6, 0, T7)
        emitter.jr(RA)
        emitter.nop
      end

      # Emits console logging routine: EE SIO UART output and PCSX2 SYSCALL_print (0x75)
      def self.emit_debug_puts(emitter : MipsEmitter)
        emitter.label("debug_puts")
        # Guard against NULL pointer
        emitter.bnez(A0, "debug_puts_not_null")
        emitter.nop
        emitter.jr(RA)
        emitter.nop

        emitter.label("debug_puts_not_null")
        emitter.addiu(SP, SP, -32)
        emitter.sw(RA, 28, SP)
        emitter.sw(S0, 24, SP)
        emitter.sw(A0, 20, SP)

        # 1. Output string to EE SIO (UART at 0x1000f180) byte-by-byte
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xf180)
        emitter.move(S0, A0)
        emitter.move(T5, ZERO) # last char seen

        emitter.label("sio_loop")
        emitter.lbu(T6, 0, S0)
        emitter.beqz(T6, "sio_done")
        emitter.nop
        emitter.sb(T6, 0, T8)
        emitter.move(T5, T6)
        emitter.addiu(S0, S0, 1)
        emitter.j("sio_loop")
        emitter.nop

        emitter.label("sio_done")
        # Ensure trailing newline in UART SIO if not present
        emitter.ori(T6, ZERO, 0x0A)
        emitter.beq(T5, T6, "sio_skip_nl")
        emitter.nop
        emitter.sb(T6, 0, T8)
        emitter.label("sio_skip_nl")

        # 2. Syscall 0x75 (PCSX2 SYSCALL_print) - only for main RAM (< 0x02000000)
        emitter.lw(A0, 20, SP)
        emitter.lui(T7, 0x0200)
        emitter.sltu(T7, A0, T7)
        emitter.beqz(T7, "sio_no_syscall")
        emitter.nop
        emitter.ori(V1, ZERO, 0x75)
        emitter.syscall_inst
        emitter.nop

        # If string didn't have trailing newline, send newline to Syscall 0x75 to flush PCSX2 buffer
        emitter.ori(T6, ZERO, 0x0A)
        emitter.beq(T5, T6, "sio_no_syscall")
        emitter.nop
        emitter.jump("after_dbg_nl")
        emitter.nop
        emitter.label("dbg_puts_nl_str")
        emitter.emit_string("\n")
        emitter.label("after_dbg_nl")
        emitter.la(A0, "dbg_puts_nl_str")
        emitter.ori(V1, ZERO, 0x75)
        emitter.syscall_inst
        emitter.nop

        emitter.label("sio_no_syscall")

        emitter.lw(RA, 28, SP)
        emitter.lw(S0, 24, SP)
        emitter.jr(RA)
        emitter.addiu(SP, SP, 32)
      end

      # Emits all native API stubs with real SPRAM controller queries and SPU2 audio commands
      def self.emit_native_stubs(emitter : MipsEmitter, profile : ProgramProfile? = nil, digit_table_addr : UInt32 = 0_u32, sched_addr : UInt32 = 0_u32, button_msg_addrs : Hash(String, UInt32) = Hash(String, UInt32).new, font_table_addr : UInt32 = 0_u32, texture_table_addr : UInt32 = 0_u32)
        STUB_NAMES.each do |sname|
          emitter.label(sname)
          handled = emit_input_stub(sname, emitter, profile, button_msg_addrs) ||
                    emit_graphics_stub(sname, emitter, profile, digit_table_addr, font_table_addr, texture_table_addr, sched_addr, button_msg_addrs) ||
                    emit_audio_stub(sname, emitter, profile) ||
                    emit_objects_stub(sname, emitter, profile) ||
                    emit_collections_stub(sname, emitter, profile) ||
                    emit_strings_stub(sname, emitter, profile) ||
                    emit_concurrency_stub(sname, emitter, profile, sched_addr)

          unless handled
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.ori(V0, ZERO, 0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)
          end
        end
      end

      # Emits Citrine_InlineAsm_Block if user source code contained inline assembly words
      def self.emit_inline_asm(emitter : MipsEmitter, words : Array(UInt32))
        return if words.empty?
        emitter.label("Citrine_InlineAsm_Block")
        words.each do |w|
          emitter.emit(w)
        end
        emitter.jr(RA)
        emitter.nop
      end

      # Dynamically updates 13 font quads for a single digit slot in uncached GIF packet memory
      def self.emit_digit_quad_updater(emitter : MipsEmitter, digit_table_addr : UInt32)
        if digit_table_addr == 0_u32
          emitter.label("update_digit_quads")
          emitter.jr(RA)
          emitter.nop
          return
        end
        emitter.label("update_digit_quads")
        # a0 = digit (0..9) or >= 10 for blank slot
        # a1 = base_pos ((y << 4 << 16) | (x << 4))
        # a2 = dst_quad_ptr (uncached address of first quad)

        emitter.ori(T1, ZERO, 10)
        emitter.sltu(T2, A0, T1)
        emitter.bnez(T2, "udq_valid_digit")
        emitter.nop

        # Blank slot: zero out all 13 quads
        emitter.ori(T5, ZERO, 13)
        emitter.label("udq_blank_loop")
        emitter.sw(ZERO, 16, A2) # RGBAQ = 0 (alpha = 0, transparent)
        emitter.sw(ZERO, 32, A2) # XYZ3 = 0
        emitter.sw(ZERO, 48, A2) # XYZ2 = 0
        emitter.addiu(A2, A2, 64)
        emitter.addiu(T5, T5, -1)
        emitter.bnez(T5, "udq_blank_loop")
        emitter.nop
        emitter.jr(RA)
        emitter.nop

        emitter.label("udq_valid_digit")
        # src_ptr = digit_table_addr + digit * 104
        emitter.sll(T1, A0, 6) # d * 64
        emitter.sll(T2, A0, 5) # d * 32
        emitter.sll(T3, A0, 3) # d * 8
        emitter.addu(T1, T1, T2)
        emitter.addu(T1, T1, T3) # T1 = d * 104
        emitter.li(T4, digit_table_addr)
        emitter.addu(T4, T4, T1)  # T4 = src_ptr in digit table
        emitter.ori(T5, ZERO, 13) # 13 quads per digit slot

        emitter.label("udq_loop")
        emitter.lw(T1, 0, T4)         # XYZ3_delta
        emitter.lw(T2, 4, T4)         # XYZ2_delta
        emitter.beqz(T2, "udq_empty") # XYZ2_delta is non-zero for any active quad
        emitter.nop
        emitter.sllv(T1, T1, A3) # Scale delta: << 1 for scale=2, << 0 for scale=1
        emitter.sllv(T2, T2, A3)
        emitter.addu(T1, T1, A1)    # XYZ3 = base_pos + delta
        emitter.addu(T2, T2, A1)    # XYZ2 = base_pos + delta
        emitter.lui(T3, 0x80FF)     # RGBA: Alpha=0x80, Blue=0xFF
        emitter.ori(T3, T3, 0xFFFF) # Green=0xFF, Red=0xFF
        emitter.sw(T3, 16, A2)      # Store RGBA at quad + 16 (opaque white)
        emitter.sw(T1, 32, A2)      # Store XYZ3 at quad + 32
        emitter.sw(T2, 48, A2)      # Store XYZ2 at quad + 48
        emitter.jump("udq_next")
        emitter.nop

        emitter.label("udq_empty")
        emitter.sw(ZERO, 16, A2) # RGBAQ = 0 (alpha = 0, transparent)
        emitter.sw(ZERO, 32, A2) # Empty quad: XYZ3 = 0
        emitter.sw(ZERO, 48, A2) # Empty quad: XYZ2 = 0

        emitter.label("udq_next")
        emitter.addiu(T4, T4, 8)  # Next entry in digit table (8 bytes)
        emitter.addiu(A2, A2, 64) # Next quad in GIF packet (64 bytes)
        emitter.addiu(T5, T5, -1)
        emitter.bnez(T5, "udq_loop")
        emitter.nop

        emitter.jr(RA)
        emitter.nop
      end
    end
  end
end
