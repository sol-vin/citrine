require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Loops, Blocks & Recursion" do
  it "verifies while loops, until loops, break, and next on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_while_until_break_next_test")
    tc.source(<<-CR
      # 1. while with break
      sum1 = 0
      i = 0
      while i < 100
        if i == 10
          break
        end
        sum1 = sum1 + i
        i = i + 1
      end
      # sum of 0..9 = 45

      # 2. until loop
      counter = 0
      until counter >= 15
        counter = counter + 3
      end
      # counter = 15

      # 3. while with next (summing only even numbers)
      sum_evens = 0
      k = 0
      while k < 10
        k = k + 1
        if (k % 2) != 0
          next
        end
        sum_evens = sum_evens + k
      end
      # 2 + 4 + 6 + 8 + 10 = 30

      if sum1 == 45 && counter == 15 && sum_evens == 30
        debug_puts "[CITRINE TEST] Loops#while_until_break_next: PASS"
      else
        debug_puts "[CITRINE TEST] Loops#while_until_break_next: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Loops#while_until_break_next: PASS")
  end

  it "verifies nested loops with independent inner break controls on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_nested_break_test")
    tc.source(<<-CR
      outer_count = 0
      inner_total = 0

      r = 0
      while r < 5
        outer_count = outer_count + 1
        c = 0
        while c < 10
          if c == 4
            break # break inner loop only
          end
          inner_total = inner_total + 1
          c = c + 1
        end
        r = r + 1
      end

      # outer_count should be 5, inner_total should be 5 * 4 = 20
      if outer_count == 5 && inner_total == 20
        debug_puts "[CITRINE TEST] Loops#nested_loops_and_inner_break: PASS"
      else
        debug_puts "[CITRINE TEST] Loops#nested_loops_and_inner_break: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Loops#nested_loops_and_inner_break: PASS")
  end

  it "verifies block yielding, parameter passing, and return values on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_blocks_and_yield_test")
    tc.source(<<-CR
      def repeat_calc(times : Int32)
        total = 0
        i = 1
        while i <= times
          total = total + yield(i)
          i = i + 1
        end
        total
      end

      # Square each index: 1^2 + 2^2 + 3^2 + 4^2 = 1 + 4 + 9 + 16 = 30
      res = repeat_calc(4) do |idx|
        idx * idx
      end

      if res == 30
        debug_puts "[CITRINE TEST] Loops#block_yield_and_returns: PASS"
      else
        debug_puts "[CITRINE TEST] Loops#block_yield_and_returns: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Loops#block_yield_and_returns: PASS")
  end

  it "verifies closures capturing and mutating enclosing local variables on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_closure_scope_mutation_test")
    tc.source(<<-CR
      running_score = 100
      multiplier = 2

      [10, 20, 30].each do |delta|
        running_score = running_score + (delta * multiplier)
      end

      # 100 + (10*2) + (20*2) + (30*2) = 100 + 20 + 40 + 60 = 220
      if running_score == 220
        debug_puts "[CITRINE TEST] Loops#closure_scope_mutation: PASS"
      else
        debug_puts "[CITRINE TEST] Loops#closure_scope_mutation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Loops#closure_scope_mutation: PASS")
  end

  it "verifies deep recursion with register preservation on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_deep_recursion_test")
    tc.source(<<-CR
      def fibonacci(n : Int32) : Int32
        if n <= 1
          n
        else
          fibonacci(n - 1) + fibonacci(n - 2)
        end
      end

      def factorial(n : Int32) : Int32
        if n <= 1
          1
        else
          n * factorial(n - 1)
        end
      end

      # fib(10) = 55
      f10 = fibonacci(10)

      # 7! = 5040
      fact7 = factorial(7)

      if f10 == 55 && fact7 == 5040
        debug_puts "[CITRINE TEST] Loops#deep_recursion_integrity: PASS"
      else
        debug_puts "[CITRINE TEST] Loops#deep_recursion_integrity: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Loops#deep_recursion_integrity: PASS")
  end
end
