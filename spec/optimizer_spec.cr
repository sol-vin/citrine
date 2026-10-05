require "./spec_helper"
require "../src/citrine/compiler/optimizer"
require "../src/citrine/compiler/opcode"

describe Citrine::BytecodeOptimizer do
  it "folds compile-time constant arithmetic (LoadInt + Add -> LoadInt)" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # R0 = 10, R1 = 20, R2 = R0 + R1
    insts = [
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 0_u8, 10_u16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 1_u8, 20_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Add, Citrine::AddSubOp::AddI32.value, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::Return, Citrine::ReturnSubOp::Val.value, 2_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    # R2 = R0 + R1 should fold to LoadInt R2, 30
    opt.size.should eq(4)
    opt[2].opcode.should eq(Citrine::Opcode::LoadImm)
    opt[2].subop.should eq(Citrine::LoadImmSubOp::Int16.value)
    opt[2].dst.should eq(2_u8)
    opt[2].imm16.should eq(30_u16)
  end

  it "simplifies algebraic identities: x + 0 -> x, x * 1 -> x, x * 0 -> 0" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # R1 = 0, R2 = R0 + R1 (should simplify to Move R2, R0)
    # R3 = 1, R4 = R0 * R3 (should simplify to Move R4, R0)
    # R5 = 0, R6 = R0 * R5 (should fold to LoadInt R6, 0)
    insts = [
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 1_u8, 0_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Add, Citrine::AddSubOp::AddI32.value, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 3_u8, 1_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Mul, Citrine::MulSubOp::MulLo.value, 4_u8, 0_u8, 3_u8),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 5_u8, 0_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Mul, Citrine::MulSubOp::MulLo.value, 6_u8, 0_u8, 5_u8)
    ]

    opt = optimizer.optimize(insts)
    # inst 1 (Add) -> Move R2, R0
    opt[1].opcode.should eq(Citrine::Opcode::Move)
    opt[1].dst.should eq(2_u8)
    opt[1].a.should eq(0_u8)

    # inst 3 (Mul) -> Move R4, R0
    opt[3].opcode.should eq(Citrine::Opcode::Move)
    opt[3].dst.should eq(4_u8)
    opt[3].a.should eq(0_u8)

    # inst 5 (Mul) -> LoadImm R6, 0
    opt[5].opcode.should eq(Citrine::Opcode::LoadImm)
    opt[5].dst.should eq(6_u8)
    opt[5].imm16.should eq(0_u16)
  end

  it "eliminates unreachable dead code after Return" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    insts = [
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 0_u8, 42_u16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::Return, Citrine::ReturnSubOp::Val.value, 0_u8, 0_u16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 1_u8, 99_u16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::Return, Citrine::ReturnSubOp::Val.value, 1_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    opt.size.should eq(2)
    opt[0].opcode.should eq(Citrine::Opcode::LoadImm)
    opt[0].imm16.should eq(42_u16)
    opt[1].opcode.should eq(Citrine::Opcode::Return)
  end

  it "eliminates redundant self-moves: Move R, R -> NOP (compacted away)" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    insts = [
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 0_u8, 100_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Move, Citrine::MoveSubOp::Move32.value, 0_u8, 0_u8, 0_u8),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::Return, Citrine::ReturnSubOp::Val.value, 0_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    opt.size.should eq(2)
    opt[0].opcode.should eq(Citrine::Opcode::LoadImm)
    opt[1].opcode.should eq(Citrine::Opcode::Return)
  end

  it "fuses Compare + BranchZ into OP_BRANCH_CMP" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # 0: Compare.Eq R2 = (R0 == R1)
    # 1: BranchZ.Truthy if R2 goto +4
    insts = [
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Compare, Citrine::CompareSubOp::Eq.value, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_branch_rel(Citrine::Opcode::BranchZ, Citrine::BranchZSubOp::Truthy.value, 2_u8, 4_i16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 3_u8, 10_u16),
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::Return, Citrine::ReturnSubOp::Val.value, 3_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    # The Compare + BranchZ should fuse into a single BranchCmp.Beq, with Nop compacted away!
    opt[0].opcode.should eq(Citrine::Opcode::BranchCmp)
    opt[0].subop.should eq(Citrine::BranchCmpSubOp::Beq.value)
    opt[0].dst.should eq(0_u8) # RegA
    opt[0].a.should eq(1_u8)   # RegB
  end

  it "fuses Sub(reg, 1) + BranchZ into OP_LOOP_DEC_BR" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # R1 = 1
    # Loop body...
    # Sub R0, R0, R1 (R0 = R0 - 1)
    # BranchZ.Nonzero R0, -5
    insts = [
      Citrine::Instruction.encode_r_imm(Citrine::Opcode::LoadImm, Citrine::LoadImmSubOp::Int16.value, 1_u8, 1_u16),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Sub, Citrine::SubSubOp::SubI32.value, 0_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_branch_rel(Citrine::Opcode::BranchZ, Citrine::BranchZSubOp::Nonzero.value, 0_u8, -5_i16)
    ]

    opt = optimizer.optimize(insts)
    # inst 1 (Sub) and inst 2 (BranchZ) fuse into single LoopDecBr.DecBrNz
    opt.any? { |i| i.opcode == Citrine::Opcode::LoopDecBr && i.subop == Citrine::LoopDecBrSubOp::DecBrNz.value }.should be_true
  end

  it "fuses Mul + Add into OP_FUSED_MADD" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # R2 = R0 * R1
    # R3 = R3 + R2 (dst = dst + prod)
    insts = [
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Mul, Citrine::MulSubOp::MulLo.value, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_rrr(Citrine::Opcode::Add, Citrine::AddSubOp::AddI32.value, 3_u8, 3_u8, 2_u8)
    ]

    opt = optimizer.optimize(insts)
    opt.size.should eq(1)
    opt[0].opcode.should eq(Citrine::Opcode::FusedMadd)
    opt[0].subop.should eq(Citrine::FusedMaddSubOp::MaddI32.value)
    opt[0].dst.should eq(3_u8)
    opt[0].a.should eq(0_u8)
    opt[0].b.should eq(1_u8)
  end
end
