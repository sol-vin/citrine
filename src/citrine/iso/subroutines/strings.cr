module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_strings_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?) : Bool
        case sname
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
          # If T2 >= 0x007F0000, wrap back to 0x00600000
          emitter.lui(T3, 0x007F)
          emitter.sltu(T3, T2, T3)
          emitter.bnez(T3, "str_alloc_nowrap")
          emitter.nop
          emitter.lui(T2, 0x0060)
          emitter.label("str_alloc_nowrap")
          emitter.sw(T2, 0xA0, T0)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_StrCmp" # A0 = s1, A1 = s2 -> V0 = (s1 == s2 ? 1 : 0)
          emitter.beq(A0, A1, "strcmp_eq")
          emitter.nop
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.bnez(T1, "strcmp_ne")
          emitter.nop
          emitter.sltu(T1, A1, T0)
          emitter.bnez(T1, "strcmp_ne")
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
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "upcase_has_str")
          emitter.nop
          emitter.move(V0, A0)
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
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "downcase_has_str")
          emitter.nop
          emitter.move(V0, A0)
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
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "strip_has_str")
          emitter.nop
          emitter.move(V0, A0)
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
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.bnez(T1, "inc_no_match")
          emitter.nop
          emitter.sltu(T1, A1, T0)
          emitter.bnez(T1, "inc_no_match")
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
        when "Citrine_StringConcat" # A0 = s1, A1 = s2 -> V0 = result_str
          # Guard against invalid pointers (< 0x00100000)
          emitter.lui(T0, 0x0010)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "concat_a0_valid")
          emitter.nop
          # A0 is invalid (< 0x00100000). Check A1:
          emitter.sltu(T2, A1, T0)
          emitter.bnez(T2, "concat_both_invalid")
          emitter.nop
          emitter.move(V0, A1)
          emitter.jr(RA)
          emitter.nop
          emitter.label("concat_both_invalid")
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop

          emitter.label("concat_a0_valid")
          # A0 is valid. Check A1:
          emitter.sltu(T2, A1, T0)
          emitter.beqz(T2, "concat_both_ok")
          emitter.nop
          # A1 is invalid, return A0
          emitter.move(V0, A0)
          emitter.jr(RA)
          emitter.nop

          emitter.label("concat_both_ok")
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.sw(S0, 24, SP)
          emitter.sw(S1, 20, SP)
          emitter.sw(S2, 16, SP)
          emitter.move(S0, A0)
          emitter.move(S1, A1)

          # Measure s1 length
          emitter.move(T0, S0)
          emitter.move(T1, ZERO)
          emitter.label("concat_len1_loop")
          emitter.lbu(T2, 0, T0)
          emitter.beqz(T2, "concat_len1_done")
          emitter.nop
          emitter.addiu(T1, T1, 1)
          emitter.addiu(T0, T0, 1)
          emitter.jump("concat_len1_loop")
          emitter.nop
          emitter.label("concat_len1_done")

          # Measure s2 length
          emitter.move(T0, S1)
          emitter.move(T3, ZERO)
          emitter.label("concat_len2_loop")
          emitter.lbu(T2, 0, T0)
          emitter.beqz(T2, "concat_len2_done")
          emitter.nop
          emitter.addiu(T3, T3, 1)
          emitter.addiu(T0, T0, 1)
          emitter.jump("concat_len2_loop")
          emitter.nop
          emitter.label("concat_len2_done")

          # Total buffer size = len1 + len2 + 1
          emitter.addu(A0, T1, T3)
          emitter.addiu(A0, A0, 1)
          emitter.call("Citrine_StringAlloc")

          # Destination pointer in V0 -> copy to T0
          emitter.move(T0, V0)
          emitter.move(S2, V0) # preserve result in S2

          # Copy s1
          emitter.move(T1, S0)
          emitter.label("concat_copy1_loop")
          emitter.lbu(T2, 0, T1)
          emitter.beqz(T2, "concat_copy1_done")
          emitter.nop
          emitter.sb(T2, 0, T0)
          emitter.addiu(T1, T1, 1)
          emitter.addiu(T0, T0, 1)
          emitter.jump("concat_copy1_loop")
          emitter.nop
          emitter.label("concat_copy1_done")

          # Copy s2
          emitter.move(T1, S1)
          emitter.label("concat_copy2_loop")
          emitter.lbu(T2, 0, T1)
          emitter.beqz(T2, "concat_copy2_done")
          emitter.nop
          emitter.sb(T2, 0, T0)
          emitter.addiu(T1, T1, 1)
          emitter.addiu(T0, T0, 1)
          emitter.jump("concat_copy2_loop")
          emitter.nop
          emitter.label("concat_copy2_done")

          # Null terminate
          emitter.sb(ZERO, 0, T0)

          emitter.move(V0, S2)
          emitter.lw(S2, 16, SP)
          emitter.lw(S1, 20, SP)
          emitter.lw(S0, 24, SP)
          emitter.lw(RA, 28, SP)
          emitter.jr(RA)
          emitter.addiu(SP, SP, 32)
        when "Citrine_ToString" # A0 = int_val
          # Converts integer to ASCII decimal string in rotating 16-slot ring at 0x70003200..0x70003300
          emitter.lui(T0, 0x7000)
          emitter.lw(T2, 0xA4, T0)
          emitter.addiu(T2, T2, 1)
          emitter.andi(T2, T2, 0x0F) # 16 rotating slots (0..15)
          emitter.sw(T2, 0xA4, T0)
          emitter.sll(T2, T2, 4) # slot * 16 bytes
          emitter.ori(T0, T0, 0x3200)
          emitter.addu(T0, T0, T2) # T0 = slot buffer base

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
          emitter.addiu(T3, T0, 15) # last byte of slot
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
        else
          return false
        end
        true
      end
    end
  end
end
