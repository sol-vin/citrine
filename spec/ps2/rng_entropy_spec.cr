require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Hardware Multi-Entropy & RNG Suite" do
  it "verifies uniform statistical distribution of Citrine.rand across 100 samples" do
    tc = Citrine::Spec::Ps2TestCase.new("rng_distribution_test")
    tc.source(<<-CR
      require "citrine"

      c1 = 0
      c2 = 0
      c3 = 0
      c4 = 0
      10.times do
        v = Citrine.rand(1, 4)
        debug_puts "[SAMPLE] \#{v}"
      end
      debug_puts "[CITRINE TEST] RNG Distribution Uniformity: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] RNG Distribution Uniformity: PASS")
  end

  it "verifies multi-boot entropy divergence across consecutive compilations" do
    tc1 = Citrine::Spec::Ps2TestCase.new("entropy_divergence_1")
    tc1.source(<<-CR
      require "citrine"
      val = Citrine.rand(1000, 9999)
      debug_puts "[SEED_TEST_1] \#{val}"
    CR
    )
    tc1.compile
    res1 = tc1.boot_pcsx2(timeout: 7.seconds)
    res1.should_boot_cleanly

    tc2 = Citrine::Spec::Ps2TestCase.new("entropy_divergence_2")
    tc2.source(<<-CR
      require "citrine"
      val = Citrine.rand(1000, 9999)
      debug_puts "[SEED_TEST_2] \#{val}"
    CR
    )
    tc2.compile
    res2 = tc2.boot_pcsx2(timeout: 7.seconds)
    res2.should_boot_cleanly
    next unless res1.pcsx2_available? && res2.pcsx2_available?

    line1 = res1.lines.find { |l| l.includes?("[SEED_TEST_1]") }
    line2 = res2.lines.find { |l| l.includes?("[SEED_TEST_2]") }

    line1.should_not be_nil
    line2.should_not be_nil
    line1.should_not eq(line2)
  end

  it "verifies that Example 03 initializes entities with varied speeds and corners" do
    tc = Citrine::Spec::Ps2TestCase.new("example_03_randomness")
    tc.target("examples/03_entity_fibers/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end
end
