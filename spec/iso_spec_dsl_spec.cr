require "./spec_helper"
require "../src/citrine/spec/iso_spec"

describe "Citrine ISO Testing DSL (PCSX2 Engine Supervisor)" do
  it "loads existing ISO and executes boot verification" do
    test_case = Citrine::Spec::IsoTestCase.new("01_hello_pad_iso")
    test_case.load("examples/01_hello_pad/game.iso")
    test_case.iso_path.should eq("examples/01_hello_pad/game.iso")

    result = test_case.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_not_exceed_boot_time(5.0.seconds)
  end

  it "asserts failure when boot time exceeds threshold" do
    res = Citrine::Spec::Ps2ExecutionResult.new(
      lines: ["Boot completed"],
      boot_time_seconds: 4.5
    )

    expect_raises(Spec::AssertionFailed, /Expected boot time to not exceed 2.0s/) do
      res.should_not_exceed_boot_time(2.0.seconds)
    end
  end

  it "discovers all built example ISOs using test_all_isos" do
    discovered_count = 0
    Citrine::Spec.test_all_isos("examples/**/game.iso", timeout: 1.seconds) do |iso_path, result|
      File.exists?(iso_path).should be_true
      result.should_preserve_spram
      discovered_count += 1
      next if discovered_count >= 2
    end

    discovered_count.should be >= 2
  end
end
