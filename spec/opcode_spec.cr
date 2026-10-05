require "./spec_helper"
require "../src/citrine/compiler/opcode"

describe "Citrine-32 ISA & Opcode Specification" do
  it "verifies all 32 primary opcodes are within [0x00, 0x1F]" do
    Citrine::Opcode.values.each do |op|
      op.value.should be <= 0x1F_u8
    end
  end

  it "encodes and decodes RRR format with sub-opcode" do
    # Add.I32 R0 = R1 + R2
    inst = Citrine::Instruction.encode_rrr(
      Citrine::Opcode::Add,
      Citrine::AddSubOp::AddI32.value,
      dst: 0_u8,
      a: 1_u8,
      b: 2_u8
    )

    inst.opcode.should eq(Citrine::Opcode::Add)
    inst.subop.should eq(Citrine::AddSubOp::AddI32.value)
    inst.dst.should eq(0_u8)
    inst.a.should eq(1_u8)
    inst.b.should eq(2_u8)

    # Verify bitfield placement: Opcode at [31:27], SubOp at [26:24]
    expected_word = (0x06_u32 << 27) | (0_u32 << 24) | (0_u32 << 16) | (1_u32 << 8) | 2_u32
    inst.raw.should eq(expected_word)
  end

  it "encodes and decodes R_IMM format" do
    # LoadImm.Int16 R5, 1234
    inst = Citrine::Instruction.encode_r_imm(
      Citrine::Opcode::LoadImm,
      Citrine::LoadImmSubOp::Int16.value,
      dst: 5_u8,
      imm: 1234_u16
    )

    inst.opcode.should eq(Citrine::Opcode::LoadImm)
    inst.subop.should eq(Citrine::LoadImmSubOp::Int16.value)
    inst.dst.should eq(5_u8)
    inst.imm16.should eq(1234_u16)
  end

  it "encodes and decodes BRANCH_REL format with signed 16-bit offset" do
    # BranchZ.Truthy R10, -8
    inst = Citrine::Instruction.encode_branch_rel(
      Citrine::Opcode::BranchZ,
      Citrine::BranchZSubOp::Truthy.value,
      reg: 10_u8,
      offset: -8_i16
    )

    inst.opcode.should eq(Citrine::Opcode::BranchZ)
    inst.subop.should eq(Citrine::BranchZSubOp::Truthy.value)
    inst.dst.should eq(10_u8)
    inst.branch_offset.should eq(-8_i16)
  end

  it "encodes and decodes JUMP_REL24 with full 24-bit memory reach" do
    # Jump +1000000 instructions
    inst = Citrine::Instruction.encode_jump_rel24(1000000)
    inst.opcode.should eq(Citrine::Opcode::Jump)
    inst.subop.should eq(Citrine::JumpSubOp::JumpRel24.value)
    inst.jump_offset24.should eq(1000000)

    # Negative 24-bit jump
    neg_inst = Citrine::Instruction.encode_jump_rel24(-500000)
    neg_inst.opcode.should eq(Citrine::Opcode::Jump)
    neg_inst.jump_offset24.should eq(-500000)
  end

  it "encodes and decodes BRANCH_FUSED (OP_BRANCH_CMP) with 8-bit offset" do
    # BranchCmp.Beq R1, R2, -12
    inst = Citrine::Instruction.encode_branch_cmp(
      Citrine::BranchCmpSubOp::Beq,
      a: 1_u8,
      b: 2_u8,
      offset: -12_i8
    )

    inst.opcode.should eq(Citrine::Opcode::BranchCmp)
    inst.subop.should eq(Citrine::BranchCmpSubOp::Beq.value)
    inst.dst.should eq(1_u8) # RegA in bits [23:16]
    inst.a.should eq(2_u8)   # RegB in bits [15:8]
    inst.offset8.should eq(-12_i8)
  end

  it "encodes and decodes BRANCH_DEC (OP_LOOP_DEC_BR)" do
    # LoopDecBr.DecBrNz R4, -5
    inst = Citrine::Instruction.encode_loop_dec_br(
      Citrine::LoopDecBrSubOp::DecBrNz,
      reg: 4_u8,
      offset: -5_i16
    )

    inst.opcode.should eq(Citrine::Opcode::LoopDecBr)
    inst.subop.should eq(Citrine::LoopDecBrSubOp::DecBrNz.value)
    inst.dst.should eq(4_u8)
    inst.branch_offset.should eq(-5_i16)
  end

  it "encodes and decodes RRR_FUSED (OP_FUSED_MADD)" do
    # FusedMadd.MaddI32 R0 = R0 + (R1 * R2)
    inst = Citrine::Instruction.encode_fused_madd(
      Citrine::FusedMaddSubOp::MaddI32,
      dst: 0_u8,
      a: 1_u8,
      b: 2_u8
    )

    inst.opcode.should eq(Citrine::Opcode::FusedMadd)
    inst.subop.should eq(Citrine::FusedMaddSubOp::MaddI32.value)
    inst.dst.should eq(0_u8)
    inst.a.should eq(1_u8)
    inst.b.should eq(2_u8)
  end

  it "verifies backward compatibility adapters" do
    abc = Citrine::Instruction.encode_abc(Citrine::Opcode::Move, 3_u8, 2_u8, 0_u8)
    abc.opcode.should eq(Citrine::Opcode::Move)
    abc.dst.should eq(3_u8)
    abc.a.should eq(2_u8)

    ab_imm = Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadImm, 7_u8, 42_u16)
    ab_imm.opcode.should eq(Citrine::Opcode::LoadImm)
    ab_imm.dst.should eq(7_u8)
    ab_imm.imm16.should eq(42_u16)
  end
end
