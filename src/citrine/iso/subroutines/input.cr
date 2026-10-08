module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_input_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?, button_msg_addrs : Hash(String, UInt32)) : Bool
        case sname
        when "Citrine_ButtonDown"  # A0 = port (0/1), A1 = button index
          emitter.sll(T1, A0, 4)   # port * 16
          emitter.sll(T2, A0, 2)   # port * 4
          emitter.addu(T1, T1, T2) # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 16, T0) # load current buttons from 0x70000010 + port * 20
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
          emitter.lw(V0, 24, T0) # load pressed buttons from 0x70000018 + port * 20
          emitter.srlv(V0, V0, A1)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ButtonReleased" # A0 = port (0/1), A1 = button index
          emitter.sll(T1, A0, 4)      # port * 16
          emitter.sll(T2, A0, 2)      # port * 4
          emitter.addu(T1, T1, T2)    # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 28, T0) # load released buttons from 0x7000001C + port * 20
          emitter.srlv(V0, V0, A1)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_GetAnalog"   # A0 = port, A1 = axis (0=LX, 1=LY, 2=RX, 3=RY)
          emitter.sll(T1, A0, 4)   # port * 16
          emitter.sll(T2, A0, 2)   # port * 4
          emitter.addu(T1, T1, T2) # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 32, T0)  # load word from 0x70000020
          emitter.andi(A1, A1, 3) # clamp axis 0..3
          emitter.sll(T3, A1, 3)  # axis * 8 bits
          emitter.srlv(V0, V0, T3)
          emitter.andi(V0, V0, 0xFF) # 8-bit unsigned analog position (0..255)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_SetRumble" # A0 = port, A1 = small_motor, A2 = large_motor
          emitter.sll(T1, A0, 4)
          emitter.sll(T2, A0, 2)
          emitter.addu(T1, T1, T2)
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.andi(A1, A1, 1)
          emitter.andi(A2, A2, 0xFF)
          emitter.sll(A2, A2, 8)
          emitter.or_(A1, A1, A2)
          emitter.sw(A1, 36, T0) # 0x70000024
          emitter.move(V0, ZERO)
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
        else
          return false
        end
        true
      end
    end
  end
end
