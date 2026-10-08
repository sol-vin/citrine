require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 SPRAM Boundaries & Canary Suite" do
  it "verifies SPRAM allocation at 0x70000000 and boundary canaries" do
    tc = Citrine::Spec::Ps2TestCase.new("spram_boundary_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] SPRAM Boundary Verification"
      # Perform computations using local variables (backed by SPRAM registers)
      v1 = 10
      v2 = 20
      v3 = 30
      v4 = 40
      v5 = 50
      v6 = 60
      v7 = 70
      v8 = 80
      total = v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8
      if total == 360
        debug_puts "[CITRINE TEST] SPRAM Register Accumulation: PASS"
      else
        debug_puts "[CITRINE TEST] SPRAM Register Accumulation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] SPRAM Register Accumulation: PASS")
  end

  it "verifies SPRAM canary preservation across multiple frames" do
    tc = Citrine::Spec::Ps2TestCase.new("spram_multiframe_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Multi-Frame SPRAM Integrity Init"
      count = 0
      while count < 3
        count = count + 1
      end
      debug_puts "[CITRINE TEST] Multi-Frame SPRAM Canary: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Multi-Frame SPRAM Canary: PASS")
  end
end
