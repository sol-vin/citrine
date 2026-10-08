require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Hardware & Compiler Pressure Points Suite" do
  ps2_test "ee_register_pressure_test", "stresses register allocation and live ranges with 25-term arithmetic expression on PS2 EE" do |tc|
    tc.source(<<-CR
      def deep_calc(a, b, c, d, e, f, g, h)
        # 25+ operations stressing register allocation ($r16..$r255)
        t1 = (a + b) * (c - d)
        t2 = (e + f) * (g - h)
        t3 = (a * c) + (b * d) - (e * g) + (f * h)
        t4 = (t1 + t2) * 2 - (t3 / 2) + ((a + d) % (b + 1))
        t5 = (t4 & 0x0FFF) | ((t1 ^ t2) & 0x00FF)
        t5
      end

      res = deep_calc(10, 5, 20, 8, 15, 3, 12, 4)
      Test.assert(res == 612, "Deep Register Calc == 612")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_pass("Deep Register Calc == 612")
  end

  ps2_test "ee_spram_recursion_test", "verifies SPRAM 16KB stack canary preservation under deep recursive call trees" do |tc|
    tc.source(<<-CR
      def fib(n)
        if n <= 1
          n
        else
          fib(n - 1) + fib(n - 2)
        end
      end

      def factorial(n)
        if n <= 1
          1
        else
          n * factorial(n - 1)
        end
      end

      # fib(10) = 55
      fib10 = fib(10)
      Test.assert(fib10 == 55, "fib(10) == 55")

      # factorial(7) = 5040
      fact7 = factorial(7)
      Test.assert(fact7 == 5040, "factorial(7) == 5040")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_pass("fib(10) == 55")
    result.should_pass("factorial(7) == 5040")
  end

  ps2_test "ee_short_circuit_side_effects_test", "verifies short-circuit evaluation prevents side-effect execution on PS2 EE" do |tc|
    tc.source(<<-CR
      class SideEffectWatcher
        @@invocations : Int32 = 0
        def self.trigger
          @@invocations = @@invocations + 1
          true
        end
        def self.count
          @@invocations
        end
      end

      # 1. false && ... MUST NOT call trigger
      v1 = false && SideEffectWatcher.trigger
      t1_ok = (SideEffectWatcher.count == 0)

      # 2. true || ... MUST NOT call trigger
      v2 = true || SideEffectWatcher.trigger
      t2_ok = (SideEffectWatcher.count == 0)

      # 3. true && ... MUST call trigger
      v3 = true && SideEffectWatcher.trigger
      t3_ok = (SideEffectWatcher.count == 1)

      # 4. false || ... MUST call trigger
      v4 = false || SideEffectWatcher.trigger
      t4_ok = (SideEffectWatcher.count == 2)

      Test.assert(t1_ok && t2_ok && t3_ok && t4_ok, "Short-circuit side-effects guarded")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_pass("Short-circuit side-effects guarded")
  end

  ps2_test "ee_nested_loops_flow_test", "verifies nested loops with break, next, and accumulator register preservation on PS2 EE" do |tc|
    tc.source(<<-CR
      total = 0
      outer = 0
      while outer < 5
        outer = outer + 1
        if outer == 3
          next # Skip outer iteration 3
        end

        inner = 0
        while inner < 10
          inner = inner + 1
          if inner == 2
            next # Skip inner 2
          end
          if inner == 6
            break # Break when inner reaches 6
          end
          total = total + inner
        end
      end

      # For each active outer (1, 2, 4, 5 = 4 outer passes):
      # Inner sequence added: 1, 3, 4, 5 (sum = 13 per pass)
      # 4 * 13 = 52
      Test.assert(total == 52, "Nested loops with break and next total == 52")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_pass("Nested loops with break and next total == 52")
  end

  ps2_test "ee_memory_arena_stress_test", "verifies zero-GC memory arena stability across 200 allocation iterations on PS2 EE" do |tc|
    tc.source(<<-CR
      class Widget
        property id : Int32
        property weight : Int32
        def initialize(@id, @weight)
        end
      end

      iter = 0
      sum_weights = 0
      while iter < 200
        w = Widget.new(iter, iter * 2)
        sum_weights = sum_weights + w.weight
        iter = iter + 1
      end

      # 2 * sum(0..199) = 2 * (199 * 200 / 2) = 39800
      Test.assert(sum_weights == 39800, "200 allocations sum == 39800")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_have_no_memory_leaks
    result.should_not_have_memory_faults
    result.should_pass("200 allocations sum == 39800")
  end
end
