require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Case/When & Range Iteration" do
  it "verifies value matching, multi-value branches, and else fallback on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_case_values_test")
    tc.source(<<-CR
      score = 2
      val_name = ""
      case score
      when 1, 2
        val_name = "low"
      when 3
        val_name = "medium"
      else
        val_name = "high"
      end

      if val_name == "low"
        debug_puts "[CITRINE TEST] Multi-value when 1, 2 matched: PASS"
      end

      other = 99
      case other
      when 1
        debug_puts "FAIL 1"
      when 2
        debug_puts "FAIL 2"
      else
        debug_puts "[CITRINE TEST] Else branch fallback matched: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Multi-value when 1, 2 matched: PASS")
    result.should_have_output("[CITRINE TEST] Else branch fallback matched: PASS")
  end

  it "verifies range matching and condition-less case predicates on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_case_ranges_test")
    tc.source(<<-CR
      level = 15
      tier = 0
      case level
      when 1..9
        tier = 1
      when 10..20
        tier = 2
      when 21..50
        tier = 3
      else
        tier = 4
      end

      if tier == 2
        debug_puts "[CITRINE TEST] Range matching 10..20: PASS"
      end

      # Condition-less case
      hp = 25
      status = ""
      case
      when hp <= 0
        status = "dead"
      when hp < 30
        status = "critical"
      else
        status = "healthy"
      end

      if status == "critical"
        debug_puts "[CITRINE TEST] Condition-less case predicate: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Range matching 10..20: PASS")
    result.should_have_output("[CITRINE TEST] Condition-less case predicate: PASS")
  end

  it "verifies range literal iteration with each on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_range_iteration_test")
    tc.source(<<-CR
      total = 0
      (1..5).each do |i|
        total = total + i
      end

      if total == 15
        debug_puts "[CITRINE TEST] Range iteration (1..5).each sum == 15: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Range iteration (1..5).each sum == 15: PASS")
  end
end
