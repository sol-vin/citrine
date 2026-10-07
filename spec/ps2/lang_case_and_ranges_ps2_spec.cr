require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Case & Ranges" do
  it "verifies case/when value matching with else fallback on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("case_values_and_else_test")
    tc.source(<<-CR
      def evaluate_code(code : Int32) : String
        case code
        when 1
          "ONE"
        when 2
          "TWO"
        when 3
          "THREE"
        else
          "UNKNOWN"
        end
      end

      r1 = evaluate_code(1)
      r2 = evaluate_code(2)
      r3 = evaluate_code(3)
      r4 = evaluate_code(99)

      if r1 == "ONE" && r2 == "TWO" && r3 == "THREE" && r4 == "UNKNOWN"
        debug_puts "[CITRINE TEST] Case#value_matching_and_else: PASS"
      else
        debug_puts "[CITRINE TEST] Case#value_matching_and_else: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Case#value_matching_and_else: PASS")
  end

  it "verifies case/when with inclusive and exclusive range matching on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("case_range_matching_test")
    tc.source(<<-CR
      def classify_grade(score : Int32) : String
        case score
        when 90..100
          "A"
        when 80...90
          "B"
        when 70...80
          "C"
        when 0...70
          "FAIL"
        else
          "INVALID"
        end
      end

      g95 = classify_grade(95)
      g90 = classify_grade(90)
      g89 = classify_grade(89)
      g80 = classify_grade(80)
      g75 = classify_grade(75)
      g50 = classify_grade(50)
      g_out = classify_grade(150)

      if g95 == "A" && g90 == "A" && g89 == "B" && g80 == "B" && g75 == "C" && g50 == "FAIL" && g_out == "INVALID"
        debug_puts "[CITRINE TEST] Case#range_matching: PASS"
      else
        debug_puts "[CITRINE TEST] Case#range_matching: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Case#range_matching: PASS")
  end

  it "verifies case/when with multiple values per branch on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("case_multi_value_branch_test")
    tc.source(<<-CR
      def category(val : Int32) : String
        case val
        when 1, 3, 5, 7, 9
          "ODD"
        when 2, 4, 6, 8, 10
          "EVEN"
        else
          "OTHER"
        end
      end

      c3 = category(3)
      c6 = category(6)
      c9 = category(9)
      c10 = category(10)
      c11 = category(11)

      if c3 == "ODD" && c6 == "EVEN" && c9 == "ODD" && c10 == "EVEN" && c11 == "OTHER"
        debug_puts "[CITRINE TEST] Case#multi_value_branches: PASS"
      else
        debug_puts "[CITRINE TEST] Case#multi_value_branches: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Case#multi_value_branches: PASS")
  end

  it "verifies case/when with dynamic class and union type matching on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("case_type_matching_test")
    tc.source(<<-CR
      class Warrior
        property sword : String
        def initialize(@sword)
        end
      end

      class Mage
        property spell : String
        def initialize(@spell)
        end
      end

      class Rogue
        property dagger : String
        def initialize(@dagger)
        end
      end

      def hero_role(entity) : String
        case entity
        when Warrior, Mage
          "CASTER_OR_TANK"
        when Rogue
          "STEALTH"
        else
          "UNKNOWN"
        end
      end

      w = Warrior.new("Excalibur")
      m = Mage.new("Fireball")
      r = Rogue.new("Stiletto")

      r_w = hero_role(w)
      r_m = hero_role(m)
      r_r = hero_role(r)

      if r_w == "CASTER_OR_TANK" && r_m == "CASTER_OR_TANK" && r_r == "STEALTH"
        debug_puts "[CITRINE TEST] Case#type_matching: PASS"
      else
        debug_puts "[CITRINE TEST] Case#type_matching: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Case#type_matching: PASS")
  end

  it "verifies inclusive and exclusive range iteration with each on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("range_iteration_each_test")
    tc.source(<<-CR
      # 1. Inclusive range 1..5: 1 + 2 + 3 + 4 + 5 = 15
      sum_inc = 0
      (1..5).each do |num|
        sum_inc = sum_inc + num
      end

      # 2. Exclusive range 1...5: 1 + 2 + 3 + 4 = 10
      sum_exc = 0
      (1...5).each do |num|
        sum_exc = sum_exc + num
      end

      # 3. Dynamic bounds range
      start_bound = 10
      end_bound = 14
      sum_dyn = 0
      (start_bound..end_bound).each do |num|
        sum_dyn = sum_dyn + num
      end
      # 10 + 11 + 12 + 13 + 14 = 60

      if sum_inc == 15 && sum_exc == 10 && sum_dyn == 60
        debug_puts "[CITRINE TEST] Ranges#iteration_and_bounds: PASS"
      else
        debug_puts "[CITRINE TEST] Ranges#iteration_and_bounds: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Ranges#iteration_and_bounds: PASS")
  end

  it "verifies conditionless case statements on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("case_conditionless_test")
    tc.source(<<-CR
      score = 85
      streak = 5

      badge = case
              when score >= 90
                "GOLD"
              when score >= 80 && streak >= 5
                "SILVER_STREAK"
              when score >= 80
                "SILVER"
              else
                "BRONZE"
              end

      if badge == "SILVER_STREAK"
        debug_puts "[CITRINE TEST] Case#conditionless_case: PASS"
      else
        debug_puts "[CITRINE TEST] Case#conditionless_case: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Case#conditionless_case: PASS")
  end
end
