require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Optimizer Hardware Verification Suite" do
  it "verifies constant folding optimization preserves exact runtime values" do
    tc = Citrine::Spec::Ps2TestCase.new("opt_constant_folding_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Constant Folding Optimizer Check"
      # Constant expressions folded at compile-time:
      val = 100 + 200 * 3 - 50
      if val == 650
        debug_puts "[CITRINE TEST] Constant Folding Result 650: PASS"
      else
        debug_puts "[CITRINE TEST] Constant Folding Failed"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Constant Folding Result 650: PASS")
  end

  it "verifies algebraic identity simplification (x+0, x*1, x*0)" do
    tc = Citrine::Spec::Ps2TestCase.new("opt_algebraic_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Algebraic Identity Simplification Check"
      x = 42
      a = x + 0
      b = a * 1
      c = b * 0
      d = a - 0
      if a == 42 && b == 42 && c == 0 && d == 42
        debug_puts "[CITRINE TEST] Algebraic Identities: PASS"
      else
        debug_puts "[CITRINE TEST] Algebraic Identities Failed"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Algebraic Identities: PASS")
  end

  it "verifies dead code elimination does not affect valid branches" do
    tc = Citrine::Spec::Ps2TestCase.new("opt_dead_code_branch_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Dead Code Branch Test Init"
      flag = true
      if flag
        debug_puts "[CITRINE TEST] Reachable Branch Taken: PASS"
      else
        debug_puts "[CITRINE TEST] Unreachable Branch Taken: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Reachable Branch Taken: PASS")
  end
end
