module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_graphics_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?, digit_table_addr : UInt32, font_table_addr : UInt32, texture_table_addr : UInt32, sched_addr : UInt32 = 0_u32, button_msg_addrs : Hash(String, UInt32) = Hash(String, UInt32).new) : Bool
        case sname
        when "Citrine_BeginDrawing"
          emitter.lui(T0, 0x7000)
          emitter.lui(T1, 0x2080)
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
          # If A2 is an IEEE-754 float (> 0x30000000), convert to integer
          emitter.lui(T4, 0x3000)
          emitter.sltu(T5, T4, A2)
          emitter.beqz(T5, "circ_rad_is_int")
          emitter.nop
          emitter.srl(T6, A2, 23)
          emitter.andi(T6, T6, 0xFF)
          emitter.addiu(T6, T6, -127)
          emitter.lui(T7, 0x007F)
          emitter.ori(T7, T7, 0xFFFF)
          emitter.and_(T8, A2, T7)
          emitter.lui(T7, 0x0080)
          emitter.or_(T8, T8, T7)
          emitter.ori(T9, ZERO, 23)
          emitter.subu(T9, T9, T6)
          emitter.srav(A2, T8, T9)
          emitter.label("circ_rad_is_int")
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
          emitter.lui(T2, 0x2080)
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
          emitter.lui(T4, 0x0080)     # MADR = 0x00800000
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

          emitter.lui(T0, 0x7000)
          emitter.lw(T5, 16, T0)   # save Port 0 current buttons
          emitter.sw(T5, 20, T0)   # store Port 0 previous buttons at 0x70000014
          emitter.lw(T6, 36, T0)   # save Port 1 current buttons
          emitter.sw(T6, 40, T0)   # store Port 1 previous buttons at 0x70000028
          emitter.sw(ZERO, 16, T0) # clear current buttons to prevent OR accumulation in pad driver
          emitter.sw(ZERO, 36, T0)

          # Poll DualShock 2 controllers so live pad and analog data stay updated
          emitter.li(T9, PadRuntimePayload::POLL_ENTRY)
          emitter.jalr(T9)
          emitter.nop

          if sched_addr > 0_u32
            # Check Virtual Input Schedule for automated test harnesses
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 4, T0) # T1 = current hardware frame counter
            emitter.li(T8, sched_addr)

            emitter.label("ed_sched_loop")
            emitter.lw(T6, 0, T8) # entry.start_frame
            emitter.li(T5, 0xFFFFFFFF_u32)
            emitter.beq(T6, T5, "ed_sched_done")
            emitter.nop
            emitter.sltu(T7, T1, T6)
            emitter.bnez(T7, "ed_sched_next")
            emitter.nop
            emitter.lhu(T4, 6, T8) # duration_frames
            emitter.addu(T6, T6, T4)
            emitter.sltu(T7, T1, T6)
            emitter.beqz(T7, "ed_sched_next")
            emitter.nop

            # Apply schedule button mask
            emitter.lhu(T4, 4, T8) # button_mask
            emitter.lbu(T3, 8, T8) # port
            emitter.bnez(T3, "ed_sched_apply_p1")
            emitter.nop
            emitter.lw(T7, 16, T0)
            emitter.or_(T7, T7, T4)
            emitter.sw(T7, 16, T0)
            emitter.jump("ed_sched_next")
            emitter.nop

            emitter.label("ed_sched_apply_p1")
            emitter.lw(T7, 36, T0)
            emitter.or_(T7, T7, T4)
            emitter.sw(T7, 36, T0)

            emitter.label("ed_sched_next")
            emitter.addiu(T8, T8, 16)
            emitter.jump("ed_sched_loop")
            emitter.nop

            emitter.label("ed_sched_done")
          end

          # Compute Edge Transitions for Port 0:
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 16, T0)    # live Port 0 current buttons (0x70000010)
          emitter.lw(T5, 20, T0)    # Port 0 previous buttons (0x70000014)
          emitter.nor(T7, T5, ZERO) # ~prev
          emitter.and_(T8, T1, T7)  # newly pressed edges (curr & ~prev)
          emitter.sw(T8, 24, T0)    # store pressed at 0x70000018
          emitter.nor(T7, T1, ZERO) # ~curr
          emitter.and_(T7, T5, T7)  # newly released edges (prev & ~curr)
          emitter.sw(T7, 28, T0)    # store released at 0x7000001C

          # Compute Edge Transitions for Port 1:
          emitter.lw(T2, 36, T0)    # live Port 1 current buttons (0x70000024)
          emitter.lw(T6, 40, T0)    # Port 1 previous buttons (0x70000028)
          emitter.nor(T7, T6, ZERO) # ~prev
          emitter.and_(T9, T2, T7)  # newly pressed edges (curr & ~prev)
          emitter.sw(T9, 44, T0)    # store pressed at 0x7000002C
          emitter.nor(T7, T2, ZERO) # ~curr
          emitter.and_(T7, T6, T7)  # newly released edges (prev & ~curr)
          emitter.sw(T7, 48, T0)    # store released at 0x70000030

          # Check newly pressed button edges for console logging
          unless button_msg_addrs.empty?
            emitter.lw(T8, 24, T0)  # pressed Port 0
            emitter.lw(T6, 44, T0)  # pressed Port 1
            emitter.or_(T8, T8, T6) # combined pressed
            emitter.beqz(T8, "ed_no_btns")
            emitter.nop

            button_masks = [
              {"cross", 0x4000},
              {"triangle", 0x1000},
              {"circle", 0x2000},
              {"square", 0x8000},
              {"r1", 0x0800},
              {"l1", 0x0400},
              {"r2", 0x0200},
              {"l2", 0x0100},
              {"start", 0x0008},
              {"select", 0x0001},
              {"up", 0x0010},
              {"right", 0x0020},
              {"down", 0x0040},
              {"left", 0x0080},
              {"l3", 0x0002},
              {"r3", 0x0004},
            ]
            button_masks.each do |name, mask|
              if addr = button_msg_addrs[name]?
                emitter.andi(T7, T8, mask)
                emitter.beqz(T7, "ed_btn_#{name}")
                emitter.nop
                emitter.li(A0, addr)
                emitter.call("debug_puts")
                emitter.lui(T0, 0x7000)
                emitter.lw(T8, 24, T0)
                emitter.lw(T6, 44, T0)
                emitter.or_(T8, T8, T6)
                emitter.label("ed_btn_#{name}")
              end
            end
            emitter.label("ed_no_btns")
          end

          # Continuously mix live frame entropy into SPRAM 0x700000E0
          # sample = (COP0 Count) ^ (Timer 1 H-Blank) ^ (Pad Buttons)
          emitter.emit((0x10_u32 << 26) | (2_u32 << 16) | (9_u32 << 11)) # mfc0 V0, Count
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 16, T0) # Pad buttons at 0x70000010
          emitter.xor_(V0, V0, T1)
          emitter.lui(T2, 0x1000)
          emitter.lw(T3, 0x0800, T2) # Timer 1 H-Blank at 0x10000800
          emitter.xor_(V0, V0, T3)
          emitter.lw(T4, 0xE0, T0) # entropy pool at 0x700000E0
          emitter.xor_(T4, T4, V0)
          emitter.lui(T5, 0x9E37)
          emitter.ori(T5, T5, 0x79B9) # Golden ratio constant
          emitter.multu(T4, T5)
          emitter.mflo(T4)
          emitter.sw(T4, 0xE0, T0)

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
        when "Citrine_LoadTexture"
          emitter.ori(V0, ZERO, 1) # Return texture handle 1
          emitter.jr(RA)
          emitter.nop
        when "Citrine_DrawTexture" # A0=id, A1=dx, A2=dy, A3=dw, 16(SP)=dh
          if texture_table_addr > 0
            emitter.lui(T0, 0x7000)
            emitter.lw(T1, 0x90, T0)
            emitter.beqz(T1, "draw_tex_ret")
            emitter.nop

            # Load dh from caller's stack
            emitter.lw(T2, 16, SP)

            # Clamp defaults: if dw <= 0, dw = 128; if dh <= 0, dh = 128
            emitter.bgtz(A3, "dtex_w_ok")
            emitter.nop
            emitter.ori(A3, ZERO, 128)
            emitter.label("dtex_w_ok")

            emitter.bgtz(T2, "dtex_h_ok")
            emitter.nop
            emitter.ori(T2, ZERO, 128)
            emitter.label("dtex_h_ok")

            # Save callee-saved registers
            emitter.addiu(SP, SP, -48)
            emitter.sw(RA, 44, SP)
            emitter.sw(S0, 40, SP)
            emitter.sw(S1, 36, SP)
            emitter.sw(S2, 32, SP)
            emitter.sw(S3, 28, SP)
            emitter.sw(S4, 24, SP)
            emitter.sw(S5, 20, SP)
            emitter.sw(S6, 16, SP)
            emitter.sw(S7, 12, SP)
            emitter.sw(T2, 8, SP) # store dest_h in stack slot, leaving FP intact

            emitter.li(T0, texture_table_addr)
            emitter.lw(S0, 0, T0) # grid_res (e.g. 32)
            emitter.lw(S1, 4, T0) # span_count
            emitter.beqz(S1, "draw_tex_cleanup")
            emitter.nop

            emitter.addiu(S2, T0, 8) # span table data pointer
            emitter.move(S3, S1)     # remaining count
            emitter.lui(T0, 0x7000)
            emitter.lw(S4, 0x90, T0) # draw_buf_ptr
            emitter.move(S5, A1)     # dest_x
            emitter.move(S6, A2)     # dest_y
            emitter.move(S7, A3)     # dest_w

            emitter.label("draw_tex_loop")
            # Span entry (8 bytes):
            # 0: gx1 (u8), 1: gy1 (u8), 2: gx2 (u8), 3: gy2 (u8), 4..7: color (u32)
            emitter.lbu(T0, 0, S2) # gx1
            emitter.lbu(T1, 1, S2) # gy1
            emitter.lbu(T2, 2, S2) # gx2
            emitter.lbu(T3, 3, S2) # gy2
            emitter.lw(T4, 4, S2)  # color

            # x1 = dest_x + (gx1 * dest_w) / grid_res
            emitter.multu(T0, S7)
            emitter.mflo(T0)
            emitter.divu(T0, S0)
            emitter.mflo(T0)
            emitter.addu(T0, S5, T0)

            # y1 = dest_y + (gy1 * dest_h) / grid_res
            emitter.lw(T5, 8, SP) # dest_h
            emitter.multu(T1, T5)
            emitter.mflo(T1)
            emitter.divu(T1, S0)
            emitter.mflo(T1)
            emitter.addu(T1, S6, T1)

            # x2 = dest_x + (gx2 * dest_w) / grid_res
            emitter.multu(T2, S7)
            emitter.mflo(T2)
            emitter.divu(T2, S0)
            emitter.mflo(T2)
            emitter.addu(T2, S5, T2)

            # y2 = dest_y + (gy2 * dest_h) / grid_res
            emitter.lw(T5, 8, SP) # dest_h
            emitter.multu(T3, T5)
            emitter.mflo(T3)
            emitter.divu(T3, S0)
            emitter.mflo(T3)
            emitter.addu(T3, S6, T3)

            # Write 64-byte Sprite primitive into S4:
            emitter.ori(T5, ZERO, 6)
            emitter.sw(T5, 0, S4) # PRIM = Sprite
            emitter.sw(ZERO, 4, S4)
            emitter.sw(ZERO, 8, S4)
            emitter.sw(ZERO, 12, S4)
            emitter.sw(T4, 16, S4) # RGBAQ (color)
            emitter.lui(T5, 0x3F80)
            emitter.sw(T5, 20, S4) # Q = 1.0
            emitter.ori(T5, ZERO, 1)
            emitter.sw(T5, 24, S4)
            emitter.sw(ZERO, 28, S4)

            # XYZ2 (x1, y1)
            emitter.sll(T0, T0, 4)
            emitter.andi(T0, T0, 0xFFFF)
            emitter.sll(T1, T1, 4)
            emitter.sll(T1, T1, 16)
            emitter.or_(T0, T0, T1)
            emitter.sw(T0, 32, S4)
            emitter.sw(ZERO, 36, S4)
            emitter.ori(T5, ZERO, 0x0D)
            emitter.sw(T5, 40, S4)
            emitter.sw(ZERO, 44, S4)

            # XYZ2 (x2, y2)
            emitter.sll(T2, T2, 4)
            emitter.andi(T2, T2, 0xFFFF)
            emitter.sll(T3, T3, 4)
            emitter.sll(T3, T3, 16)
            emitter.or_(T2, T2, T3)
            emitter.sw(T2, 48, S4)
            emitter.sw(ZERO, 52, S4)
            emitter.ori(T5, ZERO, 5)
            emitter.sw(T5, 56, S4)
            emitter.sw(ZERO, 60, S4)

            emitter.addiu(S4, S4, 64)
            emitter.addiu(S2, S2, 8)
            emitter.addiu(S3, S3, -1)
            emitter.bnez(S3, "draw_tex_loop")
            emitter.nop

            emitter.label("draw_tex_done")
            # Save updated draw_buf_ptr to 0x70000090
            emitter.lui(T0, 0x7000)
            emitter.sw(S4, 0x90, T0)

            # Add (span_count * 4) to QWC at 0x70000094
            emitter.lw(T1, 0x94, T0)
            emitter.sll(T2, S1, 2)
            emitter.addu(T1, T1, T2)
            emitter.sw(T1, 0x94, T0)

            emitter.label("draw_tex_cleanup")
            emitter.lw(S7, 12, SP)
            emitter.lw(S6, 16, SP)
            emitter.lw(S5, 20, SP)
            emitter.lw(S4, 24, SP)
            emitter.lw(S3, 28, SP)
            emitter.lw(S2, 32, SP)
            emitter.lw(S1, 36, SP)
            emitter.lw(S0, 40, SP)
            emitter.lw(RA, 44, SP)
            emitter.addiu(SP, SP, 48)
          end
          emitter.label("draw_tex_ret")
          emitter.ori(V0, ZERO, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_DrawText" # A0=str_ptr, A1=x, A2=y, A3=font_size, 16(SP)=color
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.bnez(T1, "dt_ret_early")
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x90, T0)
          emitter.beqz(T1, "dt_ret_early")
          emitter.nop

          emitter.lw(T4, 16, SP) # color from caller's frame
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

          # Check newline '\n' (0x0A)
          emitter.ori(T3, ZERO, 0x0A)
          emitter.bne(T2, T3, "dt_check_space")
          emitter.nop
          emitter.move(S1, A1) # reset curr_x to start x
          emitter.ori(T3, ZERO, 8)
          emitter.sllv(T3, T3, A3)
          emitter.addu(S2, S2, T3) # curr_y += 8 << scale_shift
          emitter.addiu(S0, S0, 1)
          emitter.jump("dt_char_loop")
          emitter.nop

          emitter.label("dt_check_space")
          # Check space (0x20)
          emitter.ori(T3, ZERO, 0x20)
          emitter.bne(T2, T3, "dt_render_glyph")
          emitter.nop
          emitter.addu(S1, S1, T6)
          emitter.addiu(S0, S0, 1)
          emitter.jump("dt_char_loop")
          emitter.nop

          emitter.label("dt_render_glyph")
          if font_table_addr > 0
            # Map lowercase 'a' (0x61) .. 'z' (0x7A) to uppercase
            emitter.addiu(T3, T2, -0x61)
            emitter.ori(T5, ZERO, 26)
            emitter.sltu(T5, T3, T5)
            emitter.beqz(T5, "dt_check_ascii")
            emitter.nop
            emitter.addiu(T2, T2, -32)

            emitter.label("dt_check_ascii")
            # Check printable range: 0x20 .. 0x7E (95 characters)
            emitter.addiu(T3, T2, -0x20)
            emitter.ori(T5, ZERO, 95)
            emitter.sltu(T5, T3, T5)
            emitter.bnez(T5, "dt_valid_char")
            emitter.nop
            # Out of range fallback: '?' (0x3F - 0x20 = 31)
            emitter.ori(T3, ZERO, 31)

            emitter.label("dt_valid_char")
            # T3 = char_index (0..94)
            # Offset in table = T3 * 128 (16 quads * 8 bytes = 128 bytes)
            emitter.sll(T5, T3, 7) # T5 = T3 << 7
            emitter.li(T7, font_table_addr)
            emitter.addu(T7, T7, T5) # T7 = src_ptr

            # base_pos = ((curr_y << 4) << 16) | (curr_x << 4)
            emitter.sll(T8, S1, 4)
            emitter.andi(T8, T8, 0xFFFF)
            emitter.sll(T9, S2, 4)
            emitter.sll(T9, T9, 16)
            emitter.or_(T8, T8, T9) # T8 = base_pos

            emitter.ori(T5, ZERO, 16) # up to 16 quads
            emitter.label("dt_quad_loop")
            emitter.lw(T2, 0, T7)            # XYZ3_delta
            emitter.lw(T3, 4, T7)            # XYZ2_delta
            emitter.beqz(T3, "dt_next_char") # 0 marks end of active quads
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

            emitter.addiu(T7, T7, 8)
            emitter.addiu(T5, T5, -1)
            emitter.bnez(T5, "dt_quad_loop")
            emitter.nop
            emitter.jump("dt_next_char")
            emitter.nop
          elsif digit_table_addr > 0
            # Fallback to digit-only table
            emitter.addiu(T3, T2, -0x30)
            emitter.ori(T5, ZERO, 10)
            emitter.sltu(T5, T3, T5)
            emitter.beqz(T5, "dt_draw_glyph_box")
            emitter.nop

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
        else
          return false
        end
        true
      end
    end
  end
end
