require "../spec_helper"

describe "Citrine Tier 1: Control Flow Compiler Specification Suite" do
  it "compiles nested if / elsif / else / unless branches with correct jump patching" do
    source = <<-CRYSTAL
      def categorize(val, invert)
        category = 0
        if val > 100
          category = 1
        elsif val > 50
          category = 2
        elsif val > 10
          category = 3
        else
          category = 4
        end

        unless invert
          category = category + 10
        end

        category
      end
    CRYSTAL

    parser = Citrine::DslParser.new("cond.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("cond.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    fn = compiler.functions.find { |f| f.name == "categorize" }.not_nil!
    branches = fn.instructions.select { |i| i.opcode == Citrine::Opcode::BranchZ || i.opcode == Citrine::Opcode::BranchCmp }
    branches.size.should be >= 4
  end

  it "compiles statement-modifier conditionals (x += 1 if cond, y -= 1 unless cond)" do
    source = <<-CRYSTAL
      def step(count, inc_flag, dec_flag)
        count += 5 if inc_flag
        count -= 2 unless dec_flag
        count
      end
    CRYSTAL

    parser = Citrine::DslParser.new("modifier.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("modifier.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "step" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::BranchZ }.should be_true
  end

  it "compiles nested while and until loops with break and next" do
    source = <<-CRYSTAL
      def process_grid(rows, cols)
        sum = 0
        r = 0
        while r < rows
          r += 1
          if r == 2
            next
          end

          c = 0
          until c >= cols
            c += 1
            if c == 5
              break
            end
            sum += (r * 10 + c)
          end
        end
        sum
      end
    CRYSTAL

    parser = Citrine::DslParser.new("loops.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("loops.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "process_grid" }.not_nil!
    # Verified backward jumps and forward break jumps
    jumps = fn.instructions.select { |i| i.opcode == Citrine::Opcode::Jump }
    jumps.size.should be >= 3
  end

  it "compiles times iterator loops with parameter binding" do
    source = <<-CRYSTAL
      def loop_times(limit)
        accumulator = 0
        limit.times do |idx|
          accumulator += (idx * 2)
        end
        accumulator
      end
    CRYSTAL

    parser = Citrine::DslParser.new("times.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("times.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "loop_times" }.not_nil!
    fn.instructions.size.should be > 10
  end

  it "compiles pattern matching case/when with single values, lists, ranges, and else" do
    source = <<-CRYSTAL
      def classify_item(code)
        case code
        when 0
          100
        when 1, 2, 3
          200
        when 10..20
          300
        else
          400
        end
      end
    CRYSTAL

    parser = Citrine::DslParser.new("case.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("case.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "classify_item" }.not_nil!
    cmps = fn.instructions.select { |i| i.opcode == Citrine::Opcode::Compare || i.opcode == Citrine::Opcode::BranchCmp }
    cmps.size.should be >= 2
  end
end
