require "../mips/mips_emitter"
require "./pad_runtime_payload"

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
        "citrine_vm_panic"
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
        emitter.addiu(SP, SP, -32)
        emitter.sw(RA, 28, SP)
        emitter.sw(S0, 24, SP)
        emitter.sw(A0, 20, SP)

        # 1. Output string to EE SIO (UART at 0x1000f180) byte-by-byte
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xf180)
        emitter.move(S0, A0)

        emitter.label("sio_loop")
        emitter.lbu(T6, 0, S0)
        emitter.beqz(T6, "sio_done")
        emitter.nop
        emitter.sb(T6, 0, T8)
        emitter.addiu(S0, S0, 1)
        emitter.j("sio_loop")
        emitter.nop

        emitter.label("sio_done")

        # 2. Syscall 0x75 (PCSX2 SYSCALL_print)
        emitter.lw(A0, 20, SP)
        emitter.ori(V1, ZERO, 0x75)
        emitter.syscall_inst
        emitter.nop

        emitter.lw(RA, 28, SP)
        emitter.lw(S0, 24, SP)
        emitter.jr(RA)
        emitter.addiu(SP, SP, 32)
      end

      # Emits all native API stubs with real SPRAM controller queries and SPU2 audio commands
      def self.emit_native_stubs(emitter : MipsEmitter, profile : ProgramProfile? = nil)
        STUB_NAMES.each do |sname|
          emitter.label(sname)
          case sname
          when "Citrine_ButtonDown" # A0 = port (0/1), A1 = button index
            emitter.sll(T1, A0, 4)     # port * 16
            emitter.sll(T2, A0, 2)     # port * 4
            emitter.addu(T1, T1, T2)   # port * 20
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T1)
            emitter.lw(V0, 16, T0)     # load current buttons from 0x70000010 + port * 20
            emitter.srlv(V0, V0, A1)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ButtonPressed" # A0 = port (0/1), A1 = button index
            emitter.sll(T1, A0, 4)     # port * 16
            emitter.sll(T2, A0, 2)     # port * 4
            emitter.addu(T1, T1, T2)   # port * 20
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T1)
            emitter.lw(V0, 24, T0)     # load pressed buttons from 0x70000018 + port * 20
            emitter.srlv(V0, V0, A1)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ButtonReleased" # A0 = port (0/1), A1 = button index
            emitter.sll(T1, A0, 4)     # port * 16
            emitter.sll(T2, A0, 2)     # port * 4
            emitter.addu(T1, T1, T2)   # port * 20
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T1)
            emitter.lw(V0, 28, T0)     # load released buttons from 0x7000001C + port * 20
            emitter.srlv(V0, V0, A1)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionPressed" # A0 = action_id
            emitter.lui(T0, 0x7000)
            # Cross on Port 0: actions 1, 4, 7, 11, 21, 27
            emitter.ori(T1, ZERO, 1)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 4)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 7)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 11)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 21)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 27)
            emitter.beq(A0, T1, "act_p_cross_p0")
            emitter.nop
            # R1 on Port 0: actions 2, 19
            emitter.ori(T1, ZERO, 2)
            emitter.beq(A0, T1, "act_p_r1_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 19)
            emitter.beq(A0, T1, "act_p_r1_p0")
            emitter.nop
            # Triangle on Port 0: actions 3, 13
            emitter.ori(T1, ZERO, 3)
            emitter.beq(A0, T1, "act_p_tri_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 13)
            emitter.beq(A0, T1, "act_p_tri_p0")
            emitter.nop
            # Square on Port 0: actions 5, 12, 22
            emitter.ori(T1, ZERO, 5)
            emitter.beq(A0, T1, "act_p_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 12)
            emitter.beq(A0, T1, "act_p_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 22)
            emitter.beq(A0, T1, "act_p_sq_p0")
            emitter.nop
            # Cross on Port 1: action 8
            emitter.ori(T1, ZERO, 8)
            emitter.beq(A0, T1, "act_p_cross_p1")
            emitter.nop
            emitter.ori(V0, ZERO, 0)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_p_cross_p0")
            emitter.lw(V0, 24, T0)     # Port 0 pressed (0x70000018)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_p_r1_p0")
            emitter.lw(V0, 24, T0)     # Port 0 pressed (0x70000018)
            emitter.srl(V0, V0, 11)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_p_tri_p0")
            emitter.lw(V0, 24, T0)     # Port 0 pressed (0x70000018)
            emitter.srl(V0, V0, 12)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_p_sq_p0")
            emitter.lw(V0, 24, T0)     # Port 0 pressed (0x70000018)
            emitter.srl(V0, V0, 15)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_p_cross_p1")
            emitter.lw(V0, 44, T0)     # Port 1 pressed (0x7000002C)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionDown" # A0 = action_id
            emitter.lui(T0, 0x7000)
            # Cross on Port 0: actions 1, 4, 7, 11, 21, 27
            emitter.ori(T1, ZERO, 1)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 4)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 7)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 11)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 21)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 27)
            emitter.beq(A0, T1, "act_d_cross_p0")
            emitter.nop
            # R1 on Port 0: actions 2, 19
            emitter.ori(T1, ZERO, 2)
            emitter.beq(A0, T1, "act_d_r1_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 19)
            emitter.beq(A0, T1, "act_d_r1_p0")
            emitter.nop
            # Triangle on Port 0: actions 3, 13
            emitter.ori(T1, ZERO, 3)
            emitter.beq(A0, T1, "act_d_tri_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 13)
            emitter.beq(A0, T1, "act_d_tri_p0")
            emitter.nop
            # Square on Port 0: actions 5, 12, 22
            emitter.ori(T1, ZERO, 5)
            emitter.beq(A0, T1, "act_d_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 12)
            emitter.beq(A0, T1, "act_d_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 22)
            emitter.beq(A0, T1, "act_d_sq_p0")
            emitter.nop
            # Cross on Port 1: action 8
            emitter.ori(T1, ZERO, 8)
            emitter.beq(A0, T1, "act_d_cross_p1")
            emitter.nop
            emitter.ori(V0, ZERO, 0)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_d_cross_p0")
            emitter.lw(V0, 16, T0)     # Port 0 current (0x70000010)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_d_r1_p0")
            emitter.lw(V0, 16, T0)     # Port 0 current (0x70000010)
            emitter.srl(V0, V0, 11)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_d_tri_p0")
            emitter.lw(V0, 16, T0)     # Port 0 current (0x70000010)
            emitter.srl(V0, V0, 12)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_d_sq_p0")
            emitter.lw(V0, 16, T0)     # Port 0 current (0x70000010)
            emitter.srl(V0, V0, 15)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_d_cross_p1")
            emitter.lw(V0, 36, T0)     # Port 1 current (0x70000024)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionReleased" # A0 = action_id
            emitter.lui(T0, 0x7000)
            # Cross on Port 0: actions 1, 4, 7, 11, 21, 27
            emitter.ori(T1, ZERO, 1)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 4)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 7)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 11)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 21)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 27)
            emitter.beq(A0, T1, "act_r_cross_p0")
            emitter.nop
            # R1 on Port 0: actions 2, 19
            emitter.ori(T1, ZERO, 2)
            emitter.beq(A0, T1, "act_r_r1_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 19)
            emitter.beq(A0, T1, "act_r_r1_p0")
            emitter.nop
            # Triangle on Port 0: actions 3, 13
            emitter.ori(T1, ZERO, 3)
            emitter.beq(A0, T1, "act_r_tri_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 13)
            emitter.beq(A0, T1, "act_r_tri_p0")
            emitter.nop
            # Square on Port 0: actions 5, 12, 22
            emitter.ori(T1, ZERO, 5)
            emitter.beq(A0, T1, "act_r_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 12)
            emitter.beq(A0, T1, "act_r_sq_p0")
            emitter.nop
            emitter.ori(T1, ZERO, 22)
            emitter.beq(A0, T1, "act_r_sq_p0")
            emitter.nop
            # Cross on Port 1: action 8
            emitter.ori(T1, ZERO, 8)
            emitter.beq(A0, T1, "act_r_cross_p1")
            emitter.nop
            emitter.ori(V0, ZERO, 0)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_r_cross_p0")
            emitter.lw(V0, 28, T0)     # Port 0 released (0x7000001C)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_r_r1_p0")
            emitter.lw(V0, 28, T0)     # Port 0 released (0x7000001C)
            emitter.srl(V0, V0, 11)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_r_tri_p0")
            emitter.lw(V0, 28, T0)     # Port 0 released (0x7000001C)
            emitter.srl(V0, V0, 12)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_r_sq_p0")
            emitter.lw(V0, 28, T0)     # Port 0 released (0x7000001C)
            emitter.srl(V0, V0, 15)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop

            emitter.label("act_r_cross_p1")
            emitter.lw(V0, 48, T0)     # Port 1 released (0x70000030)
            emitter.srl(V0, V0, 14)
            emitter.andi(V0, V0, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_LoadSound"
            emitter.ori(V0, ZERO, 1) # Return sound handle 1
            emitter.jr(RA)
            emitter.nop
          when "Citrine_PlaySound", "Citrine_PlayCDDA"
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)

            # If A0 >= 0x0100, pass directly (direct track cmd)
            emitter.lui(T0, 0x0000)
            emitter.ori(T0, T0, 0x0100)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "cdda_play_entry")
            emitter.nop

            # Map 0-based stream track index: 0x0100 | (A0 & 0xFF)
            emitter.andi(A0, A0, 0xFF)
            emitter.ori(A0, A0, 0x0100)

            emitter.label("cdda_play_entry")
            emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
            emitter.jalr(T9)
            emitter.nop
            emitter.ori(V0, ZERO, 1) # Return success (1)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)
          when "Citrine_StopSound", "Citrine_StopCDDA"
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.li(T9, PadRuntimePayload::SOUND_STOP_ENTRY)
            emitter.jalr(T9)
            emitter.nop
            emitter.ori(V0, ZERO, 0) # Return stopped (0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)
          when "Citrine_GetCDDAStatus"
            emitter.ori(V0, ZERO, 1) # Return playing / ready (1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_SetVolume"
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.sw(A0, 24, SP)
            emitter.andi(A0, A0, 0xFF)
            emitter.ori(A0, A0, 0x1000) # cmd 0x1000 | vol
            emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
            emitter.jalr(T9)
            emitter.nop
            emitter.lw(V0, 24, SP) # Return set volume (A0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)
          when "Citrine_AudioSeekStream"
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.sw(A0, 24, SP)

            # If A0 >= 0x020000, pass command directly
            emitter.lui(T0, 0x0002)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "seek_play_entry")
            emitter.nop

            # Convert seconds (A0) to bank index: target_bank = (A0 * 1000) / bank_dur_ms
            seek_bank_dur = profile.try(&.bank_dur_ms) || 1195_u32
            emitter.li(T2, 1000)
            emitter.mult(A0, T2)
            emitter.mflo(T3)
            emitter.li(T2, seek_bank_dur.to_i)
            emitter.divu(T3, T2)
            emitter.mflo(T1) # target_bank
            emitter.andi(T1, T1, 0xFFFF)
            emitter.lui(A0, 0x0002)
            emitter.or_(A0, A0, T1)

            emitter.label("seek_play_entry")
            emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
            emitter.jalr(T9)
            emitter.nop
            emitter.ori(V0, ZERO, 1) # Return success (1)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)

          else
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
        emitter.addu(T4, T4, T1) # T4 = src_ptr in digit table
        emitter.ori(T5, ZERO, 13) # 13 quads per digit slot

        emitter.label("udq_loop")
        emitter.lw(T1, 0, T4) # XYZ3_delta
        emitter.lw(T2, 4, T4) # XYZ2_delta
        emitter.beqz(T2, "udq_empty") # XYZ2_delta is non-zero for any active quad
        emitter.nop
        emitter.sllv(T1, T1, A3) # Scale delta: << 1 for scale=2, << 0 for scale=1
        emitter.sllv(T2, T2, A3)
        emitter.addu(T1, T1, A1) # XYZ3 = base_pos + delta
        emitter.addu(T2, T2, A1) # XYZ2 = base_pos + delta
        emitter.lui(T3, 0x80FF) # RGBA: Alpha=0x80, Blue=0xFF
        emitter.ori(T3, T3, 0xFFFF) # Green=0xFF, Red=0xFF
        emitter.sw(T3, 16, A2)  # Store RGBA at quad + 16 (opaque white)
        emitter.sw(T1, 32, A2)  # Store XYZ3 at quad + 32
        emitter.sw(T2, 48, A2)  # Store XYZ2 at quad + 48
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
