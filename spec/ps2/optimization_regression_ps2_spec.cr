require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Optimizer Hardware Verification Suite" do
  ps2_test "opt_constant_folding_test", "verifies constant folding optimization preserves exact runtime values" do |tc|
    tc.source(<<-CR
      # Constant expressions folded at compile-time:
      val = 100 + 200 * 3 - 50
      if val == 650
        Test.pass("Constant Folding Result 650")
      else
        Test.fail("Constant Folding Failed")
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_pass("Constant Folding Result 650")
  end

  ps2_test "opt_algebraic_test", "verifies algebraic identity simplification (x+0, x*1, x*0)" do |tc|
    tc.source(<<-CR
      x = 42
      a = x + 0
      b = a * 1
      c = b * 0
      d = a - 0
      if a == 42 && b == 42 && c == 0 && d == 42
        Test.pass("Algebraic Identities")
      else
        Test.fail("Algebraic Identities Failed")
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_pass("Algebraic Identities")
  end

  ps2_test "opt_dead_code_branch_test", "verifies dead code elimination does not affect valid branches" do |tc|
    tc.source(<<-CR
      flag = true
      if flag
        Test.pass("Reachable Branch Taken")
      else
        Test.fail("Unreachable Branch Taken")
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Reachable Branch Taken: PASS")
    result.should_pass("Reachable Branch Taken")
  end

  ps2_test "opt_multi_pass_pipeline_test", "verifies multiple passes in one test with zero-fail tolerance" do |tc|
    tc.source(<<-CR
      # Check 1: Constant folding
      val = 100 + 200 * 3 - 50
      if val == 650
        Test.pass("Check Test 1")
      else
        Test.fail("Check Test 1")
      end

      # Check 2: Algebraic identity
      x = 42
      if (x + 0 == 42) && (x * 1 == 42) && (x * 0 == 0)
        Test.pass("Check Test 2")
      else
        Test.fail("Check Test 2")
      end

      # Check 3: Branching
      flag = true
      if flag
        Test.pass("Check Test 3")
      else
        Test.fail("Check Test 3")
      end
    CR
    )
    result = tc.run_and_verify
    next unless result.pcsx2_available?
    result.should_pass("Check Test 1")
    result.should_pass("Check Test 2")
    result.should_pass("Check Test 3")
    result.passed_count.should be >= 3
    result.failed_count.should eq(0)
  end
end
