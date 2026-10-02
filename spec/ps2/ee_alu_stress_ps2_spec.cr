require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Emotion Engine ALU Stress & Logic Suite" do
  it "verifies 32-bit arithmetic with multiplication, modulo, and negative numbers" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_alu_arithmetic_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] EE ALU Arithmetic Stress"
      a = 1000
      b = -250
      c = a + b
      d = c * 2
      e = d % 700
      if e == 100
        debug_puts "[CITRINE TEST] Arithmetic Pipeline: PASS"
      else
        debug_puts "[CITRINE TEST] Arithmetic Pipeline: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Arithmetic Pipeline: PASS")
  end

  it "verifies comparison operators (<, <=, >, >=, ==, !=) on EE" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_alu_comparisons_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] EE Comparisons Testing"
      p = 50
      q = 50
      r = 100
      ok = (p == q) && (p != r) && (p < r) && (p <= q) && (r > p) && (r >= q)
      if ok
        debug_puts "[CITRINE TEST] Comparisons All Evaluated Correctly: PASS"
      else
        debug_puts "[CITRINE TEST] Comparisons Failed"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Comparisons All Evaluated Correctly: PASS")
  end

  it "verifies iterative loop execution and accumulator accuracy" do
    tc = Citrine::Spec::Ps2TestCase.new("ee_loop_accumulator_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] EE Loop Accumulator Init"
      sum = 0
      i = 1
      while i <= 100
        sum = sum + i
        i = i + 1
      end
      # Sum 1..100 = 5050
      if sum == 5050
        debug_puts "[CITRINE TEST] Accumulator 1..100 == 5050: PASS"
      else
        debug_puts "[CITRINE TEST] Accumulator Failed"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Accumulator 1..100 == 5050: PASS")
  end
end
