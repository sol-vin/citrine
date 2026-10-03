require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Regex, Pattern Matching & String Helpers" do
  it "verifies regex literals, =~ match operator, and Regex.new on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_regex_matching_test")
    tc.source(<<-CR
      pattern = /hero_\\d+/
      matched_idx = "super_hero_42_ready" =~ pattern

      if matched_idx >= 0
        debug_puts "[CITRINE TEST] Regex literal =~ matched: PASS"
      end

      # Regex.new with anchors and character classes
      rx = Regex.new("^[a-z]+$")
      if rx.matches?("citrine")
        debug_puts "[CITRINE TEST] Regex anchor ^[a-z]+$ matched: PASS"
      end

      if !rx.matches?("citrine123")
        debug_puts "[CITRINE TEST] Regex rejected non-alpha: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Regex literal =~ matched: PASS")
    result.should_have_output("[CITRINE TEST] Regex anchor ^[a-z]+$ matched: PASS")
    result.should_have_output("[CITRINE TEST] Regex rejected non-alpha: PASS")
  end

  it "verifies string operations (strip, downcase, upcase, starts_with?, ends_with?, includes?, split) on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_string_helpers_test")
    tc.source(<<-CR
      padded = "  playstation2  "
      clean = padded.strip
      if clean == "playstation2"
        debug_puts "[CITRINE TEST] String#strip: PASS"
      end

      upper = "EE_CORE".downcase
      if upper == "ee_core"
        debug_puts "[CITRINE TEST] String#downcase: PASS"
      end

      lower = "emotion".upcase
      if lower == "EMOTION"
        debug_puts "[CITRINE TEST] String#upcase: PASS"
      end

      msg = "PlayStation 2 Runtime"
      if msg.starts_with?("PlayStation")
        debug_puts "[CITRINE TEST] String#starts_with?: PASS"
      end

      if msg.ends_with?("Runtime")
        debug_puts "[CITRINE TEST] String#ends_with?: PASS"
      end

      if msg.includes?("2")
        debug_puts "[CITRINE TEST] String#includes?: PASS"
      end

      csv = "alpha,beta,gamma"
      parts = csv.split(",")
      if parts.size == 3 && parts[1] == "beta"
        debug_puts "[CITRINE TEST] String#split: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] String#strip: PASS")
    result.should_have_output("[CITRINE TEST] String#downcase: PASS")
    result.should_have_output("[CITRINE TEST] String#upcase: PASS")
    result.should_have_output("[CITRINE TEST] String#starts_with?: PASS")
    result.should_have_output("[CITRINE TEST] String#ends_with?: PASS")
    result.should_have_output("[CITRINE TEST] String#includes?: PASS")
    result.should_have_output("[CITRINE TEST] String#split: PASS")
  end
end
