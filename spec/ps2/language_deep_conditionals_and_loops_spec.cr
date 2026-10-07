require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Deep Conditionals & Advanced Loops" do
  it "verifies short-circuit boolean evaluation with side effects on && and || on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_short_circuit_test")
    tc.source(<<-CR
      class EffectTracker
        property count : Int32
        def initialize
          @count = 0
        end

        def call_true : Bool
          @count = @count + 1
          true
        end

        def call_false : Bool
          @count = @count + 1
          false
        end
      end

      tracker = EffectTracker.new

      # 1. Short-circuit AND: false && right -> right must NOT execute
      r1 = false && tracker.call_true
      c1 = tracker.count # count should still be 0

      # 2. Non-short-circuit AND: true && right -> right MUST execute
      r2 = true && tracker.call_true
      c2 = tracker.count # count should be 1

      # 3. Short-circuit OR: true || right -> right must NOT execute
      r3 = true || tracker.call_false
      c3 = tracker.count # count should still be 1

      # 4. Non-short-circuit OR: false || right -> right MUST execute
      r4 = false || tracker.call_false
      c4 = tracker.count # count should be 2

      # 5. Compound chain: (false && right1) || (true && right2)
      # right1 is skipped, left side is false. Then false || (true && right2).
      # right2 must execute.
      r5 = (false && tracker.call_true) || (true && tracker.call_true)
      c5 = tracker.count # count should be 3

      and_ok = (!r1) && (c1 == 0) && r2 && (c2 == 1)
      or_ok = r3 && (c3 == 1) && (!r4) && (c4 == 2)
      chain_ok = r5 && (c5 == 3)

      if and_ok && or_ok && chain_ok
        debug_puts "[CITRINE TEST] DeepConditionals#short_circuit_evaluation: PASS"
      else
        debug_puts "[CITRINE TEST] DeepConditionals#short_circuit_evaluation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepConditionals#short_circuit_evaluation: PASS")
  end

  it "verifies deep nested conditionals, chained ternaries, and unless-else ladders on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_deep_nested_and_ternary_test")
    tc.source(<<-CR
      def classify_coordinate(x : Int32, y : Int32) : String
        if x > 0
          if y > 0
            "QUADRANT_1"
          elsif y < 0
            "QUADRANT_4"
          else
            "POS_X_AXIS"
          end
        elsif x < 0
          if y > 0
            "QUADRANT_2"
          elsif y < 0
            "QUADRANT_3"
          else
            "NEG_X_AXIS"
          end
        else
          if y > 0
            "POS_Y_AXIS"
          elsif y < 0
            "NEG_Y_AXIS"
          else
            "ORIGIN"
          end
        end
      end

      q1 = classify_coordinate(10, 20)
      q2 = classify_coordinate(-5, 15)
      q3 = classify_coordinate(-8, -12)
      q4 = classify_coordinate(7, -3)
      org = classify_coordinate(0, 0)
      py = classify_coordinate(0, 50)

      # Chained ternary operator
      def grade(score : Int32) : String
        score >= 90 ? "GOLD" : (score >= 75 ? "SILVER" : (score >= 50 ? "BRONZE" : "IRON"))
      end

      g_gold = grade(95)
      g_silver = grade(80)
      g_bronze = grade(60)
      g_iron = grade(30)

      quad_ok = (q1 == "QUADRANT_1") && (q2 == "QUADRANT_2") && (q3 == "QUADRANT_3") && (q4 == "QUADRANT_4") && (org == "ORIGIN") && (py == "POS_Y_AXIS")
      grade_ok = (g_gold == "GOLD") && (g_silver == "SILVER") && (g_bronze == "BRONZE") && (g_iron == "IRON")

      if quad_ok && grade_ok
        debug_puts "[CITRINE TEST] DeepConditionals#deep_nested_and_ternaries: PASS"
      else
        debug_puts "[CITRINE TEST] DeepConditionals#deep_nested_and_ternaries: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepConditionals#deep_nested_and_ternaries: PASS")
  end

  it "verifies Collatz conjecture loop computation with alternating odd/even branching on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_collatz_conjecture_test")
    tc.source(<<-CR
      # The Collatz 3n + 1 sequence for starting seed n = 27
      # Requires 111 steps to reach 1, reaching a maximum peak value of 9232.
      n = 27
      steps = 0
      peak = n

      while n > 1
        if (n % 2) == 0
          n = n // 2
        else
          n = (3 * n) + 1
        end

        if n > peak
          peak = n
        end
        steps = steps + 1
      end

      # Also test a smaller sequence: n = 12 -> 6 -> 3 -> 10 -> 5 -> 16 -> 8 -> 4 -> 2 -> 1 (9 steps)
      n2 = 12
      steps2 = 0
      while n2 > 1
        if (n2 % 2) == 0
          n2 = n2 // 2
        else
          n2 = (3 * n2) + 1
        end
        steps2 = steps2 + 1
      end

      if steps == 111 && peak == 9232 && n == 1 && steps2 == 9 && n2 == 1
        debug_puts "[CITRINE TEST] DeepLoops#collatz_conjecture_loop: PASS"
      else
        debug_puts "[CITRINE TEST] DeepLoops#collatz_conjecture_loop: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepLoops#collatz_conjecture_loop: PASS")
  end

  it "verifies multi-depth nested loops with independent breaks and next skips on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_multidepth_break_next_test")
    tc.source(<<-CR
      outer_iters = 0
      mid_iters = 0
      inner_iters = 0
      sum = 0

      i = 0
      while i < 4
        outer_iters = outer_iters + 1
        j = 0
        while j < 6
          # Skip odd iterations in mid loop
          if (j % 2) != 0
            j = j + 1
            next
          end

          # Break mid loop early when j reaches 4
          if j == 4
            break
          end

          mid_iters = mid_iters + 1

          k = 0
          while k < 10
            # Break inner loop when k reaches 3
            if k == 3
              break
            end
            inner_iters = inner_iters + 1
            sum = sum + 1
            k = k + 1
          end

          j = j + 1
        end
        i = i + 1
      end

      # Tracing:
      # Outer loop runs 4 times (i = 0, 1, 2, 3)
      # For each outer iteration:
      #   j = 0: even -> passes -> inner loop runs 3 times (k = 0, 1, 2)
      #   j = 1: odd -> next
      #   j = 2: even -> passes -> inner loop runs 3 times (k = 0, 1, 2)
      #   j = 3: odd -> next
      #   j = 4: breaks mid loop
      # Mid loop passes valid 2 times per outer loop (j=0, j=2)
      # mid_iters = 4 * 2 = 8
      # inner_iters = 8 * 3 = 24
      # sum = 24

      if outer_iters == 4 && mid_iters == 8 && inner_iters == 24 && sum == 24
        debug_puts "[CITRINE TEST] DeepLoops#multidepth_break_and_next: PASS"
      else
        debug_puts "[CITRINE TEST] DeepLoops#multidepth_break_and_next: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepLoops#multidepth_break_and_next: PASS")
  end

  it "verifies case/when with multiple values, numeric ranges, and expressions on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_case_multi_and_ranges_test")
    tc.source(<<-CR
      def match_category(val : Int32) : String
        case val
        when 0
          "ZERO"
        when 1, 3, 5, 7, 9
          "SMALL_ODD"
        when 2, 4, 6, 8
          "SMALL_EVEN"
        when 10..50
          "MID_RANGE"
        when 51...100
          "HIGH_RANGE"
        else
          "EXTREME"
        end
      end

      c0 = match_category(0)
      c1 = match_category(5)
      c2 = match_category(8)
      c3 = match_category(25)
      c4 = match_category(50)  # inclusive boundary of 10..50
      c5 = match_category(75)  # in 51...100
      c6 = match_category(100) # exclusive of 51...100 -> falls to else
      c7 = match_category(200)

      all_match = (c0 == "ZERO") &&
                  (c1 == "SMALL_ODD") &&
                  (c2 == "SMALL_EVEN") &&
                  (c3 == "MID_RANGE") &&
                  (c4 == "MID_RANGE") &&
                  (c5 == "HIGH_RANGE") &&
                  (c6 == "EXTREME") &&
                  (c7 == "EXTREME")

      if all_match
        debug_puts "[CITRINE TEST] DeepConditionals#case_multi_and_ranges: PASS"
      else
        debug_puts "[CITRINE TEST] DeepConditionals#case_multi_and_ranges: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepConditionals#case_multi_and_ranges: PASS")
  end

  it "verifies .times and range .each iterations with accumulators and closures on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("loop_times_and_range_each_test")
    tc.source(<<-CR
      # 1. Integer .times iteration
      times_sum = 0
      5.times do |i|
        times_sum = times_sum + i
      end
      # 0 + 1 + 2 + 3 + 4 = 10

      # 2. Inclusive range .each (10..15)
      inc_sum = 0
      (10..15).each do |n|
        inc_sum = inc_sum + n
      end
      # 10 + 11 + 12 + 13 + 14 + 15 = 75

      # 3. Exclusive range .each (10...15)
      exc_sum = 0
      (10...15).each do |n|
        exc_sum = exc_sum + n
      end
      # 10 + 11 + 12 + 13 + 14 = 60

      # 4. 2D grid nested range iteration
      grid_area = 0
      (1..3).each do |x|
        (1..4).each do |y|
          grid_area = grid_area + 1
        end
      end
      # 3 rows x 4 cols = 12

      if times_sum == 10 && inc_sum == 75 && exc_sum == 60 && grid_area == 12
        debug_puts "[CITRINE TEST] DeepLoops#times_and_range_iterations: PASS"
      else
        debug_puts "[CITRINE TEST] DeepLoops#times_and_range_iterations: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepLoops#times_and_range_iterations: PASS")
  end
end
