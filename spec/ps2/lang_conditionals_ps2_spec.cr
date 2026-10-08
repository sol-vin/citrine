require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Conditionals & Branching" do
  it "verifies multi-way dynamic if / elsif / else ladders on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_if_elsif_else_test")
    tc.source(<<-CR
      def evaluate_score(score : Int32)
        if score >= 90
          "GRADE_A"
        elsif score >= 80
          "GRADE_B"
        elsif score >= 70
          "GRADE_C"
        elsif score >= 60
          "GRADE_D"
        else
          "GRADE_F"
        end
      end

      # Dynamic calls with runtime values
      s1 = evaluate_score(95)
      s2 = evaluate_score(82)
      s3 = evaluate_score(77)
      s4 = evaluate_score(61)
      s5 = evaluate_score(45)

      if s1 == "GRADE_A" && s2 == "GRADE_B" && s3 == "GRADE_C" && s4 == "GRADE_D" && s5 == "GRADE_F"
        debug_puts "[CITRINE TEST] Conditionals#multi_branch_ladder: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#multi_branch_ladder: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#multi_branch_ladder: PASS")
  end

  it "verifies unless statements, unless expressions, and unless-else fallback on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_unless_test")
    tc.source(<<-CR
      is_locked = false
      opened = 0
      unless is_locked
        opened = 1
      end

      is_admin = true
      denied = 0
      unless is_admin
        denied = 1
      else
        denied = 2
      end

      # Expression form
      val = 10
      status = unless val > 50
        "standard"
      else
        "overflow"
      end

      if opened == 1 && denied == 2 && status == "standard"
        debug_puts "[CITRINE TEST] Conditionals#unless_branches: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#unless_branches: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#unless_branches: PASS")
  end

  it "verifies truthy and falsy semantics for false, nil, numbers, and strings on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_truthiness_test")
    tc.source(<<-CR
      # false and nil are falsy
      f_val = false
      n_val = nil
      t_val = true
      z_val = 0
      str_val = "hello"

      f_pass = false
      if f_val
        f_pass = false
      else
        f_pass = true
      end

      n_pass = false
      if n_val
        n_pass = false
      else
        n_pass = true
      end

      # 0 is truthy in Crystal/Citrine
      z_pass = false
      if z_val
        z_pass = true
      end

      t_pass = false
      if t_val
        t_pass = true
      end

      s_pass = false
      if str_val
        s_pass = true
      end

      if f_pass && n_pass && z_pass && t_pass && s_pass
        debug_puts "[CITRINE TEST] Conditionals#truthy_falsy_semantics: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#truthy_falsy_semantics: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#truthy_falsy_semantics: PASS")
  end

  it "verifies short-circuit boolean evaluation with side-effect prevention on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_short_circuit_test")
    tc.source(<<-CR
      class SideEffectCounter
        property count : Int32
        def initialize
          @count = 0
        end

        def trigger_true
          @count = @count + 1
          true
        end

        def trigger_false
          @count = @count + 1
          false
        end
      end

      sec = SideEffectCounter.new

      # In false && expr, expr MUST NOT be evaluated
      res1 = sec.trigger_false && sec.trigger_true
      # count should only be 1 (trigger_false was called, trigger_true was skipped)
      count1_ok = (sec.count == 1)

      # In true || expr, expr MUST NOT be evaluated
      res2 = sec.trigger_true || sec.trigger_false
      # count should now be 2 (trigger_true was called, trigger_false was skipped)
      count2_ok = (sec.count == 2)

      # In true && true, both must be evaluated
      res3 = sec.trigger_true && sec.trigger_true
      # count should now be 4
      count3_ok = (sec.count == 4)

      if count1_ok && count2_ok && count3_ok && (!res1) && res2 && res3
        debug_puts "[CITRINE TEST] Conditionals#short_circuit_side_effects: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#short_circuit_side_effects: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#short_circuit_side_effects: PASS")
  end

  it "verifies nested ternary operators and expressions on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_ternary_test")
    tc.source(<<-CR
      def classify(x : Int32)
        x > 0 ? (x > 100 ? "extreme" : "positive") : (x == 0 ? "zero" : "negative")
      end

      c1 = classify(150)
      c2 = classify(42)
      c3 = classify(0)
      c4 = classify(-10)

      # Direct assignment and expression arithmetic with ternary
      base = 100
      bonus = true ? 25 : 0
      penalty = false ? 50 : 5
      total = base + (bonus > 20 ? bonus : 0) - penalty

      if c1 == "extreme" && c2 == "positive" && c3 == "zero" && c4 == "negative" && total == 120
        debug_puts "[CITRINE TEST] Conditionals#nested_ternary: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#nested_ternary: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#nested_ternary: PASS")
  end

  it "verifies guard clauses and early returns on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("cond_guard_clauses_test")
    tc.source(<<-CR
      def process_token(token_id : Int32, is_active : Bool)
        return -1 if token_id < 0
        return -2 unless is_active
        return 100 if token_id == 0

        # Normal processing
        token_id * 10
      end

      r1 = process_token(-5, true)
      r2 = process_token(10, false)
      r3 = process_token(0, true)
      r4 = process_token(7, true)

      if r1 == -1 && r2 == -2 && r3 == 100 && r4 == 70
        debug_puts "[CITRINE TEST] Conditionals#guard_clauses: PASS"
      else
        debug_puts "[CITRINE TEST] Conditionals#guard_clauses: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Conditionals#guard_clauses: PASS")
  end
end
