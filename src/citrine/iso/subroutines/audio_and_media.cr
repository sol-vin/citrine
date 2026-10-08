module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_audio_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?) : Bool
        case sname
        when "Citrine_LoadSound"
          emitter.ori(V0, ZERO, 1) # Return sound handle 1
          emitter.jr(RA)
          emitter.nop
        when "Citrine_PlaySound", "Citrine_PlayCDDA"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)

          # If A0 >= 0x00100000, it might be a string pointer ("track01.cas")
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.bnez(T1, "cdda_idx_check")
          emitter.nop

          # Parse string: check 2 digits at A0 + 5, 6
          emitter.lbu(T2, 5, A0) # tens digit e.g. '0'
          emitter.lbu(T3, 6, A0) # ones digit e.g. '1'
          emitter.addiu(T2, T2, -0x30)
          emitter.addiu(T3, T3, -0x30)
          emitter.li(T4, 10)
          emitter.mult(T2, T4)
          emitter.mflo(T2)
          emitter.addu(A0, T2, T3)  # track_num (1-based: 1..N)
          emitter.addiu(A0, A0, -1) # convert to 0-based index (0..N-1)
          emitter.bgez(A0, "cdda_map_track")
          emitter.nop
          emitter.move(A0, ZERO)
          emitter.jump("cdda_map_track")
          emitter.nop

          emitter.label("cdda_idx_check")
          # If A0 >= 0x0100, pass directly (direct track cmd)
          emitter.ori(T0, ZERO, 0x0100)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "cdda_play_entry")
          emitter.nop

          # Map 0-based stream track index: 0x0100 | (A0 & 0xFF)
          emitter.label("cdda_map_track")
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
        when "Citrine_PauseStream"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.ori(A0, ZERO, 2) # cmd 2 = Pause
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.ori(V0, ZERO, 1)
          emitter.lw(RA, 28, SP)
          emitter.jr(RA)
          emitter.addiu(SP, SP, 32)
        when "Citrine_ResumeStream"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.ori(A0, ZERO, 3) # cmd 3 = Resume
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.ori(V0, ZERO, 1)
          emitter.lw(RA, 28, SP)
          emitter.jr(RA)
          emitter.addiu(SP, SP, 32)
        when "Citrine_CdvdSeekEntropy"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.sw(S0, 24, SP)
          emitter.sw(S1, 20, SP)

          # S0 = pre-seek cycle count
          emitter.emit((0x10_u32 << 26) | (16_u32 << 16) | (9_u32 << 11)) # mfc0 S0, Count

          # Format seek command: 0x53000000 | (A0 & 0x00FFFFFF)
          emitter.bnez(A0, "cdvd_seek_has_lba")
          emitter.nop
          emitter.sll(A0, S0, 3)
          emitter.label("cdvd_seek_has_lba")
          emitter.lui(T0, 0x00FF)
          emitter.ori(T0, T0, 0xFFFF)
          emitter.and_(A0, A0, T0)
          emitter.lui(T0, 0x5300)
          emitter.or_(A0, A0, T0)

          # Trigger seek via Sound SIF RPC
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop

          # S1 = post-seek cycle count
          emitter.emit((0x10_u32 << 26) | (17_u32 << 16) | (9_u32 << 11)) # mfc0 S1, Count
          emitter.subu(V0, S1, S0)                                        # V0 = physical seek cycle latency!

          # Mix into SPRAM entropy accumulator 0x700000E0
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0xE0, T0)
          emitter.xor_(T1, T1, V0)
          emitter.lui(T2, 0x9E37)
          emitter.ori(T2, T2, 0x79B9)
          emitter.multu(T1, T2)
          emitter.mflo(T1)
          emitter.sw(T1, 0xE0, T0)

          emitter.lw(S1, 20, SP)
          emitter.lw(S0, 24, SP)
          emitter.lw(RA, 28, SP)
          emitter.jr(RA)
          emitter.addiu(SP, SP, 32)
        else
          return false
        end
        true
      end
    end
  end
end
