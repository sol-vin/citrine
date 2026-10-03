require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity & Core Features Suite" do
  it "executes custom functions, argument passing, and recursion on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_functions_and_recursion_test")
    tc.source(<<-CR
      def add_three(a, b, c)
        a + b + c
      end

      def fib(n)
        if n <= 1
          n
        else
          fib(n - 1) + fib(n - 2)
        end
      end

      debug_puts "[CITRINE TEST] Function Calls & Recursion EE Init"
      res1 = add_three(10, 20, 30)
      if res1 == 60
        debug_puts "[CITRINE TEST] add_three == 60: PASS"
      end

      fib7 = fib(7) # fib(7) = 13 (0, 1, 1, 2, 3, 5, 8, 13)
      if fib7 == 13
        debug_puts "[CITRINE TEST] fib(7) == 13: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Function Calls & Recursion EE Init")
    result.should_have_output("[CITRINE TEST] add_three == 60: PASS")
    result.should_have_output("[CITRINE TEST] fib(7) == 13: PASS")
  end

  it "executes class instantiation, @ivar fields, properties, and methods on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_classes_and_objects_test")
    tc.source(<<-CR
      class Player
        property score : Int32
        property lives : Int32

        def initialize(@score, @lives)
        end

        def add_points(pts)
          @score = @score + pts
          @score
        end
      end

      debug_puts "[CITRINE TEST] Classes & Objects EE Init"
      p = Player.new(100, 3)
      if p.score == 100
        debug_puts "[CITRINE TEST] Initial score 100: PASS"
      end

      p.add_points(50)
      if p.score == 150
        debug_puts "[CITRINE TEST] Mutated score 150: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Classes & Objects EE Init")
    result.should_have_output("[CITRINE TEST] Initial score 100: PASS")
    result.should_have_output("[CITRINE TEST] Mutated score 150: PASS")
  end

  it "executes modules and module function dispatch on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_modules_test")
    tc.source(<<-CR
      module MathHelper
        def double_it(n)
          n * 2
        end
      end

      debug_puts "[CITRINE TEST] Modules EE Init"
      val = MathHelper.double_it(21)
      if val == 42
        debug_puts "[CITRINE TEST] MathHelper.double_it(21) == 42: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Modules EE Init")
    result.should_have_output("[CITRINE TEST] MathHelper.double_it(21) == 42: PASS")
  end

  it "executes blocks with yield and with self yield on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_blocks_and_yield_test")
    tc.source(<<-CR
      def repeat_calc(times)
        sum = 0
        i = 1
        while i <= times
          sum = sum + yield(i)
          i = i + 1
        end
        sum
      end

      debug_puts "[CITRINE TEST] Blocks & Yield EE Init"
      total = repeat_calc(3) do |x|
        x * 10
      end
      # 10 + 20 + 30 = 60
      if total == 60
        debug_puts "[CITRINE TEST] repeat_calc(3) yield sum == 60: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Blocks & Yield EE Init")
    result.should_have_output("[CITRINE TEST] repeat_calc(3) yield sum == 60: PASS")
  end

  it "executes Array literals, indexing, push, pop, and each loops on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_arrays_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Dynamic Array EE Init"
      arr = [10, 20, 30]
      if arr.size == 3
        debug_puts "[CITRINE TEST] arr.size == 3: PASS"
      end

      arr << 40
      if arr.size == 4
        debug_puts "[CITRINE TEST] arr << 40 size == 4: PASS"
      end

      val = arr.pop
      if val == 40
        debug_puts "[CITRINE TEST] arr.pop == 40: PASS"
      end

      total = 0
      arr.each do |item|
        total = total + item
      end
      # 10 + 20 + 30 = 60
      if total == 60
        debug_puts "[CITRINE TEST] arr.each sum == 60: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Dynamic Array EE Init")
    result.should_have_output("[CITRINE TEST] arr.size == 3: PASS")
    result.should_have_output("[CITRINE TEST] arr << 40 size == 4: PASS")
    result.should_have_output("[CITRINE TEST] arr.pop == 40: PASS")
    result.should_have_output("[CITRINE TEST] arr.each sum == 60: PASS")
  end

  it "executes StaticArray and IO::Memory on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_static_array_and_io_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] StaticArray & IO::Memory EE Init"
      sarr = StaticArray(Int32, 4).new(0)
      sarr[0] = 77
      sarr[1] = 88
      if sarr[0] == 77 && sarr[1] == 88
        debug_puts "[CITRINE TEST] StaticArray indexed: PASS"
      end

      mem = IO::Memory.new(64)
      mem.puts "Citrine PS2 Stream Test"
      if mem.pos > 0
        debug_puts "[CITRINE TEST] IO::Memory pos > 0: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] StaticArray & IO::Memory EE Init")
    result.should_have_output("[CITRINE TEST] StaticArray indexed: PASS")
    result.should_have_output("[CITRINE TEST] IO::Memory pos > 0: PASS")
  end
end
