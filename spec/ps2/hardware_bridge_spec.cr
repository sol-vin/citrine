require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Hardware Bridge & Communication Suite" do
  it "executes debug_puts and communicates back through PCSX2 Bridge" do
    tc = Citrine::Spec::Ps2TestCase.new("bridge_comm_test")
    tc.source(<<-CR
      debug_puts "[CITRINE DEBUG] Hardware Bridge Communication Online"
      debug_puts "[CITRINE TEST] Emotion Engine MIPS instructions verified"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 3.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
    result.should_have_output("[CITRINE DEBUG] Hardware Bridge Communication Online")
    result.should_have_output("[CITRINE TEST] Emotion Engine MIPS instructions verified")
  end

  it "verifies EE arithmetic logic and emits pass message" do
    tc = Citrine::Spec::Ps2TestCase.new("bridge_math_test")
    tc.source(<<-CR
      a = 25
      b = 17
      c = a * b + 4
      if c == 429
        debug_puts "[CITRINE TEST] ALU Math & Conditional Branch Verification: PASS"
      else
        debug_puts "[CITRINE TEST] ALU Math & Conditional Branch Verification: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 3.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] ALU Math & Conditional Branch Verification: PASS")
  end

  it "verifies panic detection and reporting through the bridge" do
    tc = Citrine::Spec::Ps2TestCase.new("bridge_panic_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Running pre-panic sanity check"
      Citrine.panic("Simulated Hardware Bridge Assertion Failure")
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 3.seconds)
    result.should_have_output("[CITRINE TEST] Running pre-panic sanity check")
    result.should_panic_with("Simulated Hardware Bridge Assertion Failure")
  end

  it "verifies SPRAM canary preservation across execution" do
    tc = Citrine::Spec::Ps2TestCase.new("spram_canary_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Verifying SPRAM Canary 0xDEADBEEF"
    CR
    )
    bytes, sm = tc.compile
    result = tc.boot_pcsx2(timeout: 3.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end
end
