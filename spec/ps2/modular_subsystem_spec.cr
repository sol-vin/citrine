require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Modular Subsystems: Require Out Non-Base" do
  it "verifies pure Crystal computations execute without requiring graphics/audio subsystems on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("modular_pure_crystal_test")
    tc.source(<<-CR
      class Vector2D
        property x : Int32
        property y : Int32

        def initialize(@x : Int32, @y : Int32)
        end

        def add(other : Vector2D) : Vector2D
          Vector2D.new(@x + other.x, @y + other.y)
        end
      end

      v1 = Vector2D.new(10, 20)
      v2 = Vector2D.new(30, 40)
      v3 = v1.add(v2)

      if v3.x == 40 && v3.y == 60
        debug_puts "[CITRINE TEST] Pure Crystal Vector2D computation: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Pure Crystal Vector2D computation: PASS")
  end

  it "verifies optional Opal RNG subsystem requires on demand without polluting base on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("modular_optional_rng_test")
    tc.source(<<-CR
      require "opal/rng"

      rng = Opal::RNG::PRNG.new(123456789_u64)
      val = rng.next_int_to(100)

      if val >= 0 && val <= 100
        debug_puts "[CITRINE TEST] Optional opal/rng subsystem on demand: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Optional opal/rng subsystem on demand: PASS")
  end
end
