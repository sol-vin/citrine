require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Enums & String Interpolation" do
  it "verifies enum definitions, member resolution, and .value on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_enums_test")
    tc.source(<<-CR
      enum Direction
        North
        East
        South
        West
      end

      enum Priority
        Low = 10
        Normal = 20
        High = 30
      end

      d1 = Direction::North
      d2 = Direction::East
      d3 = Direction::West

      p1 = Priority::Low
      p2 = Priority::High

      if d1 == 0 && d2 == 1 && d3 == 3
        debug_puts "[CITRINE TEST] Enum auto-increment values: PASS"
      end

      if p1.value == 10 && p2.value == 30
        debug_puts "[CITRINE TEST] Enum explicit values with .value: PASS"
      end

      reconstructed = Priority.new(20)
      if reconstructed == 20
        debug_puts "[CITRINE TEST] Enum.new(value) constructor: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Enum auto-increment values: PASS")
    result.should_have_output("[CITRINE TEST] Enum explicit values with .value: PASS")
    result.should_have_output("[CITRINE TEST] Enum.new(value) constructor: PASS")
  end

  it "verifies string interpolation and .to_s conversion on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_strings_test")
    tc.source(<<-CR
      player_name = "Cloud"
      hp = 9999
      status = "Alive"
      level = 50

      # String interpolation with literals, variables, and expressions
      greeting = "Welcome, \#{player_name}!"
      debug_puts greeting

      summary = "HP: \#{hp} Level: \#{level + 1} Status: \#{status}"
      debug_puts summary

      num_str = hp.to_s
      if num_str == "9999"
        debug_puts "[CITRINE TEST] Integer .to_s: PASS"
      end

      active = true
      bool_str = active.to_s
      if bool_str == "true"
        debug_puts "[CITRINE TEST] Bool .to_s: PASS"
      end

      debug_puts "[CITRINE TEST] String interpolation completed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("Welcome, Cloud!")
    result.should_have_output("HP: 9999 Level: 51 Status: Alive")
    result.should_have_output("[CITRINE TEST] Integer .to_s: PASS")
    result.should_have_output("[CITRINE TEST] Bool .to_s: PASS")
    result.should_have_output("[CITRINE TEST] String interpolation completed: PASS")
  end
end
