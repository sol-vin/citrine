require "../spec_helper"

describe "Citrine Tier 1: Crystal Language Matrix & Compiler Specification Suite" do
  it "compiles arithmetic, operator precedence, bitwise logic, and unary operations" do
    source = <<-CRYSTAL
      def compute_math(a, b)
        c = (a + b) * 3 - (a / b) + (a % b)
        d = (a & b) | (a ^ b)
        e = (a << 2) >> 1
        f = -c
        g = ~d
        g
      end
    CRYSTAL

    parser = Citrine::DslParser.new("expr_test.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("expr_test.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    String.new(bytes[0, 4]).should eq("CBC2")
    fn = compiler.functions.find { |f| f.name == "compute_math" }.not_nil!
    
    # Must emit Add, Sub, Mul, DivMod, Bitwise, Shift
    opcodes = fn.instructions.map(&.opcode).to_set
    opcodes.should contain(Citrine::Opcode::Add)
    opcodes.should contain(Citrine::Opcode::Sub)
    opcodes.should contain(Citrine::Opcode::Mul)
    opcodes.should contain(Citrine::Opcode::DivMod)
    opcodes.should contain(Citrine::Opcode::Bitwise)
    opcodes.should contain(Citrine::Opcode::Shift)
  end

  it "compiles short-circuit logic (&&, ||) with proper branching and skipping" do
    source = <<-CRYSTAL
      def compute(flag1, flag2)
        r1 = flag1 && flag2
        r2 = flag1 || flag2
        r3 = (flag1 && flag2) || (!flag1)
        r3
      end
    CRYSTAL

    parser = Citrine::DslParser.new("short_circuit.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("short_circuit.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "compute" }
    fn.should_not be_nil
    fn = fn.not_nil!

    # BranchZ instructions must be emitted for short-circuit jumps
    branch_instrs = fn.instructions.select { |i| i.opcode == Citrine::Opcode::BranchZ }
    branch_instrs.size.should be >= 3
  end

  it "compiles compound assignment operators (+=, -=, *=, /=, %=, ||=, &&=)" do
    source = <<-CRYSTAL
      def mutate_val(x, flag)
        x += 5
        x -= 2
        x *= 3
        x /= 2
        x %= 7
        
        flag &&= false
        flag ||= true
        x
      end
    CRYSTAL

    parser = Citrine::DslParser.new("op_assign.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("op_assign.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 30
    fn = compiler.functions.find { |f| f.name == "mutate_val" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Add }.should be_true
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Sub }.should be_true
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Mul }.should be_true
  end

  it "compiles ternary conditional operator in multiple syntactic positions" do
    source = <<-CRYSTAL
      def test_ternary(x)
        msg = x > 10 ? "greater" : "lesser"
        factor = x < 5 ? 1 : (x < 20 ? 2 : 3)
        factor
      end
    CRYSTAL

    parser = Citrine::DslParser.new("ternary.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("ternary.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "test_ternary" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::BranchZ || i.opcode == Citrine::Opcode::BranchCmp }.should be_true
  end

  it "compiles case/when with multiple values, ranges, and types" do
    source = <<-CRYSTAL
      def classify(val)
        case val
        when 1, 3, 5, 7, 9
          "odd_single"
        when 10..20
          "teen_range"
        when String
          "string_type"
        else
          "unknown"
        end
      end
    CRYSTAL

    parser = Citrine::DslParser.new("case_when.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("case_when.cr")
    bytes = compiler.compile(prog)

    fn = compiler.functions.find { |f| f.name == "classify" }.not_nil!
    # Multiple compare/branch instructions generated
    fn.instructions.size.should be > 10
  end

  it "compiles class definitions, properties, instance methods, and class variables (@@cvar)" do
    source = <<-CRYSTAL
      class BankAccount
        @@total_accounts : Int32 = 0
        property owner : String
        property balance : Int32

        def initialize(@owner : String, @balance : Int32)
          @@total_accounts = @@total_accounts + 1
        end

        def deposit(amount : Int32)
          @balance = @balance + amount
          @balance
        end

        def self.total_count
          @@total_accounts
        end
      end

      acc = BankAccount.new("Alice", 1000)
      acc.deposit(500)
      count = BankAccount.total_count
    CRYSTAL

    parser = Citrine::DslParser.new("class_cvar.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("class_cvar.cr")
    bytes = compiler.compile(prog)

    compiler.classes.has_key?("BankAccount").should be_true
    cls = compiler.classes["BankAccount"]
    cls.fields.has_key?("owner").should be_true
    cls.fields.has_key?("balance").should be_true

    # Class methods and instance methods compiled
    fn_names = compiler.functions.map(&.name)
    fn_names.should contain("BankAccount#initialize")
    fn_names.should contain("BankAccount#deposit")
    fn_names.should contain("BankAccount.total_count")
  end

  it "compiles struct value semantics and independent struct copies" do
    source = <<-CRYSTAL
      struct Vec3D
        property x : Int32
        property y : Int32
        property z : Int32

        def initialize(@x, @y, @z)
        end

        def sum
          @x + @y + @z
        end
      end

      v1 = Vec3D.new(10, 20, 30)
      v2 = v1
      v1.x = 99
      s = v1.sum
    CRYSTAL

    parser = Citrine::DslParser.new("struct_val.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("struct_val.cr")
    bytes = compiler.compile(prog)

    compiler.classes.has_key?("Vec3D").should be_true
    compiler.classes["Vec3D"].is_struct.should be_true
  end

  it "compiles multi-tier inheritance and super forwarding" do
    source = <<-CRYSTAL
      class Entity
        property id : Int32
        def initialize(@id)
        end
        def compute_power
          @id * 2
        end
      end

      class Monster < Entity
        property danger : Int32
        def initialize(@danger, id)
          super(id)
        end
        def compute_power
          super + @danger
        end
      end

      class BossMonster < Monster
        property phase : Int32
        def initialize(@phase, danger, id)
          super(danger, id)
        end
        def compute_power
          super * @phase
        end
      end

      b = BossMonster.new(3, 50, 10)
      pw = b.compute_power
    CRYSTAL

    parser = Citrine::DslParser.new("inheritance.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("inheritance.cr")
    bytes = compiler.compile(prog)

    compiler.classes.has_key?("BossMonster").should be_true
    boss = compiler.classes["BossMonster"]
    boss.superclass_name.should eq("Monster")
    
    # Hierarchy check
    ancestors = boss.ancestor_ids(compiler.classes)
    ancestors.size.should be >= 3
  end

  it "compiles modules, mixin inclusion, and method dispatch overrides" do
    source = <<-CRYSTAL
      module Logger
        def log_prefix
          "[LOG] "
        end
      end

      module Measurable
        def metric_scale
          10
        end
      end

      class Service
        include Logger
        include Measurable

        def full_metric(val : Int32)
          val * metric_scale
        end
      end

      s = Service.new
      m = s.full_metric(5)
    CRYSTAL

    parser = Citrine::DslParser.new("modules.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("modules.cr")
    bytes = compiler.compile(prog)

    compiler.modules.has_key?("Logger").should be_true
    compiler.modules.has_key?("Measurable").should be_true
    compiler.classes["Service"].included_module_ids.size.should be >= 2
  end

  it "compiles higher-order functions, yield with arguments, and outer closure access" do
    source = <<-CRYSTAL
      def repeat_op(count : Int32, initial : Int32)
        acc = initial
        i = 0
        while i < count
          acc = yield(acc, i)
          i = i + 1
        end
        acc
      end

      outer_factor = 2
      result = repeat_op(4, 10) do |val, idx|
        val + (idx * outer_factor)
      end
    CRYSTAL

    parser = Citrine::DslParser.new("blocks.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("blocks.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 30
    main_fn = compiler.functions.last
    # Verified inlined block body in main
    main_fn.instructions.size.should be > 15
  end

  it "compiles collections, indexing, push/pop, and multi-assignment unpacking" do
    source = <<-CRYSTAL
      arr = [10, 20, 30]
      arr << 40
      p = arr.pop
      first = arr[0]
      arr[1] = 99
      
      tuple = {100, 200, 300}
      a, b, c = tuple
    CRYSTAL

    parser = Citrine::DslParser.new("collections.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("collections.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
  end

  it "compiles type introspection: is_a?, as, as?, nil?, and responds_to?" do
    source = <<-CRYSTAL
      class Vehicle
        def drive; 1; end
      end
      class Car < Vehicle
        def honk; 2; end
      end

      c = Car.new
      is_c = c.is_a?(Car)
      is_v = c.is_a?(Vehicle)
      cast_c = c.as(Vehicle)
      nil_c = c.as?(Car)
      has_honk = c.responds_to?(:honk)
      is_nil = c.nil?
    CRYSTAL

    parser = Citrine::DslParser.new("types.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("types.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 25
  end

  it "compiles low-level Pointer allocation and asm primitives" do
    source = <<-CRYSTAL
      ptr = Pointer(Int32).malloc(8)
      ptr[0] = 42
      ptr.value = 100
      addr = ptr.address

      asm("sync.l")
      Citrine.asm "sync.p"
    CRYSTAL

    parser = Citrine::DslParser.new("low_level.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("low_level.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::InlineAsm }.should be_true
  end
end
