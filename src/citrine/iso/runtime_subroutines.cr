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
        "citrine_vm_panic",
        "Citrine_ObjectNew",
        "Citrine_ObjectGetField",
        "Citrine_ObjectSetField",
        "Citrine_ArrayNew",
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
        "Citrine_FiberSpawn",
        "Citrine_FiberYield",
        "Citrine_StepFibers"
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

        # 2. Syscall 0x75 (PCSX2 SYSCALL_print) - only for main RAM (< 0x02000000)
        emitter.lw(A0, 20, SP)
        emitter.lui(T7, 0x0200)
        emitter.sltu(T7, A0, T7)
        emitter.beqz(T7, "sio_no_syscall")
        emitter.nop
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
      def self.emit_native_stubs(emitter : MipsEmitter, profile : ProgramProfile? = nil, digit_table_addr : UInt32 = 0_u32)
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
          when "Citrine_ActionRegister" # A0 = action_id, A1 = button, A2 = port
            emitter.ori(T0, ZERO, 16)
            emitter.sltu(T1, A1, T0)
            emitter.bnez(T1, "act_reg_shift")
            emitter.nop
            emitter.move(T2, A1)
            emitter.jump("act_reg_pack")
            emitter.nop
            emitter.label("act_reg_shift")
            emitter.ori(T2, ZERO, 1)
            emitter.sllv(T2, T2, A1)
            emitter.label("act_reg_pack")
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, A2, 16)
            emitter.or_(T2, T2, T3)
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x0200)
            emitter.andi(A0, A0, 0x3F)
            emitter.sll(T1, A0, 2)
            emitter.addu(T0, T0, T1)
            emitter.sw(T2, 0, T0)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionPressed" # A0 = action_id
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x0200)
            emitter.andi(T1, A0, 0x3F)
            emitter.sll(T1, T1, 2)
            emitter.addu(T0, T0, T1)
            emitter.lw(T2, 0, T0)
            emitter.bnez(T2, "act_p_lookup")
            emitter.nop
            emitter.ori(T0, ZERO, 16)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "act_p_raw")
            emitter.nop
            emitter.ori(T2, ZERO, 1)
            emitter.sllv(T2, T2, A0)
            emitter.jump("act_p_test_p0")
            emitter.nop
            emitter.label("act_p_raw")
            emitter.move(T2, A0)
            emitter.label("act_p_test_p0")
            emitter.lui(T0, 0x7000)
            emitter.lw(T3, 24, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
            emitter.label("act_p_lookup")
            emitter.srl(T3, T2, 16)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T4, T3, 4)
            emitter.sll(T5, T3, 2)
            emitter.addu(T4, T4, T5)
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T4)
            emitter.lw(T3, 24, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionDown" # A0 = action_id
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x0200)
            emitter.andi(T1, A0, 0x3F)
            emitter.sll(T1, T1, 2)
            emitter.addu(T0, T0, T1)
            emitter.lw(T2, 0, T0)
            emitter.bnez(T2, "act_d_lookup")
            emitter.nop
            emitter.ori(T0, ZERO, 16)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "act_d_raw")
            emitter.nop
            emitter.ori(T2, ZERO, 1)
            emitter.sllv(T2, T2, A0)
            emitter.jump("act_d_test_p0")
            emitter.nop
            emitter.label("act_d_raw")
            emitter.move(T2, A0)
            emitter.label("act_d_test_p0")
            emitter.lui(T0, 0x7000)
            emitter.lw(T3, 16, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
            emitter.label("act_d_lookup")
            emitter.srl(T3, T2, 16)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T4, T3, 4)
            emitter.sll(T5, T3, 2)
            emitter.addu(T4, T4, T5)
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T4)
            emitter.lw(T3, 16, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ActionReleased" # A0 = action_id
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x0200)
            emitter.andi(T1, A0, 0x3F)
            emitter.sll(T1, T1, 2)
            emitter.addu(T0, T0, T1)
            emitter.lw(T2, 0, T0)
            emitter.bnez(T2, "act_r_lookup")
            emitter.nop
            emitter.ori(T0, ZERO, 16)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "act_r_raw")
            emitter.nop
            emitter.ori(T2, ZERO, 1)
            emitter.sllv(T2, T2, A0)
            emitter.jump("act_r_test_p0")
            emitter.nop
            emitter.label("act_r_raw")
            emitter.move(T2, A0)
            emitter.label("act_r_test_p0")
            emitter.lui(T0, 0x7000)
            emitter.lw(T3, 28, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
            emitter.label("act_r_lookup")
            emitter.srl(T3, T2, 16)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T4, T3, 4)
            emitter.sll(T5, T3, 2)
            emitter.addu(T4, T4, T5)
            emitter.lui(T0, 0x7000)
            emitter.addu(T0, T0, T4)
            emitter.lw(T3, 28, T0)
            emitter.and_(V0, T3, T2)
            emitter.sltu(V0, ZERO, V0)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_BeginDrawing"
            emitter.lui(T0, 0x7000)
            emitter.lui(T1, 0x2058)
            emitter.ori(T1, T1, 0x0010)
            emitter.sw(T1, 0x90, T0)
            emitter.sw(ZERO, 0x94, T0)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_ClearBackground" # A0 = color (RGBA)
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "clr_bg_ret")
            emitter.nop
            emitter.ori(T2, ZERO, 6)
            emitter.sw(T2, 0, T1)
            emitter.sw(ZERO, 4, T1)
            emitter.sw(ZERO, 8, T1)
            emitter.sw(ZERO, 12, T1)
            emitter.sw(A0, 16, T1)
            emitter.lui(T2, 0x3F80)
            emitter.sw(T2, 20, T1)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, 24, T1)
            emitter.sw(ZERO, 28, T1)
            emitter.sw(ZERO, 32, T1)
            emitter.sw(ZERO, 36, T1)
            emitter.ori(T2, ZERO, 0x0D)
            emitter.sw(T2, 40, T1)
            emitter.sw(ZERO, 44, T1)
            emitter.lui(T2, 0x1C00)
            emitter.ori(T2, T2, 0x2800)
            emitter.sw(T2, 48, T1)
            emitter.sw(ZERO, 52, T1)
            emitter.ori(T3, ZERO, 5)
            emitter.sw(T3, 56, T1)
            emitter.sw(ZERO, 60, T1)
            emitter.addiu(T1, T1, 64)
            emitter.sw(T1, 0x90, T0)
            emitter.lw(T2, 0x94, T0)
            emitter.addiu(T2, T2, 4)
            emitter.sw(T2, 0x94, T0)
            emitter.label("clr_bg_ret")
            emitter.jr(RA)
            emitter.nop
          when "Citrine_DrawRectangle" # A0=x, A1=y, A2=w, A3=h, 16(SP)=color
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "draw_rect_ret")
            emitter.nop
            emitter.lw(T4, 16, SP)
            emitter.ori(T2, ZERO, 6)
            emitter.sw(T2, 0, T1)
            emitter.sw(ZERO, 4, T1)
            emitter.sw(ZERO, 8, T1)
            emitter.sw(ZERO, 12, T1)
            emitter.sw(T4, 16, T1)
            emitter.lui(T2, 0x3F80)
            emitter.sw(T2, 20, T1)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, 24, T1)
            emitter.sw(ZERO, 28, T1)
            emitter.sll(T2, A0, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, A1, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 32, T1)
            emitter.sw(ZERO, 36, T1)
            emitter.ori(T2, ZERO, 0x0D)
            emitter.sw(T2, 40, T1)
            emitter.sw(ZERO, 44, T1)
            emitter.addu(T2, A0, A2)
            emitter.sll(T2, T2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.addu(T3, A1, A3)
            emitter.sll(T3, T3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 48, T1)
            emitter.sw(ZERO, 52, T1)
            emitter.ori(T3, ZERO, 5)
            emitter.sw(T3, 56, T1)
            emitter.sw(ZERO, 60, T1)
            emitter.addiu(T1, T1, 64)
            emitter.sw(T1, 0x90, T0)
            emitter.lw(T2, 0x94, T0)
            emitter.addiu(T2, T2, 4)
            emitter.sw(T2, 0x94, T0)
            emitter.label("draw_rect_ret")
            emitter.jr(RA)
            emitter.nop
          when "Citrine_DrawLine" # A0=x1, A1=y1, A2=x2, A3=y2, 16(SP)=color
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "draw_line_ret")
            emitter.nop
            emitter.lw(T4, 16, SP)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, 0, T1)
            emitter.sw(ZERO, 4, T1)
            emitter.sw(ZERO, 8, T1)
            emitter.sw(ZERO, 12, T1)
            emitter.sw(T4, 16, T1)
            emitter.lui(T2, 0x3F80)
            emitter.sw(T2, 20, T1)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, 24, T1)
            emitter.sw(ZERO, 28, T1)
            emitter.sll(T2, A0, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, A1, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 32, T1)
            emitter.sw(ZERO, 36, T1)
            emitter.ori(T2, ZERO, 0x0D)
            emitter.sw(T2, 40, T1)
            emitter.sw(ZERO, 44, T1)
            emitter.sll(T2, A2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, A3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 48, T1)
            emitter.sw(ZERO, 52, T1)
            emitter.ori(T3, ZERO, 5)
            emitter.sw(T3, 56, T1)
            emitter.sw(ZERO, 60, T1)
            emitter.addiu(T1, T1, 64)
            emitter.sw(T1, 0x90, T0)
            emitter.lw(T2, 0x94, T0)
            emitter.addiu(T2, T2, 4)
            emitter.sw(T2, 0x94, T0)
            emitter.label("draw_line_ret")
            emitter.jr(RA)
            emitter.nop
          when "Citrine_DrawCircle" # A0=cx, A1=cy, A2=radius, A3=color
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "draw_circ_ret")
            emitter.nop
            emitter.ori(T2, ZERO, 6)
            emitter.sw(T2, 0, T1)
            emitter.sw(ZERO, 4, T1)
            emitter.sw(ZERO, 8, T1)
            emitter.sw(ZERO, 12, T1)
            emitter.sw(A3, 16, T1)
            emitter.lui(T2, 0x3F80)
            emitter.sw(T2, 20, T1)
            emitter.ori(T2, ZERO, 1)
            emitter.sw(T2, 24, T1)
            emitter.sw(ZERO, 28, T1)
            emitter.subu(T2, A0, A2)
            emitter.sll(T2, T2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.subu(T3, A1, A2)
            emitter.sll(T3, T3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 32, T1)
            emitter.sw(ZERO, 36, T1)
            emitter.ori(T2, ZERO, 0x0D)
            emitter.sw(T2, 40, T1)
            emitter.sw(ZERO, 44, T1)
            emitter.addu(T2, A0, A2)
            emitter.sll(T2, T2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.addu(T3, A1, A2)
            emitter.sll(T3, T3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 48, T1)
            emitter.sw(ZERO, 52, T1)
            emitter.ori(T3, ZERO, 5)
            emitter.sw(T3, 56, T1)
            emitter.sw(ZERO, 60, T1)
            emitter.addiu(T1, T1, 64)
            emitter.sw(T1, 0x90, T0)
            emitter.lw(T2, 0x94, T0)
            emitter.addiu(T2, T2, 4)
            emitter.sw(T2, 0x94, T0)
            emitter.label("draw_circ_ret")
            emitter.jr(RA)
            emitter.nop
          when "Citrine_EndDrawing"
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)

            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x94, T0)
            emitter.beqz(T1, "end_draw_vsync")
            emitter.nop
            emitter.lui(T2, 0x2058)
            emitter.lui(T3, 0x1000)
            emitter.sw(T3, 4, T2)
            emitter.lui(T3, 0x0000)
            emitter.ori(T3, T3, 0x8000)
            emitter.or_(T3, T3, T1)
            emitter.sw(T3, 0, T2)
            emitter.ori(T3, ZERO, 0x0E)
            emitter.sw(T3, 8, T2)
            emitter.sw(ZERO, 12, T2)
            # Wait for any prior DMA Channel 2 transfer to complete
            emitter.lui(T3, 0x1000)
            emitter.ori(T3, T3, 0xA000) # D2_CHCR
            emitter.label("end_draw_dma_pre_wait")
            emitter.lw(T4, 0, T3)
            emitter.andi(T4, T4, 0x0100)
            emitter.bnez(T4, "end_draw_dma_pre_wait")
            emitter.nop

            # Program MADR and QWC
            emitter.lui(T3, 0x1000)
            emitter.ori(T3, T3, 0xA010) # D2_MADR
            emitter.lui(T4, 0x0058)     # MADR = 0x00580000
            emitter.sw(T4, 0, T3)
            emitter.lui(T3, 0x1000)
            emitter.ori(T3, T3, 0xA020) # D2_QWC
            emitter.addiu(T4, T1, 1)    # QWC = data QWs + 1 GIFTag QW
            emitter.sw(T4, 0, T3)

            # Start DMA: STR=1, DIR=1 (From Memory / RAM -> GS) -> 0x0101
            emitter.lui(T3, 0x1000)
            emitter.ori(T3, T3, 0xA000) # D2_CHCR
            emitter.ori(T4, ZERO, 0x0101)
            emitter.sw(T4, 0, T3)

            # Wait for DMA Channel 2 transfer to complete
            emitter.label("end_draw_dma_wait")
            emitter.lw(T4, 0, T3)
            emitter.andi(T4, T4, 0x0100)
            emitter.bnez(T4, "end_draw_dma_wait")
            emitter.nop

            emitter.lui(T0, 0x7000)
            emitter.sw(ZERO, 0x90, T0)
            emitter.sw(ZERO, 0x94, T0)

            emitter.label("end_draw_vsync")
            # Wait for GS VSync
            emitter.vsync_wait("ed")
            # Increment hardware frame counter at 0x70000004
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 4, T0)
            emitter.addiu(T1, T1, 1)
            emitter.sw(T1, 4, T0)

            # Step all active fibers
            emitter.call("Citrine_StepFibers")

            emitter.label("end_draw_done")
            emitter.lw(RA, 28, SP)
            emitter.addiu(SP, SP, 32)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_InitWindow"
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
          when "Citrine_CloseWindow"
            emitter.ori(V0, ZERO, 0)
            emitter.jr(RA)
            emitter.nop
          when "citrine_vm_panic"
            emitter.bnez(A0, "panic_has_msg")
            emitter.nop
            emitter.lui(A0, 0x0050)
            emitter.label("panic_has_msg")
            emitter.call("debug_puts")
            emitter.label("panic_halt")
            emitter.jump("panic_halt")
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

          when "Citrine_DrawText" # A0=str_ptr, A1=x, A2=y, A3=font_size, 16(SP)=color
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "dt_ret_early")
            emitter.nop

            emitter.lw(T4, 16, SP)   # color from caller's frame
            emitter.ori(T2, ZERO, 10)
            emitter.sltu(T3, T2, A3) # 1 if font_size > 10 else 0
            emitter.move(A3, T3)     # scale_shift (0 for 1x, 1 for 2x)
            emitter.ori(T6, ZERO, 6)
            emitter.sllv(T6, T6, A3) # char advance = 6 << scale_shift

            # Save callee-saved registers and return address
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.sw(S0, 24, SP)
            emitter.sw(S1, 20, SP)
            emitter.sw(S2, 16, SP)

            emitter.move(S0, A0) # str_ptr
            emitter.move(S1, A1) # curr_x
            emitter.move(S2, A2) # curr_y

            emitter.label("dt_char_loop")
            emitter.lbu(T2, 0, S0)
            emitter.beqz(T2, "dt_done")
            emitter.nop

            # Check space (0x20)
            emitter.ori(T3, ZERO, 0x20)
            emitter.bne(T2, T3, "dt_check_digit")
            emitter.nop
            emitter.addu(S1, S1, T6)
            emitter.addiu(S0, S0, 1)
            emitter.jump("dt_char_loop")
            emitter.nop

            emitter.label("dt_check_digit")
            # Check digit '0' (0x30) .. '9' (0x39)
            emitter.addiu(T3, T2, -0x30)
            emitter.ori(T5, ZERO, 10)
            emitter.sltu(T5, T3, T5)
            emitter.beqz(T5, "dt_draw_glyph_box")
            emitter.nop

            # Valid digit: T3 = digit (0..9)
            if digit_table_addr > 0
              emitter.sll(T5, T3, 6)
              emitter.sll(T7, T3, 5)
              emitter.sll(T8, T3, 3)
              emitter.addu(T5, T5, T7)
              emitter.addu(T5, T5, T8) # T5 = d * 104
              emitter.li(T7, digit_table_addr)
              emitter.addu(T7, T7, T5) # T7 = src_ptr

              # base_pos = ((curr_y << 4) << 16) | (curr_x << 4)
              emitter.sll(T8, S1, 4)
              emitter.andi(T8, T8, 0xFFFF)
              emitter.sll(T9, S2, 4)
              emitter.sll(T9, T9, 16)
              emitter.or_(T8, T8, T9) # T8 = base_pos

              emitter.ori(T5, ZERO, 13) # 13 quads
              emitter.label("dt_digit_quad_loop")
              emitter.lw(T2, 0, T7) # XYZ3_delta
              emitter.lw(T3, 4, T7) # XYZ2_delta
              emitter.beqz(T3, "dt_digit_quad_skip")
              emitter.nop

              emitter.sllv(T2, T2, A3)
              emitter.sllv(T3, T3, A3)
              emitter.addu(T2, T2, T8)
              emitter.addu(T3, T3, T8)

              emitter.ori(T9, ZERO, 6) # PRIM = Sprite/Quad
              emitter.sw(T9, 0, T1)
              emitter.sw(ZERO, 4, T1)
              emitter.sw(ZERO, 8, T1)
              emitter.sw(ZERO, 12, T1)
              emitter.sw(T4, 16, T1) # RGBAQ = color
              emitter.lui(T9, 0x3F80)
              emitter.sw(T9, 20, T1)
              emitter.ori(T9, ZERO, 1)
              emitter.sw(T9, 24, T1)
              emitter.sw(ZERO, 28, T1)
              emitter.sw(T2, 32, T1) # XYZ3
              emitter.sw(ZERO, 36, T1)
              emitter.ori(T9, ZERO, 0x0D)
              emitter.sw(T9, 40, T1)
              emitter.sw(ZERO, 44, T1)
              emitter.sw(T3, 48, T1) # XYZ2
              emitter.sw(ZERO, 52, T1)
              emitter.ori(T9, ZERO, 5)
              emitter.sw(T9, 56, T1)
              emitter.sw(ZERO, 60, T1)

              emitter.addiu(T1, T1, 64)
              emitter.sw(T1, 0x90, T0)
              emitter.lw(T9, 0x94, T0)
              emitter.addiu(T9, T9, 4)
              emitter.sw(T9, 0x94, T0)

              emitter.label("dt_digit_quad_skip")
              emitter.addiu(T7, T7, 8)
              emitter.addiu(T5, T5, -1)
              emitter.bnez(T5, "dt_digit_quad_loop")
              emitter.nop
              emitter.jump("dt_next_char")
              emitter.nop
            end

            # Fallback for non-digit or missing table: draw glyph box
            emitter.label("dt_draw_glyph_box")
            emitter.ori(T9, ZERO, 6)
            emitter.sw(T9, 0, T1)
            emitter.sw(ZERO, 4, T1)
            emitter.sw(ZERO, 8, T1)
            emitter.sw(ZERO, 12, T1)
            emitter.sw(T4, 16, T1)
            emitter.lui(T9, 0x3F80)
            emitter.sw(T9, 20, T1)
            emitter.ori(T9, ZERO, 1)
            emitter.sw(T9, 24, T1)
            emitter.sw(ZERO, 28, T1)
            emitter.sll(T2, S1, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, S2, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 32, T1)
            emitter.sw(ZERO, 36, T1)
            emitter.ori(T9, ZERO, 0x0D)
            emitter.sw(T9, 40, T1)
            emitter.sw(ZERO, 44, T1)
            emitter.ori(T5, ZERO, 5)
            emitter.sllv(T5, T5, A3)
            emitter.addu(T2, S1, T5)
            emitter.sll(T2, T2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.ori(T5, ZERO, 7)
            emitter.sllv(T5, T5, A3)
            emitter.addu(T3, S2, T5)
            emitter.sll(T3, T3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 48, T1)
            emitter.sw(ZERO, 52, T1)
            emitter.ori(T9, ZERO, 5)
            emitter.sw(T9, 56, T1)
            emitter.sw(ZERO, 60, T1)
            emitter.addiu(T1, T1, 64)
            emitter.sw(T1, 0x90, T0)
            emitter.lw(T9, 0x94, T0)
            emitter.addiu(T9, T9, 4)
            emitter.sw(T9, 0x94, T0)

            emitter.label("dt_next_char")
            emitter.addu(S1, S1, T6)
            emitter.addiu(S0, S0, 1)
            emitter.jump("dt_char_loop")
            emitter.nop

            emitter.label("dt_done")
            emitter.lw(S2, 16, SP)
            emitter.lw(S1, 20, SP)
            emitter.lw(S0, 24, SP)
            emitter.lw(RA, 28, SP)
            emitter.addiu(SP, SP, 32)
            emitter.jr(RA)
            emitter.nop

            emitter.label("dt_ret_early")
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ObjectNew" # A0 = class_id, A1 = field_count
            emitter.lui(T0, 0x7000)
            emitter.lw(V0, 0x8C, T0) # current heap_ptr
            emitter.bnez(V0, "obj_heap_ok")
            emitter.nop
            emitter.lui(V0, 0x0022) # init heap at 0x00220000
            emitter.label("obj_heap_ok")
            emitter.sll(T1, A1, 2)  # field_count * 4
            emitter.addiu(T1, T1, 15)
            emitter.andi(T1, T1, 0xFFF0) # 16-byte align
            emitter.addu(T2, V0, T1)
            emitter.sw(T2, 0x8C, T0)   # store updated heap_ptr
            # zero allocated memory
            emitter.move(T3, V0)
            emitter.label("obj_zero_loop")
            emitter.beqz(T1, "obj_zero_done")
            emitter.nop
            emitter.sw(ZERO, 0, T3)
            emitter.addiu(T3, T3, 4)
            emitter.addiu(T1, T1, -4)
            emitter.jump("obj_zero_loop")
            emitter.nop
            emitter.label("obj_zero_done")
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ObjectGetField" # A0 = obj_ptr, A1 = field_idx
            emitter.bnez(A0, "obj_get_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("obj_get_ok")
            emitter.sll(T0, A1, 2)
            emitter.addu(T0, A0, T0)
            emitter.lw(V0, 0, T0)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ObjectSetField" # A0 = obj_ptr, A1 = field_idx, A2 = val
            emitter.bnez(A0, "obj_set_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("obj_set_ok")
            emitter.sll(T0, A1, 2)
            emitter.addu(T0, A0, T0)
            emitter.sw(A2, 0, T0)
            emitter.move(V0, A2)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArrayNew" # A0 = capacity
            emitter.ori(T1, ZERO, 64)
            emitter.sltu(T2, A0, T1)
            emitter.beqz(T2, "arr_cap_ok")
            emitter.nop
            emitter.move(A0, T1)
            emitter.label("arr_cap_ok")
            emitter.lui(T0, 0x7000)
            emitter.lw(V0, 0x8C, T0)
            emitter.bnez(V0, "arr_heap_ok")
            emitter.nop
            emitter.lui(V0, 0x0022)
            emitter.label("arr_heap_ok")
            emitter.sll(T1, A0, 2) # cap * 4
            emitter.addiu(T1, T1, 8) # +8 for size & cap
            emitter.addiu(T1, T1, 15)
            emitter.andi(T1, T1, 0xFFF0)
            emitter.addu(T2, V0, T1)
            emitter.sw(T2, 0x8C, T0)
            emitter.sw(ZERO, 0, V0) # size = 0
            emitter.sw(A0, 4, V0)   # capacity = A0
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArrayPush" # A0 = arr_ptr, A1 = val
            emitter.bnez(A0, "arr_push_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_push_ok")
            emitter.lw(T0, 0, A0)   # size
            emitter.lw(T2, 4, A0)   # capacity
            emitter.sltu(T3, T0, T2) # size < capacity
            emitter.beqz(T3, "arr_push_done") # prevent buffer overrun
            emitter.nop
            emitter.sll(T1, T0, 2)  # size * 4
            emitter.addu(T1, A0, T1)
            emitter.sw(A1, 8, T1)   # arr[8 + size * 4] = val
            emitter.addiu(T0, T0, 1)
            emitter.sw(T0, 0, A0)   # size++
            emitter.label("arr_push_done")
            emitter.move(V0, A0)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArrayPop" # A0 = arr_ptr
            emitter.bnez(A0, "arr_pop_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_pop_ok")
            emitter.lw(T0, 0, A0)   # size
            emitter.bnez(T0, "arr_pop_has_items")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_pop_has_items")
            emitter.addiu(T0, T0, -1)
            emitter.sw(T0, 0, A0)   # size--
            emitter.sll(T1, T0, 2)  # new_size * 4
            emitter.addu(T1, A0, T1)
            emitter.lw(V0, 8, T1)   # popped val = arr[8 + new_size * 4]
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArrayClear" # A0 = arr_ptr
            emitter.beqz(A0, "arr_clr_ret")
            emitter.nop
            emitter.sw(ZERO, 0, A0) # size = 0
            emitter.label("arr_clr_ret")
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArrayGet" # A0 = arr_ptr, A1 = index
            emitter.bnez(A0, "arr_get_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_get_ok")
            emitter.lw(T1, 0, A0) # size
            emitter.sltu(T2, A1, T1)
            emitter.bnez(T2, "arr_get_in_bounds")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_get_in_bounds")
            emitter.sll(T0, A1, 2)
            emitter.addu(T0, A0, T0)
            emitter.lw(V0, 8, T0)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArraySet" # A0 = arr_ptr, A1 = index, A2 = val
            emitter.bnez(A0, "arr_set_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_set_ok")
            emitter.sll(T0, A1, 2)
            emitter.addu(T0, A0, T0)
            emitter.sw(A2, 8, T0)
            emitter.move(V0, A2)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ArraySize" # A0 = arr_or_str
            emitter.bnez(A0, "arr_sz_non_zero")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_sz_non_zero")
            # Check if string pointer: in .rodata or dynamic string arena (>= 0x00500000) or ToString buffer (0x70003200..0x70003300)
            emitter.lui(T0, 0x0050)
            emitter.sltu(T1, A0, T0)
            emitter.beqz(T1, "arr_sz_strlen")
            emitter.nop
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x3200)
            emitter.subu(T1, A0, T0)
            emitter.sltiu(T1, T1, 0x100)
            emitter.bnez(T1, "arr_sz_strlen")
            emitter.nop
            # Array: size is at 0(A0)
            emitter.lw(V0, 0, A0)
            emitter.jr(RA)
            emitter.nop
            emitter.label("arr_sz_strlen")
            emitter.move(T0, A0)
            emitter.move(V0, ZERO)
            emitter.label("arr_sz_str_loop")
            emitter.lbu(T1, 0, T0)
            emitter.beqz(T1, "arr_sz_str_done")
            emitter.nop
            emitter.addiu(V0, V0, 1)
            emitter.addiu(T0, T0, 1)
            emitter.jump("arr_sz_str_loop")
            emitter.nop
            emitter.label("arr_sz_str_done")
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StringAlloc" # A0 = num_bytes -> V0 = buffer_ptr
            emitter.lui(T0, 0x7000)
            emitter.lw(V0, 0xA0, T0)
            emitter.bnez(V0, "str_alloc_ready")
            emitter.nop
            emitter.lui(V0, 0x0060) # default base 0x00600000
            emitter.label("str_alloc_ready")
            emitter.addiu(T1, A0, 15) # align to 16 bytes
            emitter.andi(T1, T1, 0xFFF0)
            emitter.addu(T2, V0, T1)
            emitter.sw(T2, 0xA0, T0)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StrCmp" # A0 = s1, A1 = s2 -> V0 = (s1 == s2 ? 1 : 0)
            emitter.beq(A0, A1, "strcmp_eq")
            emitter.nop
            emitter.beqz(A0, "strcmp_ne")
            emitter.nop
            emitter.beqz(A1, "strcmp_ne")
            emitter.nop
            emitter.label("strcmp_loop")
            emitter.lbu(T2, 0, A0)
            emitter.lbu(T3, 0, A1)
            emitter.bne(T2, T3, "strcmp_ne")
            emitter.nop
            emitter.beqz(T2, "strcmp_eq")
            emitter.nop
            emitter.addiu(A0, A0, 1)
            emitter.addiu(A1, A1, 1)
            emitter.jump("strcmp_loop")
            emitter.nop
            emitter.label("strcmp_eq")
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("strcmp_ne")
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StringUpcase" # A0 = str_ptr -> V0 = new_str
            emitter.bnez(A0, "upcase_has_str")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("upcase_has_str")
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.sw(A0, 24, SP)
            emitter.move(T0, A0)
            emitter.move(T1, ZERO)
            emitter.label("upcase_len_loop")
            emitter.lbu(T2, 0, T0)
            emitter.beqz(T2, "upcase_len_done")
            emitter.nop
            emitter.addiu(T1, T1, 1)
            emitter.addiu(T0, T0, 1)
            emitter.jump("upcase_len_loop")
            emitter.nop
            emitter.label("upcase_len_done")
            emitter.addiu(A0, T1, 1)
            emitter.call("Citrine_StringAlloc")
            emitter.lw(A0, 24, SP)
            emitter.move(T0, V0)
            emitter.label("upcase_copy_loop")
            emitter.lbu(T1, 0, A0)
            emitter.beqz(T1, "upcase_copy_done")
            emitter.nop
            emitter.ori(T2, ZERO, 97)
            emitter.sltu(T3, T1, T2)
            emitter.bnez(T3, "upcase_store")
            emitter.nop
            emitter.ori(T2, ZERO, 122)
            emitter.sltu(T3, T2, T1)
            emitter.bnez(T3, "upcase_store")
            emitter.nop
            emitter.addiu(T1, T1, -32)
            emitter.label("upcase_store")
            emitter.sb(T1, 0, T0)
            emitter.addiu(A0, A0, 1)
            emitter.addiu(T0, T0, 1)
            emitter.jump("upcase_copy_loop")
            emitter.nop
            emitter.label("upcase_copy_done")
            emitter.sb(ZERO, 0, T0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)

          when "Citrine_StringDowncase" # A0 = str_ptr -> V0 = new_str
            emitter.bnez(A0, "downcase_has_str")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("downcase_has_str")
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.sw(A0, 24, SP)
            emitter.move(T0, A0)
            emitter.move(T1, ZERO)
            emitter.label("downcase_len_loop")
            emitter.lbu(T2, 0, T0)
            emitter.beqz(T2, "downcase_len_done")
            emitter.nop
            emitter.addiu(T1, T1, 1)
            emitter.addiu(T0, T0, 1)
            emitter.jump("downcase_len_loop")
            emitter.nop
            emitter.label("downcase_len_done")
            emitter.addiu(A0, T1, 1)
            emitter.call("Citrine_StringAlloc")
            emitter.lw(A0, 24, SP)
            emitter.move(T0, V0)
            emitter.label("downcase_copy_loop")
            emitter.lbu(T1, 0, A0)
            emitter.beqz(T1, "downcase_copy_done")
            emitter.nop
            emitter.ori(T2, ZERO, 65)
            emitter.sltu(T3, T1, T2)
            emitter.bnez(T3, "downcase_store")
            emitter.nop
            emitter.ori(T2, ZERO, 90)
            emitter.sltu(T3, T2, T1)
            emitter.bnez(T3, "downcase_store")
            emitter.nop
            emitter.addiu(T1, T1, 32)
            emitter.label("downcase_store")
            emitter.sb(T1, 0, T0)
            emitter.addiu(A0, A0, 1)
            emitter.addiu(T0, T0, 1)
            emitter.jump("downcase_copy_loop")
            emitter.nop
            emitter.label("downcase_copy_done")
            emitter.sb(ZERO, 0, T0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)

          when "Citrine_StringStrip" # A0 = str_ptr -> V0 = new_str
            emitter.bnez(A0, "strip_has_str")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("strip_has_str")
            emitter.addiu(SP, SP, -32)
            emitter.sw(RA, 28, SP)
            emitter.label("strip_lead_loop")
            emitter.lbu(T1, 0, A0)
            emitter.beqz(T1, "strip_empty")
            emitter.nop
            emitter.ori(T2, ZERO, 32)
            emitter.sltu(T3, T2, T1)
            emitter.bnez(T3, "strip_lead_done")
            emitter.nop
            emitter.addiu(A0, A0, 1)
            emitter.jump("strip_lead_loop")
            emitter.nop
            emitter.label("strip_lead_done")
            emitter.move(T0, A0)
            emitter.move(T4, A0)
            emitter.label("strip_find_end")
            emitter.lbu(T1, 0, T0)
            emitter.beqz(T1, "strip_end_found")
            emitter.nop
            emitter.ori(T2, ZERO, 32)
            emitter.sltu(T3, T2, T1)
            emitter.beqz(T3, "strip_trail_ws")
            emitter.nop
            emitter.move(T4, T0)
            emitter.label("strip_trail_ws")
            emitter.addiu(T0, T0, 1)
            emitter.jump("strip_find_end")
            emitter.nop
            emitter.label("strip_end_found")
            emitter.subu(T5, T4, A0)
            emitter.addiu(T5, T5, 1)
            emitter.sw(A0, 24, SP)
            emitter.sw(T5, 20, SP)
            emitter.addiu(A0, T5, 1)
            emitter.call("Citrine_StringAlloc")
            emitter.lw(A0, 24, SP)
            emitter.lw(T5, 20, SP)
            emitter.move(T0, V0)
            emitter.label("strip_copy_loop")
            emitter.beqz(T5, "strip_copy_done")
            emitter.nop
            emitter.lbu(T1, 0, A0)
            emitter.sb(T1, 0, T0)
            emitter.addiu(A0, A0, 1)
            emitter.addiu(T0, T0, 1)
            emitter.addiu(T5, T5, -1)
            emitter.jump("strip_copy_loop")
            emitter.nop
            emitter.label("strip_copy_done")
            emitter.sb(ZERO, 0, T0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)
            emitter.label("strip_empty")
            emitter.ori(A0, ZERO, 4)
            emitter.call("Citrine_StringAlloc")
            emitter.sb(ZERO, 0, V0)
            emitter.lw(RA, 28, SP)
            emitter.jr(RA)
            emitter.addiu(SP, SP, 32)

          when "Citrine_StringStartsWith" # A0 = str, A1 = prefix -> V0 = (0 or 1)
            emitter.bnez(A0, "sw_a0_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("sw_a0_ok")
            emitter.bnez(A1, "sw_loop")
            emitter.nop
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("sw_loop")
            emitter.lbu(T2, 0, A1)
            emitter.beqz(T2, "sw_match")
            emitter.nop
            emitter.lbu(T1, 0, A0)
            emitter.bne(T1, T2, "sw_no_match")
            emitter.nop
            emitter.addiu(A0, A0, 1)
            emitter.addiu(A1, A1, 1)
            emitter.jump("sw_loop")
            emitter.nop
            emitter.label("sw_match")
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("sw_no_match")
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StringEndsWith" # A0 = str, A1 = suffix -> V0 = (0 or 1)
            emitter.bnez(A0, "ew_a0_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("ew_a0_ok")
            emitter.bnez(A1, "ew_measure")
            emitter.nop
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("ew_measure")
            emitter.move(T2, A0)
            emitter.move(T0, ZERO)
            emitter.label("ew_len0")
            emitter.lbu(T3, 0, T2)
            emitter.beqz(T3, "ew_len0_done")
            emitter.nop
            emitter.addiu(T0, T0, 1)
            emitter.addiu(T2, T2, 1)
            emitter.jump("ew_len0")
            emitter.nop
            emitter.label("ew_len0_done")
            emitter.move(T2, A1)
            emitter.move(T1, ZERO)
            emitter.label("ew_len1")
            emitter.lbu(T3, 0, T2)
            emitter.beqz(T3, "ew_len1_done")
            emitter.nop
            emitter.addiu(T1, T1, 1)
            emitter.addiu(T2, T2, 1)
            emitter.jump("ew_len1")
            emitter.nop
            emitter.label("ew_len1_done")
            emitter.sltu(T3, T0, T1)
            emitter.bnez(T3, "ew_no_match")
            emitter.nop
            emitter.subu(T3, T0, T1)
            emitter.addu(A0, A0, T3)
            emitter.label("ew_cmp_loop")
            emitter.lbu(T2, 0, A1)
            emitter.beqz(T2, "ew_match")
            emitter.nop
            emitter.lbu(T3, 0, A0)
            emitter.bne(T2, T3, "ew_no_match")
            emitter.nop
            emitter.addiu(A0, A0, 1)
            emitter.addiu(A1, A1, 1)
            emitter.jump("ew_cmp_loop")
            emitter.nop
            emitter.label("ew_match")
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("ew_no_match")
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StringIncludes" # A0 = str, A1 = needle -> V0 = (0 or 1)
            emitter.bnez(A0, "inc_a0_ok")
            emitter.nop
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop
            emitter.label("inc_a0_ok")
            emitter.bnez(A1, "inc_needle_chk")
            emitter.nop
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("inc_needle_chk")
            emitter.lbu(T2, 0, A1)
            emitter.bnez(T2, "inc_outer_loop")
            emitter.nop
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("inc_outer_loop")
            emitter.lbu(T1, 0, A0)
            emitter.beqz(T1, "inc_no_match")
            emitter.nop
            emitter.bne(T1, T2, "inc_next_char")
            emitter.nop
            emitter.move(T3, A0)
            emitter.move(T4, A1)
            emitter.label("inc_sub_cmp")
            emitter.lbu(T6, 0, T4)
            emitter.beqz(T6, "inc_match")
            emitter.nop
            emitter.lbu(T5, 0, T3)
            emitter.bne(T5, T6, "inc_next_char")
            emitter.nop
            emitter.addiu(T3, T3, 1)
            emitter.addiu(T4, T4, 1)
            emitter.jump("inc_sub_cmp")
            emitter.nop
            emitter.label("inc_next_char")
            emitter.addiu(A0, A0, 1)
            emitter.jump("inc_outer_loop")
            emitter.nop
            emitter.label("inc_match")
            emitter.ori(V0, ZERO, 1)
            emitter.jr(RA)
            emitter.nop
            emitter.label("inc_no_match")
            emitter.move(V0, ZERO)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_ToString" # A0 = int_val
            # Converts integer to ASCII decimal string at 0x70003200
            emitter.lui(T0, 0x7000)
            emitter.ori(T0, T0, 0x3200)
            emitter.move(T1, A0)
            emitter.bnez(T1, "ts_non_zero")
            emitter.nop
            emitter.ori(T2, ZERO, 0x30) # '0'
            emitter.sb(T2, 0, T0)
            emitter.sb(ZERO, 1, T0)
            emitter.move(V0, T0)
            emitter.jr(RA)
            emitter.nop
            emitter.label("ts_non_zero")
            emitter.addiu(T3, T0, 16) # buffer end
            emitter.sb(ZERO, 0, T3)
            emitter.ori(T4, ZERO, 10)
            emitter.label("ts_loop")
            emitter.beqz(T1, "ts_done")
            emitter.nop
            emitter.divu(T1, T4)
            emitter.mflo(T1)
            emitter.mfhi(T5)
            emitter.addiu(T5, T5, 0x30)
            emitter.addiu(T3, T3, -1)
            emitter.sb(T5, 0, T3)
            emitter.jump("ts_loop")
            emitter.nop
            emitter.label("ts_done")
            emitter.move(V0, T3)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_FiberSpawn" # A0 = func_idx, A1 = arg
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x88, T0) # fiber_count
            emitter.ori(T2, ZERO, 32)
            emitter.sltu(T3, T1, T2)
            emitter.beqz(T3, "fib_sp_done")
            emitter.nop

            # Fiber table entry at 0x70002000 + (fiber_count * 32)
            emitter.sll(T2, T1, 5) # fiber_count * 32
            emitter.ori(T3, T0, 0x2000)
            emitter.addu(T3, T3, T2) # T3 = fiber entry

            emitter.sw(A0, 0, T3) # func_idx
            emitter.sw(A1, 4, T3) # arg
            emitter.ori(T4, ZERO, 1)
            emitter.sw(T4, 8, T3) # state = 1 (READY)

            # Initial fiber_pc = citrine_func_table + (func_idx * 8)
            emitter.la(T4, "citrine_func_table")
            emitter.sll(T5, A0, 3) # func_idx * 8
            emitter.addu(T4, T4, T5)
            emitter.sw(T4, 12, T3) # fiber_pc

            # Initial fiber_sp = 0x01FE0000 - (fiber_count * 0x1000)
            emitter.lui(T4, 0x01FE)
            emitter.sll(T5, T1, 12) # fiber_count * 4096
            emitter.subu(T4, T4, T5)
            emitter.sw(T4, 16, T3) # fiber_sp

            # Initial fiber_k0 = 0x70001000 + (fiber_count * 128)
            emitter.ori(T4, T0, 0x1000)
            emitter.sll(T5, T1, 7) # fiber_count * 128
            emitter.addu(T4, T4, T5)
            emitter.sw(T4, 20, T3) # fiber_k0

            # Set up register $r0 at 0(fiber_k0) with arg (A1)
            emitter.sw(A1, 0, T4)

            # fiber_count++
            emitter.addiu(T1, T1, 1)
            emitter.sw(T1, 0x88, T0)

            emitter.label("fib_sp_done")
            emitter.move(V0, T1)
            emitter.jr(RA)
            emitter.nop

          when "Citrine_FiberYield"
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x84, T0) # current_fiber_idx
            emitter.bltz(T1, "fib_yield_ret")
            emitter.nop

            # Save fiber context: fiber entry at 0x70002000 + (idx * 32)
            emitter.sll(T2, T1, 5) # idx * 32
            emitter.ori(T3, T0, 0x2000)
            emitter.addu(T3, T3, T2)
            emitter.sw(RA, 12, T3) # save resume PC = RA
            emitter.sw(SP, 16, T3) # save SP
            emitter.sw(FP, 20, T3) # save FP
 
            # Restore scheduler context from 0x70000380
            emitter.lw(RA, 0x380, T0)
            emitter.lw(SP, 0x384, T0)
            emitter.lw(S0, 0x388, T0)
            emitter.lw(S1, 0x38C, T0)
            emitter.lw(S2, 0x390, T0)
            emitter.lw(FP, 0x394, T0)

            # Switch back to scheduler loop
            emitter.jump("step_fib_next")
            emitter.nop

            emitter.label("fib_yield_ret")
            emitter.jr(RA)
            emitter.nop

          when "Citrine_StepFibers"
            # Save scheduler context at 0x70000380
            emitter.lui(T0, 0x7000)
            emitter.sw(RA, 0x380, T0)
            emitter.sw(SP, 0x384, T0)
            emitter.sw(S0, 0x388, T0)
            emitter.sw(S1, 0x38C, T0)
            emitter.sw(S2, 0x390, T0)
            emitter.sw(FP, 0x394, T0)

            emitter.move(S0, ZERO) # loop index = 0

            emitter.label("step_fib_loop")
            emitter.lui(T0, 0x7000)
            emitter.lw(S1, 0x88, T0) # fiber_count
            emitter.sltu(T2, S0, S1)
            emitter.beqz(T2, "step_fib_done")
            emitter.nop

            # Check if fiber S0 is ready
            emitter.sll(T2, S0, 5) # S0 * 32
            emitter.ori(T3, T0, 0x2000)
            emitter.addu(T3, T3, T2)
            emitter.lw(T4, 8, T3) # state
            emitter.beqz(T4, "step_fib_next")
            emitter.nop

            # Mark current_fiber_idx = S0
            emitter.sw(S0, 0x84, T0)

            # Load fiber context
            emitter.lw(T9, 12, T3) # resume PC
            emitter.lw(SP, 16, T3) # fiber SP
            emitter.lw(FP, 20, T3) # fiber FP

            # Set up return address to exit trampoline if fiber terminates
            emitter.la(RA, "citrine_fiber_exit")

            # Jump to fiber resume PC
            emitter.jr(T9)
            emitter.nop

            # Label reached after fiber yields
            emitter.label("step_fib_next")
            emitter.lui(T0, 0x7000)
            emitter.lw(S0, 0x84, T0) # load current fiber idx
            emitter.addiu(S0, S0, 1) # advance to next fiber
            emitter.jump("step_fib_loop")
            emitter.nop

            emitter.label("step_fib_done")
            # Reset current_fiber_idx = -1
            emitter.lui(T0, 0x7000)
            emitter.li(T1, -1)
            emitter.sw(T1, 0x84, T0)

            # Restore scheduler context
            emitter.lw(RA, 0x380, T0)
            emitter.lw(SP, 0x384, T0)
            emitter.lw(S0, 0x388, T0)
            emitter.lw(S1, 0x38C, T0)
            emitter.lw(S2, 0x390, T0)
            emitter.lw(FP, 0x394, T0)
            emitter.jr(RA)
            emitter.nop

            # Exit handler for fibers that finish without yielding
            emitter.label("citrine_fiber_exit")
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x84, T0) # current_fiber_idx
            emitter.bltz(T1, "fib_exit_ret")
            emitter.nop

            emitter.sll(T2, T1, 5)
            emitter.ori(T3, T0, 0x2000)
            emitter.addu(T3, T3, T2)
            emitter.sw(ZERO, 8, T3) # state = 0 (done)

            # Restore scheduler context
            emitter.lw(RA, 0x380, T0)
            emitter.lw(SP, 0x384, T0)
            emitter.lw(S0, 0x388, T0)
            emitter.lw(S1, 0x38C, T0)
            emitter.lw(S2, 0x390, T0)
            emitter.lw(FP, 0x394, T0)
            emitter.jump("step_fib_next")
            emitter.nop

            emitter.label("fib_exit_ret")
            emitter.jr(RA)
            emitter.nop

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
