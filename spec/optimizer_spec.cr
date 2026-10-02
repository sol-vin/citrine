require "./spec_helper"
require "../src/citrine/compiler/optimizer"
require "../src/citrine/compiler/opcode"

describe Citrine::BytecodeOptimizer do
  it "folds compile-time constant arithmetic (LoadInt + Add -> LoadInt)" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # R0 = 10, R1 = 20, R2 = R0 + R1
    insts = [
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 0_u8, 10_u16),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 1_u8, 20_u16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Add, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::Return, 2_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    # R2 = R0 + R1 should fold to LoadInt R2, 30
    opt.size.should eq(4)
    opt[2].opcode.should eq(Citrine::Opcode::LoadInt)
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
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 1_u8, 0_u16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Add, 2_u8, 0_u8, 1_u8),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 3_u8, 1_u16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Mul, 4_u8, 0_u8, 3_u8),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 5_u8, 0_u16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Mul, 6_u8, 0_u8, 5_u8)
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

    # inst 5 (Mul) -> LoadInt R6, 0
    opt[5].opcode.should eq(Citrine::Opcode::LoadInt)
    opt[5].dst.should eq(6_u8)
    opt[5].imm16.should eq(0_u16)
  end

  it "eliminates unreachable dead code after Return" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    insts = [
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 0_u8, 42_u16),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::Return, 0_u8, 0_u16),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 1_u8, 99_u16),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::Return, 1_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    # The dead instructions following Return should be stripped
    opt.size.should eq(2)
    opt[0].opcode.should eq(Citrine::Opcode::LoadInt)
    opt[0].imm16.should eq(42_u16)
    opt[1].opcode.should eq(Citrine::Opcode::Return)
  end

  it "eliminates redundant self-moves: Move R, R -> NOP (compacted away)" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    insts = [
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, 0_u8, 100_u16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Move, 0_u8, 0_u8, 0_u8),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::Return, 0_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    opt.size.should eq(2)
    opt[0].opcode.should eq(Citrine::Opcode::LoadInt)
    opt[1].opcode.should eq(Citrine::Opcode::Return)
  end

  it "updates jump target offsets accurately when compacting NOPs" do
    constants = [] of Citrine::ConstValue
    optimizer = Citrine::BytecodeOptimizer.new(constants, opt_level: 1)

    # Jump offset +2, passing over a NOP, landing on Return
    # 0: Jump +2 (target idx 0 + 1 + 2 = 3)
    # 1: Nop
    # 2: Nop
    # 3: Return
    # After dropping two NOPs:
    # 0: Jump +0 (target idx 0 + 1 + 0 = 1)
    # 1: Return
    insts = [
      Citrine::Instruction.encode_branch(Citrine::Opcode::Jump, 0_u8, 2_i16),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Nop, 0_u8, 0_u8, 0_u8),
      Citrine::Instruction.encode_abc(Citrine::Opcode::Nop, 0_u8, 0_u8, 0_u8),
      Citrine::Instruction.encode_ab_imm(Citrine::Opcode::Return, 0_u8, 0_u16)
    ]

    opt = optimizer.optimize(insts)
    opt.size.should eq(2)
    opt[0].opcode.should eq(Citrine::Opcode::Jump)
    # New target is idx 1, so offset from idx 0 is 1 - (0 + 1) = 0
    opt[0].imm16.should eq(0_u16)
    opt[1].opcode.should eq(Citrine::Opcode::Return)
  end
end
