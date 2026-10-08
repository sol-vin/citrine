require "../spec_helper"

describe "Citrine Tier 1: Crystal Language Expressions & Operators Suite" do
  it "compiles deep arithmetic expressions with complex parentheses and precedence" do
    source = <<-CRYSTAL
      def compute(a, b, c, d, e, f)
        r1 = (a + b) * (c - d) + (e * f) - (a / (b + 1))
        r2 = (r1 % 7) * 3 + (a * c * e) - (b * d * f)
        r2
      end
    CRYSTAL

    parser = Citrine::DslParser.new("expr.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("expr.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    String.new(bytes[0, 4]).should eq("CBC2")

    fn = compiler.functions.find { |f| f.name == "compute" }.not_nil!
    opcodes = fn.instructions.map(&.opcode).to_set
    opcodes.should contain(Citrine::Opcode::Add)
    opcodes.should contain(Citrine::Opcode::Sub)
    opcodes.should contain(Citrine::Opcode::Mul)
    opcodes.should contain(Citrine::Opcode::DivMod)
  end

  it "compiles bitwise logic and shifts (&, |, ^, ~, <<, >>)" do
    source = <<-CRYSTAL
      def bit_ops(val, mask)
        a = val & mask
        b = val | mask
        c = val ^ mask
        d = ~val
        e = (val << 3) >> 1
        (a | b | c) ^ (d & e)
      end
    CRYSTAL

    parser = Citrine::DslParser.new("bits.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("bits.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "bit_ops" }.not_nil!
    opcodes = fn.instructions.map(&.opcode).to_set
    opcodes.should contain(Citrine::Opcode::Bitwise)
    opcodes.should contain(Citrine::Opcode::Shift)
  end

  it "compiles unary negation for numbers and booleans" do
    source = <<-CRYSTAL
      def unaries(x, flag)
        neg_x = -x
        inv_flag = !flag
        inv_flag2 = !inv_flag
        neg_x
      end
    CRYSTAL

    parser = Citrine::DslParser.new("unary.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("unary.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "unaries" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Sub && i.subop == Citrine::SubSubOp::NegI32.value }.should be_true
  end

  it "compiles multi-level nested short-circuit expressions" do
    source = <<-CRYSTAL
      def check_access(is_admin, is_moderator, is_active, is_banned)
        can_access = (!is_banned && is_active) && (is_admin || is_moderator)
        can_access
      end
    CRYSTAL

    parser = Citrine::DslParser.new("access.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("access.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "check_access" }.not_nil!
    branches = fn.instructions.select { |i| i.opcode == Citrine::Opcode::BranchZ }
    branches.size.should be >= 3
  end

  it "compiles nested ternary expressions" do
    source = <<-CRYSTAL
      def evaluate_grade(score)
        grade = score >= 90 ? 1 : (score >= 80 ? 2 : (score >= 70 ? 3 : 4))
        grade
      end
    CRYSTAL

    parser = Citrine::DslParser.new("grade.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("grade.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "evaluate_grade" }.not_nil!
    branches = fn.instructions.select { |i| i.opcode == Citrine::Opcode::BranchZ || i.opcode == Citrine::Opcode::BranchCmp }
    branches.size.should be >= 3
  end

  it "compiles single-precision floating-point arithmetic and conversions" do
    source = <<-CRYSTAL
      def float_calc(x, y)
        fx = x.to_f32
        fy = y.to_f32
        fsum = fx + fy
        fprod = fx * fy
        fdiv = fx / fy
        fres = fsum + fprod - fdiv
        fres.to_i32
      end
    CRYSTAL

    parser = Citrine::DslParser.new("floats.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("floats.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "float_calc" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::FloatAlu }.should be_true
  end

  it "compiles numeric clamp expressions" do
    source = <<-CRYSTAL
      def bound_val(v)
        v.clamp(10, 100)
      end
    CRYSTAL

    parser = Citrine::DslParser.new("clamp.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("clamp.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "bound_val" }.not_nil!
    # Clamp emits compare + branch bounds checking (fused into BranchCmp by optimizer)
    cmps = fn.instructions.select { |i| i.opcode == Citrine::Opcode::BranchCmp || i.opcode == Citrine::Opcode::Compare }
    cmps.size.should be >= 2
  end
end
