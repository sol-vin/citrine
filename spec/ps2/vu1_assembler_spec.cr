require "../spec_helper"
require "../../src/citrine/core/vu1"

describe "Citrine::Core::VU1 (Dual-Issue 64-Bit Assembler, Hazard Detector & VIF1 Packer)" do
  describe "Dual-Issue 64-Bit VLIW Instruction Encoding" do
    it "encodes canonical NOP | NOP and [E]-bit termination words" do
      nop = Citrine::Core::VU1::MicroInstruction.nop
      nop.upper.encode.should eq(0x000002FF_u32)
      nop.lower.encode.should eq(0x8000033C_u32)
      nop.encode.should eq(0x000002FF_8000033C_u64)

      end_nop = Citrine::Core::VU1::MicroInstruction.nop(flag_e: true)
      (end_nop.upper.encode & (1_u32 << 30)).should_not eq(0_u32)
    end

    it "assembles dual-issue Upper FMAC and Lower Load/Store/ALU/XGKICK instructions" do
      program = Citrine::Core::VU1::Assembler.assemble(<<-VSM)
        ; Matrix-vector transform + GIF kick microprogram
        NOP | LQ.xyzw vf01, 0(vi01)
        NOP | LQ.xyzw vf02, 1(vi01)
        NOP | LQ.xyzw vf03, 2(vi01)
        NOP | LQ.xyzw vf04, 3(vi01)
        NOP | LQ.xyzw vf05, 4(vi01)
        MULAx.xyzw ACC, vf01, vf05 | IADDIU vi02, vi00, 16
        MADDAy.xyzw ACC, vf02, vf05 | NOP
        MADDAz.xyzw ACC, vf03, vf05 | NOP
        MADDw.xyzw vf06, vf04, vf05 | NOP
        NOP | NOP
        NOP | NOP
        NOP | NOP
        FTOI4.xyzw vf07, vf06 | NOP
        NOP | NOP
        NOP | NOP
        NOP | NOP
        NOP | SQ.xyzw vf07, 0(vi02)
        NOP | XGKICK vi02
        NOP[E] | NOP
        NOP | NOP
      VSM

      program.size.should eq(20)
      program.byte_size.should eq(160)
      program.hazard_report.clean?.should be_true
      program.hazard_report.stall_cycles.should eq(0)

      slice = program.to_slice
      slice.size.should eq(160)
    end

    it "encodes LOI 32-bit IEEE-754 float immediate in Lower slot with Upper I-bit set" do
      program = Citrine::Core::VU1::Assembler.assemble(<<-VSM)
        NOP | LOI 2.5
        ADDi.xyzw vf01, vf00 | NOP
      VSM

      program.size.should eq(2)
      first = program.instructions[0]
      first.upper.flag_i?.should be_true
      first.lower.encode.should eq(2.5_f32.unsafe_as(UInt32))
      (first.upper.encode & 0x80000000_u32).should eq(0x80000000_u32)
    end

    it "resolves forward and backward symbolic branch labels into 11-bit relative offsets" do
      program = Citrine::Core::VU1::Assembler.assemble(<<-VSM)
        NOP | IADDIU vi01, vi00, 4
        NOP | B skip_init
        NOP | NOP
      loop_top:
        ADD.xyzw vf01, vf01, vf02 | IADDI vi01, vi01, -1
      skip_init:
        NOP | NOP
        NOP | IBNE vi01, vi00, loop_top
        NOP | NOP
      VSM

      program.labels["loop_top"].should eq(3)
      program.labels["skip_init"].should eq(4)
      # At PC 1 (`B skip_init`), relative offset = 4 - 1 - 1 = 2
      program.instructions[1].lower.imm.should eq(2)
      # At PC 5 (`IBNE vi01, vi00, loop_top`), relative offset = 3 - 5 - 1 = -3
      program.instructions[5].lower.imm.should eq(-3)
    end
  end

  describe "Compile-Time & Assembly-Time Register Hazard Detection" do
    it "verifies non-conflicting and disjoint-component dual-issue pairs via static_dual_issue macro" do
      # Disjoint components on vf01: Upper writes .xy, Lower writes .zw
      inst = Citrine::Core::VU1.static_dual_issue(
        ADD, :xy, 1, 2, 3,
        LQ, :zw, 1, 0, 1, 0
      )
      inst.upper.fd.should eq(1_u8)
      inst.lower.vf_dest.should eq(1_u8)
      Citrine::Core::VU1::HazardDetector.check_pair(inst.upper, inst.lower).should be_empty
    end

    it "detects same-cycle VF register write-write conflicts (SameCycleVfWrite)" do
      expect_raises(Citrine::Core::VU1::HazardError, /Dual-issue write conflict on vf03/) do
        Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
          ADD.xyzw vf03, vf01, vf02 | LQ.xyzw vf03, 0(vi01)
        VSM
      end

      # Disjoint masks (.xy vs .zw) on the same VF register must NOT trigger a hazard
      clean_prog = Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
        ADD.xy vf03, vf01, vf02 | LQ.zw vf03, 0(vi01)
      VSM
      clean_prog.hazard_report.has_errors?.should be_false
    end

    it "detects VI -> Branch 1-cycle pipeline hazard (ViBranchHazard)" do
      expect_raises(Citrine::Core::VU1::HazardError, /VI branch hazard on vi01/) do
        Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
        loop:
          NOP | IADDI vi01, vi01, -1
          NOP | IBNE vi01, vi00, loop
          NOP | NOP
        VSM
      end
    end

    it "detects unwaited FDIV Q-register read hazard (QRegisterHazard) and clears with WAITQ" do
      expect_raises(Citrine::Core::VU1::HazardError, /reads Q register/) do
        Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
          NOP | DIV Q, vf00.w, vf01.w
          MULq.xyzw vf02, vf01 | NOP
        VSM
      end

      waited = Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
        NOP | DIV Q, vf00.w, vf01.w
        NOP | WAITQ
        MULq.xyzw vf02, vf01 | NOP
      VSM
      waited.hazard_report.has_errors?.should be_false
      waited.hazard_report.stall_cycles.should eq(6)
    end

    it "calculates FMAC 4-cycle RAW interlock stall cycles" do
      prog = Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: false)
        ADD.xyzw vf01, vf02, vf03 | NOP
        MUL.xyzw vf04, vf01, vf05 | NOP
      VSM

      prog.hazard_report.has_errors?.should be_false
      prog.hazard_report.warnings.size.should eq(1)
      prog.hazard_report.warnings[0].kind.should eq(Citrine::Core::VU1::HazardKind::FmacRawHazard)
      prog.hazard_report.stall_cycles.should eq(3)
      prog.hazard_report.total_estimated_cycles.should eq(5)
    end

    it "detects branch inside branch delay slot (BranchDelaySlotHazard)" do
      expect_raises(Citrine::Core::VU1::HazardError, /delay slot/) do
        Citrine::Core::VU1::Assembler.assemble(<<-VSM, strict_hazards: true)
        target:
          NOP | B target
          NOP | B target
        VSM
      end
    end
  end

  describe "VIF1 Packet Packer (MPG, UNPACK, MSCAL, FLUSH)" do
    it "packs MPG, UNPACK, MSCAL, and FLUSH into a 16-byte aligned VIF1 DMA packet" do
      prog = Citrine::Core::VU1::Assembler.assemble(<<-VSM)
        NOP | LQ.xyzw vf01, 0(vi00)
        NOP | XGKICK vi00
        NOP[E] | NOP
        NOP | NOP
      VSM

      packer = Citrine::Core::VU1::VifPacketPacker.new(capacity_qwc: 64)
      packer.flush
      packer.stcycl(1_u8, 1_u8)
      packer.base(0_u16)
      packer.offset(512_u16)
      packer.mpg(prog.instructions, dst_addr: 0_u16)

      # Unpack 2 quadwords (8 floats) to VU1 data memory address 0
      floats = [
        1.0_f32, 2.0_f32, 3.0_f32, 1.0_f32,
        4.0_f32, 5.0_f32, 6.0_f32, 1.0_f32,
      ]
      packer.unpack_floats(0_u16, floats, format: Citrine::Core::VU1::UnpackFormat::V4_32, use_tops: true)
      packer.mscal(0_u16)
      packer.flush

      slice = packer.to_slice
      (slice.size % 16).should eq(0)
      packer.qword_aligned?.should be_true

      # Verify VIFcodes in stream:
      # Word 0: FLUSH (0x11000000)
      # Word 1: STCYCL (0x01000101)
      # Word 2: BASE (0x03000000)
      # Word 3: OFFSET (0x02000200)
      # Word 4: MPG (4 instructions at addr 0 -> 0x4A040000)
      packer.word_at(0).should eq(0x11000000_u32)
      packer.word_at(1).should eq(0x01000101_u32)
      packer.word_at(2).should eq(0x03000000_u32)
      packer.word_at(3).should eq(0x02000200_u32)
      packer.word_at(4).should eq(0x4A040000_u32)
    end

    it "automatically chunks MPG transfers larger than 256 instructions" do
      assembler = Citrine::Core::VU1::Assembler.new
      300.times { assembler.nop }
      prog = assembler.finalize!

      packer = Citrine::Core::VU1::VifPacketPacker.new(capacity_qwc: 256)
      packer.mpg(prog.instructions, dst_addr: 0_u16)
      slice = packer.to_slice
      (slice.size % 16).should eq(0)

      # First MPG header: 256 instructions encoded as NUM=0x00 at addr 0 -> 0x4A000000
      packer.word_at(0).should eq(0x4A000000_u32)
      # Second MPG header sits after 1 + (256 * 2) = 513 words: 44 instructions at addr 256 (0x0100) -> 0x4A2C0100
      packer.word_at(513).should eq(0x4A2C0100_u32)
    end
  end
end
