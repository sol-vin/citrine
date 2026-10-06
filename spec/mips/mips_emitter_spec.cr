require "../spec_helper"
require "../../src/citrine/mips/mips_emitter"

describe "Citrine MIPS R5900 Emitter Suite" do
  it "encodes basic ALU and branch instructions" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter.nop
    emitter.ori(Citrine::MIPS::T0, Citrine::MIPS::ZERO, 42)
    emitter.lui(Citrine::MIPS::T1, 0x1234)
    emitter.words.size.should eq 3
    emitter.words[0].should eq 0x00000000_u32
  end

  it "optimizes branch delay slots by filling independent preceding instruction" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter.ori(Citrine::MIPS::T0, Citrine::MIPS::ZERO, 5) # cand (writes T0)
    emitter.j("target")                                    # branch (reads none)
    emitter.nop                                           # delay slot nop
    emitter.label("target")
    emitter.nop

    initial_size = emitter.words.size # 4 words
    optimized = emitter.optimize_delay_slots!
    optimized.should eq 1
    emitter.words.size.should eq(initial_size - 1) # 3 words

    # Instruction 0 should now be j "target"
    # Instruction 1 should now be ori T0, ZERO, 5 (in delay slot!)
    # Instruction 2 should be nop (at label "target")
    emitter.words[1].should eq((0x0D_u32 << 26) | (Citrine::MIPS::T0.to_u32 << 16) | 5_u32)
    emitter.resolve!
    # Target address was shifted from 0x0010000C to 0x00100008
    emitter.labels["target"].should eq 0x00100008_u32
    target_encoded = 0x08000000_u32 | ((0x00100008_u32 >> 2) & 0x03FFFFFF_u32)
    emitter.words[0].should eq target_encoded
  end

  it "preserves nop when candidate writes register read by branch condition" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter.addiu(Citrine::MIPS::T1, Citrine::MIPS::ZERO, 1) # writes T1
    emitter.bnez(Citrine::MIPS::T1, "target")                # reads T1!
    emitter.nop                                             # delay slot nop
    emitter.label("target")
    emitter.nop

    optimized = emitter.optimize_delay_slots!
    optimized.should eq 0 # Must NOT fill delay slot due to dependency!
    emitter.words.size.should eq 4
    emitter.words[2].should eq 0_u32 # nop preserved
  end

  it "preserves nop when candidate conflicts with jal link register RA" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter.lw(Citrine::MIPS::RA, 28, Citrine::MIPS::SP) # writes RA
    emitter.jal("func")                                  # jal writes RA!
    emitter.nop
    emitter.label("func")
    emitter.nop

    optimized = emitter.optimize_delay_slots!
    optimized.should eq 0 # Conflicting RA write/read
    emitter.words.size.should eq 4
    emitter.words[2].should eq 0_u32
  end

  it "preserves nop when label targets candidate or delay slot" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter.label("loop_entry")
    emitter.ori(Citrine::MIPS::T0, Citrine::MIPS::ZERO, 10)
    emitter.j("loop_entry")
    emitter.nop

    optimized = emitter.optimize_delay_slots!
    optimized.should eq 0 # Label loop_entry targets candidate, cannot relocate
    emitter.words.size.should eq 3
    emitter.words[2].should eq 0_u32
  end

  it "encodes lq and sq 128-bit quadword instructions and optimizes into delay slots" do
    emitter = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    # lq V0, 16(K0) -> opcode 0x1E, base K0(26), rt V0(2), offset 16
    emitter.lq(Citrine::MIPS::V0, 16, Citrine::MIPS::K0)
    expected_lq = (0x1E_u32 << 26) | (26_u32 << 21) | (2_u32 << 16) | 16_u32
    emitter.words[0].should eq expected_lq

    # sq V1, 32(K0) -> opcode 0x1F, base K0(26), rt V1(3), offset 32
    emitter.sq(Citrine::MIPS::V1, 32, Citrine::MIPS::K0)
    expected_sq = (0x1F_u32 << 26) | (26_u32 << 21) | (3_u32 << 16) | 32_u32
    emitter.words[1].should eq expected_sq

    # Test delay slot optimization with independent lq
    emitter2 = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter2.lq(Citrine::MIPS::V0, 16, Citrine::MIPS::K0) # cand writes V0
    emitter2.j("target")                                  # jump
    emitter2.nop
    emitter2.label("target")
    emitter2.nop

    opt = emitter2.optimize_delay_slots!
    opt.should eq 1
    emitter2.words[1].should eq expected_lq # lq moved into delay slot!

    # Test RAW hazard with lq writing register tested by branch
    emitter3 = Citrine::MIPS::MipsEmitter.new(0x00100000_u32)
    emitter3.lq(Citrine::MIPS::V0, 16, Citrine::MIPS::K0) # cand writes V0
    emitter3.bnez(Citrine::MIPS::V0, "target")            # branch reads V0!
    emitter3.nop
    emitter3.label("target")
    emitter3.nop

    opt3 = emitter3.optimize_delay_slots!
    opt3.should eq 0 # Preserves nop due to RAW hazard on V0!
    emitter3.words[2].should eq 0_u32
  end
end
