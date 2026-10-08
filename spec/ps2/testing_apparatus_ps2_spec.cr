require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Testing Apparatus Verification Suite" do
  ps2_test "apparatus_multi_pass_test", "verifies multiple Test.pass calls can all be verified" do |tc|
    tc.source(<<-CR
      Test.pass("Check Test 1")
      Test.pass("Check Test 2")
      Test.pass("Check Test 3")
    CR
    )
    result = tc.run_and_verify
    next unless result.pcsx2_available?
    result.should_pass("Check Test 1")
    result.should_pass("Check Test 2")
    result.should_pass("Check Test 3")
    result.should_pass("Check Test 1", "Check Test 2", "Check Test 3")
    result.passed_count.should eq(3)
    result.failed_count.should eq(0)
  end

  ps2_test "apparatus_single_fail_rejection_test", "verifies that a single Test.fail causes failure detection" do |tc|
    tc.source(<<-CR
      Test.pass("First Check Passed")
      Test.fail("Second Check Failed")
      Test.pass("Third Check Passed")
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18
    result = tc.boot_pcsx2(timeout: 5.seconds)
    next unless result.pcsx2_available?

    # 1. Lifecycle ran
    result.should_have_init("apparatus_single_fail_rejection_test")
    result.should_have_close

    # 2. Failure is captured
    result.should_fail("Second Check Failed")
    result.failed_count.should eq(1)
    result.passed_count.should eq(2)

    # 3. should_pass must raise an exception when failure count > 0
    expect_raises(Spec::AssertionFailed, /Test failed with 1 failure/) do
      result.should_pass("First Check Passed")
    end
  end

  ps2_test "apparatus_assert_helpers_test", "verifies Test.assert and Test.assert_equal" do |tc|
    tc.source(<<-CR
      val = 50 + 50
      Test.assert(val == 100, "Math Check")
      Test.assert_equal(100, val, "Equal Check")
    CR
    )
    result = tc.run_and_verify
    next unless result.pcsx2_available?
    result.should_pass("Math Check")
    result.should_pass("Equal Check")
  end

  ps2_test "apparatus_lifecycle_integrity_test", "verifies Test.init and Test.close sequencing" do |tc|
    tc.source(<<-CR
      Test.pass("Body Executed")
    CR
    )
    result = tc.run_and_verify
    next unless result.pcsx2_available?
    result.should_have_init("apparatus_lifecycle_integrity_test")
    result.should_have_close
    result.lines.any? { |l| l.includes?("CLOSE: PASSED") }.should be_true
  end
end
